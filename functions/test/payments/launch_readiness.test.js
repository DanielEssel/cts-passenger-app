// Wallet integrity for launch (2026-10-28). Wallet payment stays available;
// the server decides what a hold may pay for:
//  - holdBalance takes holds only for a known service, and supplier Gas
//    holds only while supplier Gas is switched on;
//  - attachEscrowToOrder links a hold only to the passenger's own, still
//    open, wallet booking whose price it equals and which reaches the
//    server's minimum price (Ride, Delivery and now legacy Gas);
//  - wallet Gas orders, like deliveries, are offered to drivers only once
//    paid, unpaid ones expire, and no driver accepts a wallet job whose hold
//    is not linked to it;
//  - settlement re-checks the price before releasing anything; a Gas wallet
//    order without a hold, or delivered by its own customer's account, earns
//    nothing; Gas cash settles on the booked total;
//  - a hold is refunded only for the order it pays;
//  - no driver accepts their own order;
//  - wallet Delivery and Gas are held back (cash only) until app_config/mobile
//    requires Passenger 1.0.1 and Driver 1.0.3, and never fund an order that
//    carries a driver-readable code; a wallet Delivery/Gas order taken before
//    its payment is linked is cancelled at once. Ride wallet is unaffected.
// Tests of wallet Delivery/Gas logic run with those minimum versions set
// (codeSecureApps), the state after the Passenger 1.0.1 / Driver 1.0.3 rollout.
// Firestore emulator only; FCM is stubbed; no real money.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const trips = require("../../trips");
const escrow = require("../../escrow");
const notifications = require("../../notifications");
const { acceptJob } = require("../../accept_job");
const { gasFareFloor, gasOrderPriceProblem, verifyHeldAmount } = require("../../payment_verification");

const { GeoPoint, Timestamp } = h.admin.firestore;
const PICKUP = new GeoPoint(5.6037, -0.187);
const DROPOFF = new GeoPoint(5.62, -0.19);
const P = "lr-passenger";
const D = "lr-driver";
const MIN = 60 * 1000;

Object.defineProperty(h.admin, "messaging", {
  configurable: true, writable: true,
  value: () => ({
    sendEachForMulticast: async (m) => ({ successCount: m.tokens.length, failureCount: 0,
      responses: m.tokens.map(() => ({ success: true })) }),
    send: async () => "stub-id",
  }),
});

const hold = (data, uid = P) => h.callCallable(escrow.holdBalance, uid, data);
const attach = (data, uid = P) => h.callCallable(escrow.attachEscrowToOrder, uid, data);
const refundOnError = (data, uid = P) => h.callCallable(escrow.refundEscrowOnError, uid, data);
const driver = () => h.read(`drivers/${D}`);
const alerts = (type) => h.count("admin_alerts", "type", type);
const captures = () => h.count("ledger", "idempotencyKey", "capture_e1");
const all = async (collection) => (await h.db().collection(collection).get()).size;
const inbox = async (id) => (await h.db().collection("drivers").doc(id).collection("notifications").get()).size;

// A legacy Gas order as gas_refill_request.dart writes it: 3 kg exchange,
// GHS 40 refill + GHS 12 minimum delivery = GHS 52 floor at default prices.
const gasOrder = (o = {}) => ({ passengerId: P, driverId: null, status: "pendingApproval",
  refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1, paymentMethod: "wallet",
  pickupLocation: PICKUP, deliveryLocation: PICKUP, deliveryAddress: "C", totalPrice: 100,
  createdAt: Timestamp.now(), ...o });
// Release v5: an order is created at exactly the server's price (total and
// delivery fee; functions/gas_pricing.js). gasOrder() keeps its round total
// for the tests that seed orders directly; tests that create or accept one
// use these amounts, the 3 kg exchange price at built-in prices.
const PRICED = { totalPrice: 52, deliveryFee: 12 };
const deliveryOrder = (o = {}) => ({ passengerId: P, driverId: null, status: "pending",
  vehicleType: "Okada", weightTier: "Small", paymentMethod: "wallet", pickupLocation: PICKUP,
  dropoffLocation: DROPOFF, estimatedFare: 100, createdAt: Timestamp.now(), ...o });
const goodsDriver = (o = {}) => ({ uid: D, role: "driver_delivery", serviceType: "delivery",
  vehicleType: "motorcycle", isApproved: true, signupStep: "approved", isOnline: true,
  isAvailable: true, location: PICKUP, lastLocationUpdate: Timestamp.now(), fcmToken: "tok", ...o });

// The approved Delivery rates (test fixture) server quotes are priced with.
const DPLATFORM = { platformFeePercent: 15, delivery: h.DELIVERY_RATES };

async function seedAccounts(platform = {}) {
  await h.seed("settings/platform", { ...DPLATFORM, ...platform });
  await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 100 });
  await h.seed(`drivers/${D}`, { walletBalance: 0, totalEarnings: 0, commissionOwed: 0,
    currentTripId: "o1", isAvailable: false });
}

async function seedHold(referenceType, amount, o = {}) {
  await h.seed("escrows/e1", { userId: P, amount, platformFee: Math.round(amount * 15) / 100,
    driverNet: Math.round(amount * 85) / 100, status: "HELD", referenceId: "o1", referenceType, ...o });
}

const SERVICES = {
  ride: {
    fn: () => trips.onTripCompleted, collection: "trips", idParam: "tripId", referenceType: "trip",
    failedAlert: "trip_settlement_failed",
    before: { status: "tripStarted" },
    after: { status: "completed", passengerConfirmed: true, estimatedFare: 100, serviceType: "taxi",
      pickupLocation: PICKUP, dropoffLocation: DROPOFF },
  },
  delivery: {
    fn: () => trips.onDeliveryCompleted, collection: "deliveries", idParam: "deliveryId",
    referenceType: "delivery", failedAlert: "delivery_settlement_failed",
    before: { status: "arrivedAtDropoff" },
    after: { status: "completed", estimatedFare: 100, vehicleType: "Okada", weightTier: "Small",
      pickupLocation: PICKUP, dropoffLocation: DROPOFF, deliveryOtp: "1234", otpSubmitted: "1234" },
  },
  gas: {
    fn: () => trips.onGasOrderCompleted, collection: "gas_orders", idParam: "orderId",
    referenceType: "gas_order", failedAlert: "gas_settlement_failed",
    before: { status: "returning" },
    after: { status: "delivered", totalPrice: 100, refillType: "exchangeEmpty", cylinderSize: "kg3",
      quantity: 1, deliveryOtp: "4321", otpSubmitted: "4321" },
  },
};

