// Release v5 review round:
//  WG  — the dedicated Delivery/Gas wallet switch (escrow.js
//        walletDeliveryGasAvailable): off unless app_config/payments.
//        deliveryGasWalletEnabled === true AND the code-secure minimum
//        versions are required; raising the minimums alone never enables it;
//        Ride wallet is unaffected.
//  CL  — the cash offer lifecycle through the real triggers: cash orders
//        reach the right offer collection without any wallet payment; unpaid
//        or unlinked wallet orders never become listed or claimable;
//        duplicate, concurrent and retried events publish and notify once.
//  E2E — the amount a driver is shown is the amount settled, and the
//        commission is taken once.
// Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const { Timestamp, GeoPoint } = require("firebase-admin/firestore");
const h = require("./helpers");
const escrow = require("../../escrow");
const notifications = require("../../notifications");
const trips = require("../../trips");
const { acceptJob } = require("../../accept_job");

const P = "wg-passenger";
const P2 = "wg-other-passenger";
const D = "wg-driver";
const PT = new GeoPoint(5.55671, -0.18234);
const PROD = { platformFeePercent: 15, gas: { refill3kg: 50, full3kg: 100, baseFare: 7.5, perKm: 0.5,
  minDeliveryFee: 12, roundTripFee: 30, commercialRate: 1 },
  // Delivery rates (test fixture: the app's built-in defaults) for server quotes.
  delivery: h.DELIVERY_RATES };

const hold = (data, uid = P) => h.callCallable(escrow.holdBalance, uid, data);
const attach = (data, uid = P) => h.callCallable(escrow.attachEscrowToOrder, uid, data);
const driver = (o = {}) => ({ uid: D, role: "driver_delivery", serviceType: "delivery", vehicleType: "motorcycle",
  isApproved: true, signupStep: "approved", isOnline: true, isAvailable: true, location: PT,
  lastLocationUpdate: Timestamp.now(), ...o });
const delivery = (o = {}) => ({ passengerId: P, driverId: null, status: "pending", vehicleType: "Okada",
  weightTier: "Small", parcelType: "Documents", paymentMethod: "cash", pickupLocation: PT, dropoffLocation: PT,
  pickupAddress: "12 Oxford St, Osu, Accra", dropoffAddress: "7 Ring Rd, Adabraka, Accra", estimatedFare: 30,
  createdAt: Timestamp.now(), ...o });
// Priced (exactly, as the app writes it) for whatever type/size/brand [o] sets.
const gas = (o = {}) => h.gasPriced({ passengerId: P, driverId: null, status: "pendingApproval",
  refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1, paymentMethod: "cash", pickupLocation: PT,
  deliveryLocation: PT, deliveryAddress: "12 Oxford St, Osu, Accra", createdAt: Timestamp.now(), ...o }, PROD);

const created = (fn, id, data) => fn.run({ params: { deliveryId: id, orderId: id }, data: { data: () => data } });
const updated = (fn, id, before, afterDoc) => fn.run({ params: { deliveryId: id, orderId: id },
  data: { before: { data: () => before }, after: { data: () => afterDoc } } });
const inbox = async () => (await h.db().collection("drivers").doc(D).collection("notifications").get()).size;
const COLL = { deliveries: ["delivery_offers", "gas_order_offers"], gas_orders: ["gas_order_offers", "delivery_offers"] };
const CREATE = { deliveries: () => notifications.onDeliveryCreated, gas_orders: () => notifications.onGasOrderCreated };
const ATTACHED = { deliveries: () => notifications.onDeliveryPaymentAttached,
  gas_orders: () => notifications.onGasOrderPaymentAttached };
const SERVICE = { deliveries: "delivery", gas_orders: "gas" };
const REF = { deliveries: "delivery", gas_orders: "gas_order" };

// Deliveries as Passenger 1.0.1 books them: with the server quote for the route.
async function place(collection, id, data) {
  if (collection === "deliveries" && data.deliveryQuoteId === undefined) {
    data = await h.quotedDelivery(data, { quoteId: `q-${id}-${Date.now()}`, settings: PROD });
  }
  await h.seed(`${collection}/${id}`, data);
  await created(CREATE[collection](), id, data);
}

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed("settings/platform", PROD);
  await h.seed(`wallets/${P}`, { balance: 1000, heldBalance: 0 });
  await h.seed(`drivers/${D}`, driver());
});