function event(svc, extra = {}) {
  const base = { passengerId: P, driverId: D, paymentMethod: "wallet", escrowId: "e1" };
  const before = { ...base, ...svc.before };
  const afterDoc = { ...base, ...svc.after, ...extra };
  return { params: { [svc.idParam]: "o1" },
    data: { before: { data: () => before }, after: { data: () => afterDoc } } };
}

async function complete(svc, extra = {}) {
  const ev = event(svc, extra);
  await h.seed(`${svc.collection}/o1`, ev.data.after.data());
  await svc.fn().run(ev);
  return ev;
}

const order = (svc) => h.read(`${svc.collection}/o1`);

/** The minimum versions after which wallet Delivery and Gas are offered. */
// Code-secure minimum versions and the Delivery/Gas wallet switch (both needed).
const codeSecureApps = (o = {}) => h.enableDeliveryGasWallet(o);

beforeEach(async () => {
  await h.clearFirestore();
});

after(async () => {
  await h.clearFirestore();
  h.fft.cleanup();
});

describe("holds", () => {
  test("LR-01 wallet payment works with no new setting: the hold is taken", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    await codeSecureApps();
    for (const referenceType of ["trip", "delivery", "gas_order"]) {
      const r = await hold({ amount: 50, serviceType: referenceType, referenceType });
      assert.equal(r.success, true, referenceType);
      assert.equal((await h.read(`escrows/${r.escrowId}`)).status, "HELD");
    }
    assert.equal((await h.read(`wallets/${P}`)).balance, 350);
  });

  test("LR-02 a hold for an unknown service is refused and changes nothing", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    for (const referenceType of [undefined, "ride", "toString", "__proto__", "gas_supplier"]) {
      await assert.rejects(hold({ amount: 50, serviceType: "x", referenceType }), (e) => {
        assert.equal(e.code, "invalid-argument");
        assert.equal(e.details?.reason, "reference_type_invalid");
        return true;
      });
    }
    assert.equal(await all("escrows"), 0);
    assert.equal(await all("ledger"), 0);
    assert.equal((await h.read(`wallets/${P}`)).balance, 500);
  });

  test("LR-03 supplier Gas holds only while supplier Gas is switched on", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    const supplier = { amount: 50, serviceType: "gas", referenceType: "gas_supplier_order" };
    await assert.rejects(hold(supplier), (e) => e.details?.reason === "supplier_gas_disabled");
    await h.seed("settings/gas_supplier_fulfilment", { enabled: "true" });
    await assert.rejects(hold(supplier), (e) => e.details?.reason === "supplier_gas_disabled");
    assert.equal(await all("escrows"), 0);
    await h.seed("settings/gas_supplier_fulfilment", { enabled: true });
    assert.equal((await hold(supplier)).success, true);
  });
});

describe("wallet Delivery and Gas held back until the apps keep the code secret", () => {
  test("LR-06 Delivery/Gas holds are refused until both minimum versions are reached; Ride is not", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    const holdFor = (referenceType) => hold({ amount: 50, serviceType: "x", referenceType });
    for (const cfg of [null, { passengerMinimumVersion: "1.0.0", driverMinimumVersion: "1.0.0" },
      { passengerMinimumVersion: "1.0.1", driverMinimumVersion: "1.0.2" },
      { passengerMinimumVersion: "1.0.0", driverMinimumVersion: "1.0.3" },
      { passengerMinimumVersion: "1.0.1", driverMinimumVersion: "1.0.2+99" },
      { passengerMinimumVersion: 101, driverMinimumVersion: "1.0.3" }]) {
      if (cfg) await h.seed("app_config/mobile", cfg);
      for (const t of ["delivery", "gas_order"]) {
        await assert.rejects(holdFor(t), (e) => {
          assert.equal(e.code, "failed-precondition");
          assert.equal(e.details?.reason, "wallet_delivery_gas_unavailable", JSON.stringify(cfg));
          return true;
        });
      }
    }
    assert.equal(await all("escrows"), 0, "nothing held");
    assert.equal((await h.read(`wallets/${P}`)).balance, 500);
    assert.equal((await holdFor("trip")).success, true, "Ride wallet still works");

    await codeSecureApps({ passengerMinimumVersion: "1.0.1+5", driverMinimumVersion: "1.1.0" });
    assert.equal((await holdFor("delivery")).success, true);
    assert.equal((await holdFor("gas_order")).success, true);
  });

  test("LR-07 attach refuses a Delivery/Gas hold while held back: booking cancelled, hold returned", async () => {
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 200 });
    await h.seed("escrows/e-d", { userId: P, amount: 100, platformFee: 15, driverNet: 85, status: "HELD",
      referenceId: null, referenceType: "delivery" });
    await h.seed("escrows/e-g", { userId: P, amount: 100, platformFee: 15, driverNet: 85, status: "HELD",
      referenceId: null, referenceType: "gas_order" });
    await h.seed("deliveries/d1", deliveryOrder());
    await h.seed("gas_orders/g1", gasOrder());
    await assert.rejects(attach({ escrowId: "e-d", referenceId: "d1", referenceType: "delivery" }),
      (e) => e.details?.reason === "wallet_delivery_gas_unavailable");
    await assert.rejects(attach({ escrowId: "e-g", referenceId: "g1", referenceType: "gas_order" }),
      (e) => e.details?.reason === "wallet_delivery_gas_unavailable");
    assert.equal((await h.read("deliveries/d1")).status, "cancelled");
    assert.equal((await h.read("gas_orders/g1")).status, "cancelled");
    assert.equal((await h.read("escrows/e-d")).status, "REFUNDED");
    assert.equal((await h.read("escrows/e-g")).status, "REFUNDED");
    const w = await h.read(`wallets/${P}`);
    assert.equal(w.balance, 200);
    assert.equal(w.heldBalance, 0);
  });

  test("LR-08 an order carrying a driver-readable code never takes a wallet hold", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    await codeSecureApps();
    for (const [referenceType, collection, doc] of [
      ["delivery", "deliveries", deliveryOrder({ deliveryOtp: "1234" })],
      ["gas_order", "gas_orders", gasOrder({ deliveryOtp: "4321" })],
    ]) {
      const { escrowId } = await hold({ amount: 100, serviceType: "x", referenceType });
      await h.seed(`${collection}/o1`, doc);
      await assert.rejects(attach({ escrowId, referenceId: "o1", referenceType }),
        (e) => e.details?.reason === "completion_code_on_order");
      assert.equal((await h.read(`${collection}/o1`)).status, "cancelled");
      assert.equal((await h.read(`escrows/${escrowId}`)).status, "REFUNDED");
    }
    assert.equal((await h.read(`wallets/${P}`)).balance, 500);
  });

  test("LR-09 Ride wallet is linked and offered regardless of the Delivery/Gas restriction", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    const { escrowId } = await hold({ amount: 100, serviceType: "taxi", referenceType: "trip" });
    await h.seed("trips/t1", { passengerId: P, status: "searching", paymentMethod: "wallet", escrowId,
      serviceType: "taxi", estimatedFare: 100, pickupLocation: PICKUP, dropoffLocation: DROPOFF });
    assert.equal((await attach({ escrowId, referenceId: "t1", referenceType: "trip" })).success, true);
    assert.equal((await h.read(`escrows/${escrowId}`)).referenceId, "t1");
  });
});

describe("a wallet Delivery/Gas order taken before it is paid", () => {
  const statusEvent = (fn, idParam, before, afterDoc) => fn.run({ params: { [idParam]: "o1" },
    data: { before: { data: () => before }, after: { data: () => afterDoc } } });

  for (const [label, fn, idParam, collection, doc, referenceType] of [
    ["delivery", () => notifications.onDeliveryStatusChanged, "deliveryId", "deliveries", deliveryOrder(), "delivery"],
    ["gas", () => notifications.onGasOrderStatusChanged, "orderId", "gas_orders", gasOrder(), "gas_order"],
  ]) {
    test(`LR-24 ${label}: taken unpaid (direct claim) → cancelled at once, then the driver is freed`, async () => {
      await h.seed(`users/${P}`, { displayName: "Pat", phoneNumber: "+233200000000" });
      await h.seed(`drivers/${D}`, goodsDriver({ isAvailable: false, currentTripId: "o1",
        currentTripType: collection }));
      const taken = { ...doc, driverId: D, status: "driverAssigned" };
      await h.seed(`${collection}/o1`, taken);
      await statusEvent(fn(), idParam, doc, taken);
      const o = await h.read(`${collection}/o1`);
      assert.equal(o.status, "cancelled");
      assert.equal(o.paymentRejectedReason, "wallet_payment_missing_at_assignment");
      assert.equal(o.passengerPhone, undefined, "no customer contact copied for an unpaid claim");
      assert.equal(await alerts("wallet_payment_rejected"), 1);

      // The cancellation's own status event frees the driver.
      await statusEvent(fn(), idParam, taken, o);
      const d = await driver();
      assert.equal(d.currentTripId, undefined);
      assert.equal(d.isAvailable, true);
    });

    test(`LR-25 ${label}: taken after its hold is linked → stays assigned`, async () => {
      await seedHold(referenceType, 100);
      await h.seed(`drivers/${D}`, goodsDriver({ isAvailable: false, currentTripId: "o1" }));
      const paid = { ...doc, escrowId: "e1" };
      const taken = { ...paid, driverId: D, status: "driverAssigned" };
      await h.seed(`${collection}/o1`, taken);
      await statusEvent(fn(), idParam, paid, taken);
      assert.equal((await h.read(`${collection}/o1`)).status, "driverAssigned");
      assert.equal((await driver()).currentTripId, "o1");
    });
  }

  test("LR-26 cash orders taken by a driver are never cancelled by this check", async () => {
    await h.seed(`drivers/${D}`, goodsDriver({ isAvailable: false, currentTripId: "o1" }));
    const doc = gasOrder({ paymentMethod: "cash" });
    const taken = { ...doc, driverId: D, status: "driverAssigned" };
    await h.seed("gas_orders/o1", taken);
    await notifications.onGasOrderStatusChanged.run({ params: { orderId: "o1" },
      data: { before: { data: () => doc }, after: { data: () => taken } } });
    assert.equal((await h.read("gas_orders/o1")).status, "driverAssigned");
  });
});

describe("Gas price floor (payment_verification.js)", () => {
  test("LR-04 the floor is the product price plus the minimum delivery fee", () => {
    const o = (x) => ({ cylinderSize: "kg3", refillType: "exchangeEmpty", quantity: 1, ...x });
    assert.equal(gasFareFloor(o(), null), 52);
    assert.equal(gasFareFloor(o({ quantity: 2 }), null), 92);
    assert.equal(gasFareFloor(o({ refillType: "newCylinder" }), null), 192);
    assert.equal(gasFareFloor(o({ refillType: "pickupAndReturn" }), null), 82, "plus the round-trip fee");
    // Configured prices, as the app reads them (production's differ from the built-in ones).
    assert.equal(gasFareFloor(o({ cylinderSize: "kg12_5" }), { gas: { refill12kg: 160 } }), 172);
    assert.equal(gasFareFloor(o({ cylinderSize: "kg12_5" }), { gas: { refill12kg: 140 } }), 152);
    // Brand premium and the 1 km delivery charge.
    assert.equal(gasFareFloor(o({ preferredBrand: "totalEnergies" }), null), 54);
    // Release v5: a brand the server does not know cannot be priced (was: priced as "any").
    assert.equal(gasFareFloor(o({ preferredBrand: "unknownBrand" }), null), null);
    assert.equal(gasFareFloor(o(), { gas: { baseFare: 20, perKm: 5 } }), 65, "40 + max(12, 20 + 5 × 1 km)");
    assert.equal(gasFareFloor(o({ refillType: "pickupAndReturn" }), { gas: { baseFare: 20, perKm: 5 } }), 100,
      "40 + max(12, 20 + 5 × 2 legs) + 30");
    assert.equal(gasFareFloor(o({ refillType: "commercialBulk", quantity: 3 }), { gas: { commercialRate: 1.5 } }), 192,
      "40 × 3 × 1.5 + 12");
    for (const bad of [{ cylinderSize: "12.5kg" }, { refillType: "x" }, { quantity: 0 },
      { quantity: 1.5 }, { quantity: "1" }]) {
      assert.equal(gasFareFloor(o(bad), null), null, JSON.stringify(bad));
    }
  });

  test("LR-05 a Gas hold must equal the order total and reach the floor", () => {
    const o = gasOrder();
    const check = (amount, x = {}) => verifyHeldAmount({ referenceType: "gas_order",
      order: { ...o, ...x }, escrowAmount: amount, settings: null });
    assert.deepEqual(check(100), { ok: true, floor: 52 });
    assert.equal(check(99).reason, "hold_amount_mismatch");
    assert.equal(check(10, { totalPrice: 10 }).reason, "hold_below_minimum_price");
    assert.equal(check(100, { paymentMethod: "cash" }).reason, "order_not_wallet_payment");
    assert.equal(check(100, { cylinderSize: null }).reason, "price_unverifiable");
  });
});