describe("WG: the Delivery/Gas wallet switch", () => {
  const refused = (referenceType) => assert.rejects(hold({ amount: 30, serviceType: "x", referenceType }),
    (e) => e.code === "failed-precondition" && e.details?.reason === "wallet_delivery_gas_unavailable");

  test("WG-01 raising the minimum versions alone does not enable wallet Delivery/Gas", async () => {
    await h.seed("app_config/mobile", { passengerMinimumVersion: "1.0.1", driverMinimumVersion: "1.0.3" });
    await refused("delivery");
    await refused("gas_order");
    await h.seed("app_config/mobile", { passengerMinimumVersion: "2.0.0", driverMinimumVersion: "2.0.0" });
    await refused("delivery");
  });

  test("WG-02 only the boolean true switches it on", async () => {
    await h.seed("app_config/mobile", { passengerMinimumVersion: "1.0.1", driverMinimumVersion: "1.0.3" });
    for (const v of [false, "true", 1, null, {}, "yes"]) {
      await h.seed("app_config/payments", { deliveryGasWalletEnabled: v });
      await refused("delivery");
      await refused("gas_order");
    }
    await h.seed("app_config/payments", { otherFlag: true });
    await refused("gas_order");
  });

  test("WG-03 the switch alone does not enable it while old apps are still allowed", async () => {
    await h.seed("app_config/payments", { deliveryGasWalletEnabled: true });
    await refused("delivery");
    await h.seed("app_config/mobile", { passengerMinimumVersion: "1.0.1", driverMinimumVersion: "1.0.2" });
    await refused("gas_order");
  });

  test("WG-04 switch on + minimums: holds are taken; switched off again: attach refuses and refunds", async () => {
    await h.enableDeliveryGasWallet();
    const d = await hold({ amount: 30, serviceType: "x", referenceType: "delivery" });
    assert.equal(d.success, true);
    await h.seed("deliveries/d1", delivery({ paymentMethod: "wallet" }));
    await h.seed("app_config/payments", { deliveryGasWalletEnabled: false });
    await assert.rejects(attach({ escrowId: d.escrowId, referenceId: "d1", referenceType: "delivery" }),
      (e) => e.details?.reason === "wallet_delivery_gas_unavailable");
    assert.equal((await h.read(`escrows/${d.escrowId}`)).status, "REFUNDED");
    assert.equal((await h.read("deliveries/d1")).status, "cancelled");
  });

  test("WG-05 Ride wallet holds and links whatever the switch says", async () => {
    for (const payments of [null, { deliveryGasWalletEnabled: false }, { deliveryGasWalletEnabled: true }]) {
      await h.clearFirestore();
      await h.seed(`wallets/${P}`, { balance: 500, heldBalance: 0 });
      if (payments) await h.seed("app_config/payments", payments);
      const r = await hold({ amount: 100, serviceType: "taxi", referenceType: "trip" });
      assert.equal(r.success, true, JSON.stringify(payments));
      await h.seed("trips/t1", { passengerId: P, status: "searching", paymentMethod: "wallet",
        escrowId: r.escrowId, serviceType: "taxi", estimatedFare: 100, pickupLocation: PT,
        dropoffLocation: new GeoPoint(5.6037, -0.187) });
      assert.equal((await attach({ escrowId: r.escrowId, referenceId: "t1", referenceType: "trip" })).success, true);
    }
  });

  test("WG-06 hold-integrity checks still apply when switched on (amount must equal the booking)", async () => {
    await h.enableDeliveryGasWallet();
    const g = await hold({ amount: 10, serviceType: "x", referenceType: "gas_order" });
    await h.seed("gas_orders/g1", gas({ paymentMethod: "wallet" }));
    await assert.rejects(attach({ escrowId: g.escrowId, referenceId: "g1", referenceType: "gas_order" }));
    assert.equal((await h.read(`escrows/${g.escrowId}`)).referenceId ?? null, null, "never linked");
  });
});