describe("attaching a hold", () => {
  test("LR-10 Gas: a hold below the order's price is refused; the order is cancelled and the hold returned", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    await codeSecureApps();
    const { escrowId } = await hold({ amount: 10, serviceType: "gas", referenceType: "gas_order" });
    await h.seed("gas_orders/o1", gasOrder({ totalPrice: 10 }));
    await assert.rejects(attach({ escrowId, referenceId: "o1", referenceType: "gas_order" }),
      (e) => e.details?.reason === "hold_below_minimum_price");
    assert.equal((await h.read("gas_orders/o1")).status, "cancelled");
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "REFUNDED");
    const w = await h.read(`wallets/${P}`);
    assert.equal(w.balance, 500);
    assert.equal(w.heldBalance, 0);
  });

  test("LR-11 Gas: a hold differing from the order total is refused", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    await codeSecureApps();
    const { escrowId } = await hold({ amount: 60, serviceType: "gas", referenceType: "gas_order" });
    await h.seed("gas_orders/o1", gasOrder());
    await assert.rejects(attach({ escrowId, referenceId: "o1", referenceType: "gas_order" }),
      (e) => e.details?.reason === "hold_amount_mismatch");
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "REFUNDED");
  });

  test("LR-12 Gas: a matching hold is linked and recorded on the order", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    await codeSecureApps();
    const { escrowId } = await hold({ amount: 100, serviceType: "gas", referenceType: "gas_order" });
    await h.seed("gas_orders/o1", gasOrder());
    assert.equal((await attach({ escrowId, referenceId: "o1", referenceType: "gas_order" })).success, true);
    const e = await h.read(`escrows/${escrowId}`);
    assert.deepEqual([e.status, e.referenceId, e.referenceType], ["HELD", "o1", "gas_order"]);
    assert.equal((await h.read("gas_orders/o1")).escrowId, escrowId);
  });

  test("LR-13 a hold is never linked to a booking that already ended", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    await codeSecureApps();
    const { escrowId } = await hold({ amount: 100, serviceType: "delivery", referenceType: "delivery" });
    await h.seed("deliveries/o1", deliveryOrder({ status: "cancelled" }));
    await assert.rejects(attach({ escrowId, referenceId: "o1", referenceType: "delivery" }),
      /no longer open/);
    assert.equal((await h.read(`escrows/${escrowId}`)).referenceId, null);
  });

  test("LR-14 a hold is never linked to another passenger's booking", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    await codeSecureApps();
    const { escrowId } = await hold({ amount: 100, serviceType: "gas", referenceType: "gas_order" });
    await h.seed("gas_orders/o1", gasOrder({ passengerId: "someone-else" }));
    await assert.rejects(attach({ escrowId, referenceId: "o1", referenceType: "gas_order" }),
      (e) => e.code === "permission-denied");
  });
});

describe("Gas wallet dispatch", () => {
  const created = (data) => notifications.onGasOrderCreated.run({ params: { orderId: "o1" },
    data: { data: () => data } });
  const attached = (before, afterDoc) => notifications.onGasOrderPaymentAttached.run({
    params: { orderId: "o1" }, data: { before: { data: () => before }, after: { data: () => afterDoc } } });

  test("LR-20 an unpaid wallet order is not offered; it is once its hold is linked", async () => {
    await h.seed("drivers/bike", goodsDriver({ uid: "bike" }));
    const o = gasOrder(PRICED);
    await h.seed("gas_orders/o1", o);
    await created(o);
    assert.equal(await inbox("bike"), 0, "not offered before payment");

    await seedHold("gas_order", 52);
    const paid = { ...(await h.read("gas_orders/o1")), escrowId: "e1" };
    await h.seed("gas_orders/o1", paid);
    await attached(o, paid);
    assert.equal(await inbox("bike"), 1, "offered once paid");
  });

  test("LR-21 an escrowId that does not name its linked hold dispatches nothing", async () => {
    await h.seed("drivers/bike", goodsDriver({ uid: "bike" }));
    await seedHold("gas_order", 100, { referenceId: "another-order" });
    const o = gasOrder();
    await attached(o, { ...o, escrowId: "e1" });
    assert.equal(await inbox("bike"), 0);
  });

  test("LR-22 cash orders are offered at once, as before", async () => {
    await h.seed("drivers/bike", goodsDriver({ uid: "bike" }));
    // The trigger fires for a stored order (it verifies the price on it).
    const o = gasOrder({ paymentMethod: "cash", ...PRICED });
    await h.seed("gas_orders/o1", o);
    await created(o);
    assert.equal(await inbox("bike"), 1);
  });

  test("LR-23 an unpaid wallet Gas order expires after ten minutes; a paid or recent one does not", async () => {
    const old = Timestamp.fromDate(new Date(Date.now() - 11 * MIN));
    await h.seed("gas_orders/unpaid", gasOrder({ createdAt: old }));
    await h.seed("gas_orders/paid", gasOrder({ createdAt: old, escrowId: "e1" }));
    await h.seed("gas_orders/recent", gasOrder());
    await h.seed("deliveries/unpaid", deliveryOrder({ createdAt: old }));
    const r = await escrow.cancelUnpaidWalletDeliveries();
    assert.equal(r.cancelled, 2);
    assert.equal((await h.read("gas_orders/unpaid")).status, "cancelled");
    assert.equal((await h.read("gas_orders/paid")).status, "pendingApproval");
    assert.equal((await h.read("gas_orders/recent")).status, "pendingApproval");
    assert.equal((await h.read("deliveries/unpaid")).status, "cancelled");
  });
});

describe("acceptance", () => {
  const open = {
    ride: { collection: "trips", doc: { passengerId: D, status: "searching", driverId: null,
      serviceType: "taxi", paymentMethod: "cash", pickupLocation: PICKUP, estimatedFare: 20 } },
    delivery: { collection: "deliveries", doc: { passengerId: D, status: "pending", driverId: null,
      vehicleType: "Okada", weightTier: "Small", paymentMethod: "cash", pickupLocation: PICKUP } },
    gas: { collection: "gas_orders", doc: { customerId: D, status: "pendingApproval", driverId: null,
      paymentMethod: "cash", totalPrice: 100 } },
  };
  for (const [service, o] of Object.entries(open)) {
    test(`LR-30 a driver cannot accept their own ${service} order`, async () => {
      await h.seed(`drivers/${D}`, goodsDriver());
      await h.seed(`${o.collection}/o1`, { ...o.doc, createdAt: Timestamp.now() });
      const r = await acceptJob(service, D, "o1");
      assert.deepEqual(r, { success: false, reason: "order_unavailable", detail: "own_order" });
      assert.equal((await h.read(`${o.collection}/o1`)).driverId, null);
      assert.equal((await driver()).currentTripId, undefined);
    });
  }

  for (const [service, collection, referenceType, doc] of [
    // Past creation: its quote verified and stamped (release v5 round 3).
    ["delivery", "deliveries", "delivery", h.deliveryStamped(deliveryOrder())],
    ["gas", "gas_orders", "gas_order", gasOrder(PRICED)],
  ]) {
    test(`LR-31 ${service}: a wallet job is accepted only once its hold is linked to it`, async () => {
      await h.seed(`drivers/${D}`, goodsDriver());
      await h.seed(`${collection}/o1`, doc);
      let r = await acceptJob(service, D, "o1");
      assert.equal(r.detail, "payment_not_verified", "no escrowId");

      await seedHold(referenceType, 100, { referenceId: "another-order" });
      await h.seed(`${collection}/o1`, { ...doc, escrowId: "e1" });
      r = await acceptJob(service, D, "o1");
      assert.equal(r.detail, "payment_not_verified", "hold linked elsewhere");

      await seedHold(referenceType, 100, { status: "REFUNDED" });
      r = await acceptJob(service, D, "o1");
      assert.equal(r.detail, "payment_not_verified", "hold refunded");
      assert.equal((await h.read(`${collection}/o1`)).driverId, null);

      await seedHold(referenceType, 100);
      r = await acceptJob(service, D, "o1");
      assert.equal(r.success, true, "paid: accepted");
      assert.equal((await driver()).currentTripId, "o1");
    });
  }
});

describe("refunds", () => {
  test("LR-40 a hold an order names cannot be refunded by its owner through refundEscrowOnError", async () => {
    await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
    const { escrowId } = await hold({ amount: 100, serviceType: "taxi", referenceType: "trip" });
    await h.seed("trips/t1", { passengerId: P, status: "searching", paymentMethod: "wallet",
      escrowId, estimatedFare: 100 });
    await assert.rejects(refundOnError({ escrowId, reason: "x" }));
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "HELD");
  });

  test("LR-41 cancelling order B never refunds the hold that pays for order A", async () => {
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
    await seedHold("trip", 100, { referenceId: "A" });
    const b = { passengerId: P, status: "searching", paymentMethod: "wallet", escrowId: "e1" };
    await h.seed("trips/B", { ...b, status: "cancelledByPassenger" });
    await trips.onTripCancelled.run({ params: { tripId: "B" },
      data: { before: { data: () => b }, after: { data: () => ({ ...b, status: "cancelledByPassenger" }) } } });
    assert.equal((await h.read("escrows/e1")).status, "HELD");
    assert.equal((await h.read(`wallets/${P}`)).balance, 0);
  });

  test("LR-42 cancelling the order a hold pays for refunds it once", async () => {
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
    await seedHold("trip", 100, { referenceId: "A" });
    const a = { passengerId: P, status: "searching", paymentMethod: "wallet", escrowId: "e1" };
    const ev = { params: { tripId: "A" },
      data: { before: { data: () => a }, after: { data: () => ({ ...a, status: "cancelledByPassenger" }) } } };
    await h.seed("trips/A", { ...a, status: "cancelledByPassenger" });
    await trips.onTripCancelled.run(ev);
    await trips.onTripCancelled.run(ev);
    assert.equal((await h.read("escrows/e1")).status, "REFUNDED");
    const w = await h.read(`wallets/${P}`);
    assert.equal(w.balance, 100);
    assert.equal(w.heldBalance, 0);
  });
});

describe("settlement never trusts the hold's amount", () => {
  for (const [service, svc] of Object.entries(SERVICES)) {
    test(`LR-50 ${service}: a hold below the booked price releases nothing`, async () => {
      await seedAccounts();
      await seedHold(svc.referenceType, 10);
      await complete(svc);
      const o = await order(svc);
      assert.notEqual(o.walletProcessed, true);
      assert.equal(o.settlementStatus, "failed");
      assert.equal(o.settlementFailureReason, "hold_amount_mismatch");
      assert.equal((await h.read("escrows/e1")).status, "HELD", "the passenger's hold is untouched");
      assert.equal(await captures(), 0);
      assert.equal((await driver()).walletBalance, 0, "driver not credited");
      assert.equal(await alerts(svc.failedAlert), 1);
    });

    test(`LR-51 ${service}: a matching hold settles once, and a repeat pays nothing more`, async () => {
      await seedAccounts();
      await seedHold(svc.referenceType, 100);
      const ev = await complete(svc);
      await svc.fn().run(ev); // the same event delivered again
      const o = await order(svc);
      assert.equal(o.walletProcessed, true);
      assert.equal((await h.read("escrows/e1")).status, "RELEASED");
      assert.equal(await captures(), 1);
      assert.equal((await driver()).walletBalance, 85);
      assert.equal((await h.read(`wallets/${P}`)).heldBalance, 0);
    });
  }

  test("LR-52 ride: a hold equal to a booked fare under the route's minimum releases nothing", async () => {
    await seedAccounts();
    await seedHold("trip", 1);
    await complete(SERVICES.ride, { estimatedFare: 1 });
    assert.equal((await order(SERVICES.ride)).settlementFailureReason, "hold_below_minimum_price");
    assert.equal((await h.read("escrows/e1")).status, "HELD");
    assert.equal((await driver()).walletBalance, 0);
  });

  test("LR-53 gas: a hold equal to an order total under the minimum Gas price releases nothing", async () => {
    await seedAccounts();
    await seedHold("gas_order", 20);
    await complete(SERVICES.gas, { totalPrice: 20 });
    assert.equal((await order(SERVICES.gas)).settlementFailureReason, "hold_below_minimum_price");
    assert.equal((await h.read("escrows/e1")).status, "HELD");
  });

  test("LR-54 delivery: a hold without locations to price it releases nothing", async () => {
    await seedAccounts();
    await seedHold("delivery", 100);
    await complete(SERVICES.delivery, { pickupLocation: null });
    assert.equal((await order(SERVICES.delivery)).settlementFailureReason, "price_unverifiable");
    assert.equal((await h.read("escrows/e1")).status, "HELD");
  });
});