describe("CL: cash offers, unpaid and unlinked wallet orders", () => {
  for (const collection of ["deliveries", "gas_orders"]) {
    const make = collection === "deliveries" ? delivery : gas;
    const [mine, other] = COLL[collection];

    test(`CL-01 ${collection}: a cash order is listed in ${mine} only, with no wallet payment anywhere`, async () => {
      await place(collection, "o1", make());
      assert.ok(await h.read(`${mine}/o1`));
      assert.equal(await h.read(`${other}/o1`), null);
      assert.equal(await h.count("escrows", "referenceId", "o1"), 0);
      assert.equal(await inbox(), 1);
      assert.equal((await acceptJob(SERVICE[collection], D, "o1")).success, true);
      assert.equal(await h.read(`${mine}/o1`), null);
    });

    test(`CL-02 ${collection}: an order without a payment method is dispatched as cash`, async () => {
      const o = make(); delete o.paymentMethod;
      await place(collection, "o1", o);
      assert.equal((await h.read(`${mine}/o1`)).paymentMethod, "cash");
    });

    test(`CL-03 ${collection}: an unpaid wallet order is never listed or claimable (switch on or off)`, async () => {
      for (const on of [false, true]) {
        await h.clearFirestore();
        await h.seed("settings/platform", PROD);
        await h.seed(`drivers/${D}`, driver());
        if (on) await h.enableDeliveryGasWallet();
        await place(collection, "o1", make({ paymentMethod: "wallet" }));
        assert.equal(await h.read(`${mine}/o1`), null);
        assert.equal(await inbox(), 0);
        assert.equal((await acceptJob(SERVICE[collection], D, "o1")).detail, "payment_not_verified");
      }
    });

    test(`CL-04 ${collection}: an escrowId that is not this order's held payment lists nothing, claims nothing`, async () => {
      await h.enableDeliveryGasWallet();
      const bad = {
        missing: null,
        otherOwner: { userId: P2, status: "HELD", referenceId: "o1", referenceType: REF[collection] },
        otherOrder: { userId: P, status: "HELD", referenceId: "o9", referenceType: REF[collection] },
        refunded: { userId: P, status: "REFUNDED", referenceId: "o1", referenceType: REF[collection] },
        wrongType: { userId: P, status: "HELD", referenceId: "o1", referenceType: "trip" },
        unlinked: { userId: P, status: "HELD", referenceId: null, referenceType: REF[collection] },
      };
      for (const [name, e] of Object.entries(bad)) {
        const o = make({ paymentMethod: "wallet" });
        await place(collection, "o1", o);
        if (e) await h.seed(`escrows/e-${name}`, { amount: o.totalPrice ?? o.estimatedFare, ...e });
        const paid = { ...(await h.read(`${collection}/o1`)), escrowId: `e-${name}` };
        await h.seed(`${collection}/o1`, paid);
        await updated(ATTACHED[collection](), "o1", { ...paid, escrowId: null }, paid);
        assert.equal(await h.read(`${mine}/o1`), null, name);
        assert.equal((await acceptJob(SERVICE[collection], D, "o1")).detail, "payment_not_verified", name);
      }
      assert.equal(await inbox(), 0);
    });

    test(`CL-05 ${collection}: duplicate and concurrent create events publish one offer and notify once`, async () => {
      const o = collection === "deliveries"
        ? await h.quotedDelivery(make(), { quoteId: "q-dup", settings: PROD }) : make();
      await h.seed(`${collection}/o1`, o);
      await created(CREATE[collection](), "o1", o);
      await Promise.all([1, 2, 3].map(() => created(CREATE[collection](), "o1", o)));
      assert.ok(await h.read(`${mine}/o1`));
      assert.equal(await inbox(), 1);
      if (collection === "gas_orders") {
        const first = (await h.read("gas_orders/o1")).verifiedPrice;
        await created(CREATE[collection](), "o1", o);
        assert.deepEqual((await h.read("gas_orders/o1")).verifiedPrice, first, "stamped once");
      }
    });

    test(`CL-06 ${collection}: a retry after a run that stopped before publishing lists it once`, async () => {
      // As if the first run crashed after its price stamp / completion code,
      // before the offer was written.
      const o = make();
      await place(collection, "o1", o);
      await h.db().collection(mine).doc("o1").delete();
      await h.db().collection("drivers").doc(D).collection("notifications").get()
        .then((s) => Promise.all(s.docs.map((d) => d.ref.delete())));
      await created(CREATE[collection](), "o1", o);
      assert.ok(await h.read(`${mine}/o1`));
      assert.equal(await inbox(), 1);
    });

    test(`CL-07 ${collection}: cancelled before acceptance — withdrawn, and a replay does not relist`, async () => {
      const o = make();
      await place(collection, "o1", o);
      const cancelled = { ...(await h.read(`${collection}/o1`)), status: "cancelled" };
      await h.seed(`${collection}/o1`, cancelled);
      const statusFn = collection === "deliveries" ? notifications.onDeliveryStatusChanged
        : notifications.onGasOrderStatusChanged;
      await updated(statusFn, "o1", o, cancelled);
      assert.equal(await h.read(`${mine}/o1`), null);
      await created(CREATE[collection](), "o1", o);
      assert.equal(await h.read(`${mine}/o1`), null);
      assert.equal((await acceptJob(SERVICE[collection], D, "o1")).success, false);
    });

    test(`CL-08 ${collection}: a paid wallet order is listed once its own hold is linked (switch on)`, async () => {
      await h.enableDeliveryGasWallet();
      const o = make({ paymentMethod: "wallet" });
      const amount = o.totalPrice ?? o.estimatedFare;
      const r = await hold({ amount, serviceType: "x", referenceType: REF[collection] });
      await place(collection, "o1", o);
      assert.equal(await h.read(`${mine}/o1`), null);
      await attach({ escrowId: r.escrowId, referenceId: "o1", referenceType: REF[collection] });
      // The write that recorded escrowId (attach or the app) fires the trigger.
      const paid = { ...(await h.read(`${collection}/o1`)), escrowId: r.escrowId };
      const before = { ...paid, escrowId: null };
      await h.seed(`${collection}/o1`, paid);
      const ev = () => updated(ATTACHED[collection](), "o1", before, paid);
      await Promise.all([ev(), ev()]);
      assert.ok(await h.read(`${mine}/o1`));
      assert.equal(await inbox(), 1);
      assert.equal((await acceptJob(SERVICE[collection], D, "o1")).success, true);
    });
  }
});