describe("Gas settlement", () => {
  test("LR-60 a wallet order without a hold is not charged or credited", async () => {
    await seedAccounts();
    await complete(SERVICES.gas, { escrowId: null });
    const o = await order(SERVICES.gas);
    assert.equal(o.settlementFailureReason, "wallet_order_without_escrow");
    assert.equal((await h.read(`wallets/${P}`)).balance, 500, "passenger not charged");
    const d = await driver();
    assert.equal(d.walletBalance, 0);
    assert.equal(d.totalEarnings, 0);
    assert.equal(await all("ledger"), 0);
  });

  test("LR-61 an order delivered by its own customer's account is flagged, not settled", async () => {
    await seedAccounts();
    await h.seed("escrows/e1", { userId: D, amount: 100, platformFee: 15, driverNet: 85,
      status: "HELD", referenceId: "o1", referenceType: "gas_order" });
    await complete(SERVICES.gas, { passengerId: D });
    const o = await order(SERVICES.gas);
    assert.equal(o.status, "flagged");
    assert.notEqual(o.walletProcessed, true);
    assert.equal((await h.read("escrows/e1")).status, "HELD");
    assert.equal((await driver()).walletBalance, 0);
    assert.equal(await alerts("gas_self_order"), 1);
  });

  test("LR-62 cash: an inflated driver-written actualFare is ignored; nothing withdrawable", async () => {
    await seedAccounts();
    await complete(SERVICES.gas, { paymentMethod: "cash", escrowId: null, actualFare: 5000 });
    const o = await order(SERVICES.gas);
    assert.equal(o.walletProcessed, true);
    assert.equal(o.actualFare, 100, "settled on the booked total");
    const d = await driver();
    assert.equal(d.totalEarnings, 100);
    assert.equal(d.commissionOwed, 15);
    assert.equal(d.walletBalance, 0, "cash never becomes withdrawable credit");
  });

  test("LR-63 cash, the same event twice: recorded once", async () => {
    await seedAccounts();
    const ev = await complete(SERVICES.gas, { paymentMethod: "cash", escrowId: null });
    await SERVICES.gas.fn().run(ev);
    const d = await driver();
    assert.equal(d.totalEarnings, 100);
    assert.equal(d.commissionOwed, 15);
  });
});

// ── Gate 3 (2026-10-27): private details, Gas price at creation, stale-safe guard ──

const priv = (collection, id = "o1") => h.read(`${collection}/${id}/private/details`);
// As Passenger 1.0.1 books it: the stored order names its server quote.
async function deliveryCreated(id, data) {
  const quoted = await h.quotedDelivery(data, { quoteId: `q-${id}`, settings: DPLATFORM });
  await h.seed("settings/platform", DPLATFORM);
  await h.db().doc(`deliveries/${id}`).set({ deliveryQuoteId: quoted.deliveryQuoteId }, { merge: true });
  return notifications.onDeliveryCreated.run({ params: { deliveryId: id }, data: { data: () => quoted } });
}
const gasCreated = (id, data) => notifications.onGasOrderCreated.run({ params: { orderId: id },
  data: { data: () => data } });
const statusRun = (fn, idParam, id, before, afterDoc) => fn.run({ params: { [idParam]: id },
  data: { before: { data: () => before }, after: { data: () => afterDoc } } });
const RECEIVER = { receiverName: "Ama", receiverPhone: "+233200000009", notes: "Blue gate", photoUrl: "https://x/p.jpg" };
const GAS_PRIVATE = { pickupInstructions: "Ring twice", deliveryInstructions: "Gate code 4411",
  cylinderConditionNotes: "Valve stiff", receiptEmail: "ama@example.com" };

describe("private order details", () => {
  test("LR-70 a new delivery's receiver details leave the order; the offer carries none", async () => {
    await h.seed("drivers/bike", goodsDriver({ uid: "bike" }));
    const d = deliveryOrder({ paymentMethod: "cash", ...RECEIVER });
    await h.seed("deliveries/o1", d);
    await deliveryCreated("o1", d);
    const o = await h.read("deliveries/o1");
    for (const k of Object.keys(RECEIVER)) assert.equal(o[k], undefined, `${k} not on the open order`);
    assert.deepEqual(await priv("deliveries"), RECEIVER);
    assert.equal(await inbox("bike"), 1, "still offered");
    const entry = (await h.db().collection("drivers/bike/notifications").get()).docs[0].data();
    assert.ok(!JSON.stringify(entry).includes("Ama") && !JSON.stringify(entry).includes("200000009"));
  });

  test("LR-71 a valid assignment copies them back once; a repeat changes nothing", async () => {
    await h.seed(`drivers/${D}`, goodsDriver({ isAvailable: false, currentTripId: "o1" }));
    const d = deliveryOrder({ paymentMethod: "cash", ...RECEIVER });
    await h.seed("deliveries/o1", d);
    await deliveryCreated("o1", d);
    const open = await h.read("deliveries/o1");
    const taken = { ...open, driverId: D, status: "driverAssigned" };
    await h.seed("deliveries/o1", taken);
    await statusRun(notifications.onDeliveryStatusChanged, "deliveryId", "o1", open, taken);
    await statusRun(notifications.onDeliveryStatusChanged, "deliveryId", "o1", open, taken);
    const o = await h.read("deliveries/o1");
    for (const [k, v] of Object.entries(RECEIVER)) assert.equal(o[k], v);
  });

  test("LR-72 an order cancelled before assignment never gets them back", async () => {
    const d = deliveryOrder({ paymentMethod: "cash", ...RECEIVER });
    await h.seed("deliveries/o1", d);
    await deliveryCreated("o1", d);
    const open = await h.read("deliveries/o1");
    const cancelled = { ...open, status: "cancelled" };
    await h.seed("deliveries/o1", cancelled);
    await statusRun(notifications.onDeliveryStatusChanged, "deliveryId", "o1", open, cancelled);
    assert.equal((await h.read("deliveries/o1")).receiverPhone, undefined);
  });

  test("LR-73 taken before the create trigger ran: nothing is moved (its driver may see them)", async () => {
    const d = deliveryOrder({ paymentMethod: "cash", ...RECEIVER });
    await h.seed("deliveries/o1", { ...d, driverId: D, status: "driverAssigned" });
    await deliveryCreated("o1", d);
    assert.equal((await h.read("deliveries/o1")).receiverPhone, RECEIVER.receiverPhone);
    assert.equal(await priv("deliveries"), null);
  });

  test("LR-74 a stale assignment event (order since cancelled or held by another driver) copies nothing", async () => {
    const d = deliveryOrder({ paymentMethod: "cash", ...RECEIVER });
    await h.seed("deliveries/o1", d);
    await deliveryCreated("o1", d);
    const open = await h.read("deliveries/o1");
    const staleTaken = { ...open, driverId: D, status: "driverAssigned" };
    for (const now of [{ ...open, status: "cancelled" }, { ...open, driverId: "someone-else", status: "driverAssigned" }]) {
      await h.seed("deliveries/o1", now);
      await statusRun(notifications.onDeliveryStatusChanged, "deliveryId", "o1", open, staleTaken);
      assert.equal((await h.read("deliveries/o1")).receiverPhone, undefined);
    }
  });

  test("LR-75 Gas instructions and condition notes: sealed at creation, back on assignment", async () => {
    await h.seed(`drivers/${D}`, goodsDriver({ isAvailable: false, currentTripId: "o1" }));
    const g = gasOrder({ paymentMethod: "cash", ...PRICED, ...GAS_PRIVATE });
    await h.seed("gas_orders/o1", g);
    await gasCreated("o1", g);
    const open = await h.read("gas_orders/o1");
    for (const k of Object.keys(GAS_PRIVATE)) assert.equal(open[k], undefined);
    assert.equal(open.deliveryAddress, "C", "addresses stay: the apps require them");
    const taken = { ...open, driverId: D, status: "driverAssigned" };
    await h.seed("gas_orders/o1", taken);
    await statusRun(notifications.onGasOrderStatusChanged, "orderId", "o1", open, taken);
    const o = await h.read("gas_orders/o1");
    for (const [k, v] of Object.entries(GAS_PRIVATE)) assert.equal(o[k], v);
  });
});

describe("Gas price at creation and acceptance", () => {
  test("LR-80 an underpriced cash order is cancelled before it is offered", async () => {
    await h.seed("drivers/bike", goodsDriver({ uid: "bike" }));
    const g = gasOrder({ paymentMethod: "cash", totalPrice: 40 });
    await h.seed("gas_orders/o1", g);
    await gasCreated("o1", g);
    const o = await h.read("gas_orders/o1");
    assert.equal(o.status, "cancelled");
    // Release v5: any amount other than the server's price (was: below it).
    assert.equal(o.cancellationReason, "price_changed");
    assert.equal(o.paymentRejectedReason, "price_changed");
    assert.equal(await alerts("gas_price_rejected"), 1);
    assert.equal(await inbox("bike"), 0);
  });

  test("LR-81 the brand premium is part of the price: dropping it cancels the order", async () => {
    const g = gasOrder({ paymentMethod: "cash", preferredBrand: "totalEnergies", ...PRICED });
    await h.seed("gas_orders/o1", g);
    await gasCreated("o1", g);
    assert.equal((await h.read("gas_orders/o1")).paymentRejectedReason, "price_changed");
  });

  test("LR-82 configured prices apply (production's 3 kg refill is above the built-in one)", async () => {
    await h.seed("settings/platform", { platformFeePercent: 15, gas: { refill3kg: 50 } });
    const g = gasOrder({ paymentMethod: "cash", ...PRICED });
    await h.seed("gas_orders/o1", g);
    await gasCreated("o1", g);
    assert.equal((await h.read("gas_orders/o1")).status, "cancelled");
    const ok = gasOrder({ paymentMethod: "cash", totalPrice: 62, deliveryFee: 12 });
    await h.seed("gas_orders/o2", ok);
    await gasCreated("o2", ok);
    assert.equal((await h.read("gas_orders/o2")).status, "pendingApproval");
  });

  test("LR-83 an order the server cannot price is cancelled, not offered", async () => {
    const g = gasOrder({ paymentMethod: "cash", cylinderSize: "12.5kg" });
    await h.seed("gas_orders/o1", g);
    await gasCreated("o1", g);
    assert.equal((await h.read("gas_orders/o1")).paymentRejectedReason, "price_unverifiable");
  });

  test("LR-84 correctly priced orders of every type are offered", async () => {
    await h.seed("drivers/bike", goodsDriver({ uid: "bike" }));
    const orders = {
      a: gasOrder({ paymentMethod: "cash", totalPrice: 54, deliveryFee: 12, preferredBrand: "totalEnergies" }),
      b: gasOrder({ paymentMethod: "cash", refillType: "pickupAndReturn", totalPrice: 82, deliveryFee: 42 }),
      c: gasOrder({ paymentMethod: "cash", refillType: "newCylinder", totalPrice: 192, deliveryFee: 12 }),
      d: gasOrder({ paymentMethod: "cash", refillType: "commercialBulk", quantity: 2, totalPrice: 92, deliveryFee: 12 }),
    };
    for (const [id, g] of Object.entries(orders)) {
      await h.seed(`gas_orders/${id}`, g);
      await gasCreated(id, g);
      assert.equal((await h.read(`gas_orders/${id}`)).status, "pendingApproval", id);
    }
    assert.equal(await alerts("gas_price_rejected"), 0);
    assert.ok(await inbox("bike") >= 1, "offered (which vehicles get which type is the dispatch policy's)");
  });

  test("LR-85 acceptGasOrder refuses an underpriced order listed before the create trigger ran", async () => {
    await h.seed(`drivers/${D}`, goodsDriver());
    await h.seed("gas_orders/o1", gasOrder({ paymentMethod: "cash", totalPrice: 40, deliveryFee: 12 }));
    const r = await acceptJob("gas", D, "o1");
    assert.deepEqual([r.success, r.detail], [false, "price_changed"]);
    assert.equal((await h.read("gas_orders/o1")).driverId, null);
    await h.seed("gas_orders/o2", gasOrder({ paymentMethod: "cash", ...PRICED }));
    assert.equal((await acceptJob("gas", D, "o2")).success, true);
  });
});