describe("E2E: shown fare = settled amount; commission once", () => {
  async function deliverGas(id, runs) {
    const before = await h.read(`gas_orders/${id}`);
    const afterDoc = { ...before, status: "delivered", otpSubmitted: "4821" };
    await h.seed(`gas_orders/${id}`, afterDoc);
    await h.seed(`order_completion_codes/gas_orders_${id}`, { code: "4821", passengerId: P });
    await Promise.all(Array.from({ length: runs }, () =>
      updated(trips.onGasOrderCompleted, id, { ...afterDoc, status: "returning" }, afterDoc)));
  }

  test("E2E-01 cash Gas: offer total = stamp = ledger gross; commission once across repeated events", async () => {
    await place("gas_orders", "g1", gas({ refillType: "newCylinder", quantity: 2, preferredBrand: "shell" }));
    const shown = (await h.read("gas_order_offers/g1")).totalPrice;
    assert.equal(shown, 220);
    assert.equal((await acceptJob("gas", D, "g1")).success, true);
    await deliverGas("g1", 3);
    const ledger = await h.read("ledger/commission_gas_g1");
    assert.deepEqual([ledger.grossFare, ledger.amount], [shown, 33]);
    assert.equal(await h.count("ledger", "referenceId", "g1"), 1);
    const drv = await h.read(`drivers/${D}`);
    assert.deepEqual([drv.totalEarnings, drv.commissionOwed], [220, 33]);
  });

  test("E2E-02 wallet Gas (switch on): offer total = hold = amount released; released once", async () => {
    await h.enableDeliveryGasWallet();
    const o = gas({ paymentMethod: "wallet" });
    const r = await hold({ amount: o.totalPrice, serviceType: "x", referenceType: "gas_order" });
    await place("gas_orders", "g1", o);
    await attach({ escrowId: r.escrowId, referenceId: "g1", referenceType: "gas_order" });
    const paid = { ...(await h.read("gas_orders/g1")), escrowId: r.escrowId };
    await h.seed("gas_orders/g1", paid);
    await updated(notifications.onGasOrderPaymentAttached, "g1", { ...paid, escrowId: null }, paid);
    const shown = (await h.read("gas_order_offers/g1")).totalPrice;
    assert.equal(shown, 62);
    assert.equal((await acceptJob("gas", D, "g1")).success, true);
    await deliverGas("g1", 3);
    const e = await h.read(`escrows/${r.escrowId}`);
    assert.deepEqual([e.status, e.amount], ["RELEASED", shown]);
    assert.equal((await h.read("gas_orders/g1")).walletProcessed, true);
    assert.equal(await h.count("ledger", "idempotencyKey", `capture_${r.escrowId}`), 1);
  });
});