describe("Gas price: production configuration and edge cases", () => {
  // settings/platform.gas in production (read 2026-10-27): refill3kg 50, full3kg 100, baseFare 7.5,
  // perKm 0.5, minDeliveryFee 12, roundTripFee 30, commercialRate 1; other prices = built-in.
  const PROD = { gas: { refill3kg: 50, full3kg: 100, baseFare: 7.5, perKm: 0.5, minDeliveryFee: 12,
    roundTripFee: 30, commercialRate: 1 } };
  const o = (x) => ({ cylinderSize: "kg3", refillType: "exchangeEmpty", quantity: 1, ...x });
  /** The app's delivery charge (gas_pricing.dart) at a one-way distance, legs and round trip. */
  const appDelivery = (km, legs, roundTrip = 0) =>
    Math.max(PROD.gas.minDeliveryFee, PROD.gas.baseFare + PROD.gas.perKm * km * legs) + roundTrip;

  test("LR-86 residual under production prices: what the floor cannot see is the distance above the minimum fee", () => {
    // The app clamps its distance to 1–30 km; the floor charges as at 1 km.
    assert.equal(gasFareFloor(o(), PROD), 62, "50 + max(12, 7.5 + 0.5)");
    assert.equal(appDelivery(1, 1), 12);
    assert.equal(appDelivery(9, 1), 12, "the fee stays at the minimum up to 9 km one-way");
    assert.equal(appDelivery(30, 1) - appDelivery(1, 1), 10.5, "largest gap, one leg");
    assert.equal(gasFareFloor(o({ refillType: "pickupAndReturn" }), PROD), 92, "50 + 12 + 30");
    assert.equal(appDelivery(30, 2, 30) - appDelivery(1, 2, 30), 25.5, "largest gap, pickup and return");
  });

  test("LR-87 exact to the pesewa (release v5: was one pesewa under passing)", () => {
    const floor = gasFareFloor(o(), PROD);
    assert.equal(gasOrderPriceProblem(o({ totalPrice: floor, deliveryFee: 12 }), PROD), null);
    assert.equal(gasOrderPriceProblem(o({ totalPrice: floor - 0.01, deliveryFee: 12 }), PROD), "price_changed");
    assert.equal(gasOrderPriceProblem(o({ totalPrice: floor + 0.01, deliveryFee: 12 }), PROD), "price_changed");
    assert.equal(gasOrderPriceProblem(o({ totalPrice: floor, deliveryFee: 12.01 }), PROD), "price_changed");
    assert.equal(gasOrderPriceProblem(o({ totalPrice: 0 }), PROD), "price_missing");
    assert.equal(gasOrderPriceProblem(o({ totalPrice: "62" }), PROD), "price_missing");
  });

  test("LR-88 quantity, brand and type combine as in the app", () => {
    // New cylinder: 100 × 2, shell +4 % → 208, + 12.
    assert.equal(gasFareFloor(o({ refillType: "newCylinder", quantity: 2, preferredBrand: "shell" }), PROD), 220);
    // Commercial bulk with a premium brand: 50 × 3 × 1 → 150, totalEnergies +5 % → 157.5, + 12.
    assert.equal(gasFareFloor(o({ refillType: "commercialBulk", quantity: 3, preferredBrand: "totalEnergies" }), PROD),
      169.5);
  });
});

describe("the unpaid-assignment guard decides on current data", () => {
  const run = (collection, before, afterDoc) => statusRun(
    collection === "deliveries" ? notifications.onDeliveryStatusChanged : notifications.onGasOrderStatusChanged,
    collection === "deliveries" ? "deliveryId" : "orderId", "o1", before, afterDoc);

  for (const [collection, doc, referenceType] of [
    ["deliveries", deliveryOrder(), "delivery"], ["gas_orders", gasOrder(), "gas_order"]]) {
    test(`LR-90 ${collection}: a stale event (taken unpaid) after the payment was linked keeps the order`, async () => {
      await h.seed(`drivers/${D}`, goodsDriver({ isAvailable: false, currentTripId: "o1" }));
      await seedHold(referenceType, 100);
      const staleTaken = { ...doc, driverId: D, status: "driverAssigned" };
      await h.seed(`${collection}/o1`, { ...staleTaken, escrowId: "e1" }); // paid meanwhile
      await run(collection, doc, staleTaken);
      assert.equal((await h.read(`${collection}/o1`)).status, "driverAssigned");
      assert.equal(await alerts("wallet_payment_rejected"), 0);
      assert.equal((await h.read("escrows/e1")).status, "HELD");
    });

    test(`LR-91 ${collection}: repeated events cancel an unpaid order once`, async () => {
      const taken = { ...doc, driverId: D, status: "driverAssigned" };
      await h.seed(`${collection}/o1`, taken);
      await Promise.all([run(collection, doc, taken), run(collection, doc, taken)]);
      await run(collection, doc, taken);
      assert.equal((await h.read(`${collection}/o1`)).status, "cancelled");
      assert.equal(await alerts("wallet_payment_rejected"), 1);
    });

    test(`LR-92 ${collection}: a stale event for an order that moved on changes nothing`, async () => {
      const taken = { ...doc, driverId: D, status: "driverAssigned" };
      await h.seed(`${collection}/o1`, { ...taken, status: collection === "deliveries" ? "pickupEnroute" : "driverEnRoute" });
      await run(collection, doc, taken);
      assert.notEqual((await h.read(`${collection}/o1`)).status, "cancelled");
    });
  }

  for (const [service, collection, referenceType, doc] of [
    ["delivery", "deliveries", "delivery", deliveryOrder()], ["gas", "gas_orders", "gas_order", gasOrder(PRICED)]]) {
    test(`LR-93 ${service}: payment linking racing a claim never leaves an unpaid job taken`, async () => {
      await codeSecureApps();
      await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
      for (let i = 0; i < 4; i++) {
        await h.seed(`drivers/${D}`, goodsDriver());
        const id = `race${i}`;
        const { escrowId } = await hold({ amount: doc.totalPrice ?? doc.estimatedFare, serviceType: "x", referenceType });
        // A delivery is booked with its own quote and verified (release v5 round 3).
        const order = service === "delivery"
          ? h.deliveryStamped(await h.quotedDelivery(doc, { quoteId: `q-${id}`, settings: DPLATFORM }))
          : doc;
        await h.seed(`${collection}/${id}`, order);
        const [, accepted] = await Promise.all([
          attach({ escrowId, referenceId: id, referenceType }).catch(() => null),
          acceptJob(service, D, id),
        ]);
        const o = await h.read(`${collection}/${id}`);
        const e = await h.read(`escrows/${escrowId}`);
        if (accepted.success) {
          assert.equal(o.driverId, D);
          assert.deepEqual([e.status, e.referenceId], ["HELD", id], "taken only once paid");
        } else {
          assert.equal(accepted.detail, "payment_not_verified");
          assert.equal(o.driverId, null);
        }
      }
    });
  }
});
