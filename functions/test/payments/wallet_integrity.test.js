// Wallet payment integrity for Ride and Delivery (Batch 1):
//   • a legitimate wallet ride or delivery is linked, dispatched and settled;
//   • a hold that does not match the booking's price is never linked: the
//     order is cancelled and the hold returned, once;
//   • a wallet order without a valid hold is never offered to drivers;
//   • a hold cannot be returned while an order still names it;
//   • cash takings are never paid out as wallet funds;
//   • legacy no-hold wallet settlement charges only the booked fare;
//   • cash settlement is unchanged.
// Firestore emulator, local stub gateway and stubbed FCM only.

"use strict";

process.env.GCLOUD_PROJECT = "demo-ctsgo-payments";
process.env.PAYMENTS_MODE = "stub";
process.env.BRIDGE_CLIENT_KEY = "fake-client-key";
process.env.BRIDGE_SECRET_KEY = "fake-secret-key";
process.env.BRIDGE_SERVICE_ID = "1";
const index = require("../../index");
const h = require("./helpers");

const { test, describe, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const escrow = require("../../escrow");
const trips = require("../../trips");
const bridge = require("../../bridge");
const wallet = require("../../wallet");
const { rideFareFloor } = require("../../payment_verification");

const { GeoPoint, Timestamp } = h.admin.firestore;
const P = "wi-passenger";
const OTHER = "wi-other";
const D = "wi-driver";
const PICKUP = new GeoPoint(5.556, -0.1969);
const DROPOFF = new GeoPoint(5.6037, -0.155); // about 7 km
const FAR = new GeoPoint(5.78, -0.02); // about 31 km

const multicasts = [];
Object.defineProperty(h.admin, "messaging", {
  configurable: true, writable: true,
  value: () => ({
    sendEachForMulticast: async (m) => {
      multicasts.push(m);
      return { successCount: m.tokens.length, failureCount: 0,
        responses: m.tokens.map(() => ({ success: true })) };
    },
    send: async () => "stub-id",
  }),
});

const code = (e) => e.code ?? e.httpErrorCode?.canonicalName;
const hold = (amount, referenceType, uid = P) =>
  h.callCallable(escrow.holdBalance, uid, { amount, serviceType: referenceType, referenceType });
const attach = (escrowId, referenceId, referenceType, uid = P) =>
  h.callCallable(escrow.attachEscrowToOrder, uid, { escrowId, referenceId, referenceType });
const refundOnError = (escrowId, uid = P) =>
  h.callCallable(escrow.refundEscrowOnError, uid, { escrowId, reason: "order_creation_failed" });

const tripDoc = (o = {}) => ({ passengerId: P, driverId: null, status: "searching",
  serviceType: "taxi", paymentMethod: "wallet", estimatedFare: 40, pickupLocation: PICKUP,
  dropoffLocation: DROPOFF, pickupAddress: "A", dropoffAddress: "B", createdAt: Timestamp.now(), ...o });
const deliveryDoc = (o = {}) => ({ passengerId: P, driverId: null, status: "pending",
  paymentMethod: "wallet", estimatedFare: 100, pickupLocation: PICKUP,
  dropoffLocation: DROPOFF, vehicleType: "Okada", weightTier: "Small", isFragile: false,
  requiresHelpers: false, createdAt: Timestamp.now(), ...o });

async function createTrip(id, data) {
  await h.seed(`trips/${id}`, data);
  await index.onTripCreatedNotify.run({ params: { tripId: id }, data: { data: () => data } });
}
// Orders as Passenger 1.0.1 creates them: no code on the order; the code is
// server-held in order_completion_codes (completion_codes.js), as the create
// triggers store it. Wallet Delivery/Gas refuse orders that carry one.
const CODES = { deliveries: "4321", gas_orders: "777" };
// Deliveries are booked with their server quote (release v5 round 3) whenever
// one is possible at their fare; an underpriced or impossible booking (only an
// older build makes one) stays unquoted.
const PLATFORM = { platformFeePercent: 15, delivery: h.DELIVERY_RATES };
async function withQuote(collection, orderId, doc) {
  if (collection !== "deliveries" || doc.deliveryQuoteId !== undefined) return doc;
  try {
    h.metersForFare(doc, PLATFORM);
  } catch (_) {
    return doc;
  }
  return h.quotedDelivery(doc, { quoteId: `q-${orderId}`, settings: PLATFORM });
}
async function seedOrder(path, doc) {
  const [collection, orderId] = path.split("/");
  doc = await withQuote(collection, orderId, doc);
  await h.seed(path, doc);
  await h.seed(`order_completion_codes/${collection}_${orderId}`, { collection, orderId,
    passengerId: doc.passengerId ?? null, code: CODES[collection], attempts: 0 });
}

async function createDelivery(id, data) {
  await h.seed("settings/platform", PLATFORM);
  await seedOrder(`deliveries/${id}`, data);
  const stored = await h.read(`deliveries/${id}`);
  await index.onDeliveryCreated.run({ params: { deliveryId: id }, data: { data: () => stored } });
}

/** Writes a change and runs an update trigger with the stored before/after. */
async function update(fn, collection, id, changes) {
  const before = await h.read(`${collection}/${id}`);
  const afterDoc = { ...before, ...changes };
  await h.db().doc(`${collection}/${id}`).set(afterDoc);
  const params = { trips: { tripId: id }, deliveries: { deliveryId: id } }[collection];
  if (fn) {
    await fn.run({ params, data: { before: { data: () => before }, after: { data: () => afterDoc } } });
  }
  return afterDoc;
}

const walletOf = (uid = P) => h.read(`wallets/${uid}`);
async function assertWallet(balance, held, uid = P) {
  const w = await walletOf(uid);
  assert.equal(w.balance, balance, "wallet balance");
  assert.equal(w.heldBalance, held, "wallet heldBalance");
}
const refunds = (escrowId) => h.count("ledger", "idempotencyKey", `refund_${escrowId}`);

let stub;
before(async () => { stub = await h.startStubGateway(); });
after(async () => { await stub.close(); h.fft.cleanup(); });
beforeEach(async () => {
  multicasts.length = 0;
  stub.reset();
  await h.clearFirestore();
  // Wallet Delivery/Gas offered: the state after the Passenger 1.0.1 / Driver 1.0.3 rollout.
  await h.enableDeliveryGasWallet();
  await h.seed(`wallets/${P}`, { userId: P, balance: 200, heldBalance: 0 });
  await h.seed(`wallets/${OTHER}`, { userId: OTHER, balance: 200, heldBalance: 0 });
  await h.seed(`drivers/${D}`, { uid: D, walletBalance: 0, totalEarnings: 0 });
  await h.seed("drivers/ride-near", { uid: "ride-near", role: "driver_hailing", serviceType: "taxi",
    vehicleType: "taxi", isApproved: true, isOnline: true, isAvailable: true, location: PICKUP, fcmToken: "t-ride" });
  await h.seed("drivers/del-near", { uid: "del-near", role: "driver_delivery", serviceType: "delivery",
    vehicleType: "motorcycle", isApproved: true, isOnline: true, isAvailable: true, location: PICKUP, fcmToken: "t-del" });
});

// ── Ride ────────────────────────────────────────────────────────────────────

describe("Ride wallet payments", () => {
  test("WI-R01 a legitimate wallet ride is linked by the server, dispatched and settled once", async () => {
    const { escrowId } = await hold(40, "trip");
    await createTrip("r1", tripDoc({ escrowId }));
    const e = await h.read(`escrows/${escrowId}`);
    assert.equal(e.referenceId, "r1", "linked before dispatch");
    assert.equal(multicasts.length, 1, "offered to drivers");
    assert.equal((await h.read("trips/r1")).status, "searching");
    // The app's own attach call afterwards is a harmless repeat.
    assert.deepEqual(await attach(escrowId, "r1", "trip"), { success: true, alreadyAttached: true });

    await update(null, "trips", "r1", { driverId: D, status: "tripStarted" });
    await update(trips.onTripCompleted, "trips", "r1", { status: "completed", passengerConfirmed: true });
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "RELEASED");
    await assertWallet(160, 0);
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 34);
  });

  test("WI-R02 a hold below the route's minimum price: cancelled, not dispatched, refunded once", async () => {
    const far = tripDoc({ dropoffLocation: FAR, estimatedFare: 20 });
    assert.ok(rideFareFloor(far, null) > 20, "the route's minimum is above the hold");
    const { escrowId } = await hold(20, "trip");
    await createTrip("r2", { ...far, escrowId });
    const t = await h.read("trips/r2");
    assert.equal(t.status, "cancelled");
    assert.equal(t.paymentRejectedReason, "hold_below_minimum_price");
    assert.equal(multicasts.length, 0, "never offered to drivers");
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "REFUNDED");
    await assertWallet(200, 0);
    // The cancellation trigger then finds nothing more to refund.
    await trips.onTripCancelled.run({ params: { tripId: "r2" }, data: {
      before: { data: () => ({ ...t, status: "searching" }) }, after: { data: () => t } } });
    await assertWallet(200, 0);
    assert.equal(await refunds(escrowId), 1);
    assert.equal(await h.count("admin_alerts", "type", "wallet_payment_rejected"), 1);
  });

  test("WI-R03 a hold that differs from the booked fare is refused the same way", async () => {
    const { escrowId } = await hold(40, "trip");
    await createTrip("r3", tripDoc({ escrowId, estimatedFare: 60 }));
    assert.equal((await h.read("trips/r3")).paymentRejectedReason, "hold_amount_mismatch");
    assert.equal(multicasts.length, 0);
    await assertWallet(200, 0);
  });

  test("WI-R04 a wallet ride with no hold is cancelled before any driver sees it", async () => {
    await createTrip("r4", tripDoc());
    const t = await h.read("trips/r4");
    assert.equal(t.status, "cancelled");
    assert.equal(t.paymentRejectedReason, "wallet_hold_missing");
    assert.equal(multicasts.length, 0);
    await assertWallet(200, 0);
  });

  test("WI-R05 someone else's hold: the ride is cancelled and that hold is untouched", async () => {
    const { escrowId } = await hold(40, "trip", OTHER);
    await createTrip("r5", tripDoc({ escrowId }));
    const t = await h.read("trips/r5");
    assert.equal(t.status, "cancelled");
    assert.equal(multicasts.length, 0);
    await trips.onTripCancelled.run({ params: { tripId: "r5" }, data: {
      before: { data: () => ({ ...t, status: "searching" }) }, after: { data: () => t } } });
    const e = await h.read(`escrows/${escrowId}`);
    assert.equal(e.status, "HELD");
    assert.equal(e.referenceId, null);
    await assertWallet(160, 40, OTHER);
    await assertWallet(200, 0);
  });

  test("WI-R06 the app's attach with a mismatched hold is refused, cancels and refunds once", async () => {
    const { escrowId } = await hold(40, "trip");
    const doc = tripDoc({ escrowId, estimatedFare: 70 });
    await h.seed("trips/r6", doc); // the dispatcher has not run yet
    await assert.rejects(attach(escrowId, "r6", "trip"), (e) =>
      code(e) === "failed-precondition" && e.details?.reason === "hold_amount_mismatch");
    assert.equal((await h.read("trips/r6")).status, "cancelled");
    await assertWallet(200, 0);
    // The dispatcher then runs on the creation event and changes nothing more.
    await index.onTripCreatedNotify.run({ params: { tripId: "r6" }, data: { data: () => doc } });
    assert.equal(multicasts.length, 0);
    await assertWallet(200, 0);
    assert.equal(await refunds(escrowId), 1);
  });

  test("WI-R07 cash rides are dispatched exactly as before", async () => {
    await createTrip("r7", tripDoc({ paymentMethod: "cash", escrowId: null }));
    assert.equal((await h.read("trips/r7")).status, "searching");
    assert.equal(multicasts.length, 1);
    assert.equal((await h.db().collection("escrows").get()).size, 0);
  });

  test("WI-R08 insufficient balance: no hold, and a wallet ride created anyway is cancelled", async () => {
    await assert.rejects(hold(500, "trip"), (e) => code(e) === "failed-precondition");
    await createTrip("r8", tripDoc({ estimatedFare: 500 }));
    assert.equal((await h.read("trips/r8")).status, "cancelled");
    assert.equal(multicasts.length, 0);
    await assertWallet(200, 0);
  });
});

// ── Delivery ────────────────────────────────────────────────────────────────

describe("Delivery wallet payments", () => {
  test("WI-D01 a legitimate wallet delivery is dispatched once linked, and settles once", async () => {
    const { escrowId } = await hold(100, "delivery");
    await createDelivery("d1", deliveryDoc());
    assert.equal(multicasts.length, 0, "not offered before its payment is linked");
    const before = await h.read("deliveries/d1");
    assert.deepEqual(await attach(escrowId, "d1", "delivery"), { success: true });
    const after = await h.read("deliveries/d1");
    assert.equal(after.escrowId, escrowId, "the server records escrowId with the link");
    await index.onDeliveryPaymentAttached.run({ params: { deliveryId: "d1" },
      data: { before: { data: () => before }, after: { data: () => after } } });
    assert.equal(multicasts.length, 1, "offered once paid");

    await update(null, "deliveries", "d1", { driverId: D, status: "arrivedAtDropoff" });
    await update(trips.onDeliveryCompleted, "deliveries", "d1", { status: "completed", otpSubmitted: "4321" });
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "RELEASED");
    await assertWallet(100, 0);
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 85);
  });

  test("WI-D02 an underpriced delivery: attach refused, order cancelled, hold returned once", async () => {
    const { escrowId } = await hold(10, "delivery");
    await createDelivery("d2", deliveryDoc({ estimatedFare: 10 }));
    await assert.rejects(attach(escrowId, "d2", "delivery"), (e) =>
      code(e) === "failed-precondition" && e.details?.reason === "hold_below_minimum_price");
    const d = await h.read("deliveries/d2");
    assert.equal(d.status, "cancelled");
    assert.equal(d.escrowId, undefined, "never linked");
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "REFUNDED");
    await assertWallet(200, 0);
    // The app's rollback afterwards returns nothing more.
    assert.equal((await refundOnError(escrowId)).success, true);
    await assertWallet(200, 0);
    assert.equal(await refunds(escrowId), 1);
    assert.equal(multicasts.length, 0);
  });

  test("WI-D03 a wallet delivery never linked to a hold is cancelled once it is stale", async () => {
    const t0 = Date.now();
    const { escrowId } = await hold(100, "delivery");
    await createDelivery("d3", deliveryDoc());
    await seedOrder("deliveries/taken", deliveryDoc({ status: "driverAssigned", driverId: D }));
    await seedOrder("deliveries/cash", deliveryDoc({ paymentMethod: "cash" }));
    await seedOrder("deliveries/paid", deliveryDoc({ escrowId: "some-hold" }));
    assert.equal(multicasts.length, 0, "never offered unpaid");

    assert.deepEqual(await escrow.cancelUnpaidWalletDeliveries({ now: t0 + 5 * 60e3 }), { cancelled: 0 });
    assert.deepEqual(await escrow.cancelUnpaidWalletDeliveries({ now: t0 + 11 * 60e3 }), { cancelled: 1 });
    assert.equal((await h.read("deliveries/d3")).status, "cancelled");
    assert.equal((await h.read("deliveries/d3")).paymentRejectedReason, "wallet_hold_missing");
    for (const id of ["taken", "cash", "paid"]) {
      assert.notEqual((await h.read(`deliveries/${id}`)).status, "cancelled", id);
    }
    // Its unlinked hold can then be rolled back by the app (nothing names it).
    await refundOnError(escrowId);
    await assertWallet(200, 0);
  });

  test("WI-D04 an escrowId that does not name this delivery's linked hold is not dispatched", async () => {
    const { escrowId } = await hold(100, "delivery");
    await createDelivery("d4", deliveryDoc());
    const before = await h.read("deliveries/d4");
    const after = await update(null, "deliveries", "d4", { escrowId }); // never attached
    await index.onDeliveryPaymentAttached.run({ params: { deliveryId: "d4" },
      data: { before: { data: () => before }, after: { data: () => after } } });
    assert.equal(multicasts.length, 0);
  });

  test("WI-D05 cash deliveries are dispatched at creation exactly as before", async () => {
    await createDelivery("d5", deliveryDoc({ paymentMethod: "cash" }));
    assert.equal(multicasts.length, 1);
  });
});

// ── Refund on error ─────────────────────────────────────────────────────────

describe("refundEscrowOnError", () => {
  for (const [collection, doc] of [["trips", tripDoc()], ["deliveries", deliveryDoc()],
    ["gas_orders", { passengerId: P, status: "pendingApproval", totalPrice: 40 }]]) {
    test(`WI-F01 refused while a ${collection} document names the hold`, async () => {
      const { escrowId } = await hold(40, "trip");
      await h.seed(`${collection}/o1`, { ...doc, escrowId });
      await assert.rejects(refundOnError(escrowId), (e) => code(e) === "failed-precondition");
      assert.equal((await h.read(`escrows/${escrowId}`)).status, "HELD");
      await assertWallet(160, 40);
    });
  }

  test("WI-F02 an unlinked, unnamed hold is returned once, however often it is asked", async () => {
    const { escrowId } = await hold(40, "trip");
    await Promise.all([refundOnError(escrowId), refundOnError(escrowId), refundOnError(escrowId)]);
    assert.equal((await refundOnError(escrowId)).success, true);
    await assertWallet(200, 0);
    assert.equal(await refunds(escrowId), 1);
  });

  test("WI-F03 another user cannot return someone's hold", async () => {
    const { escrowId } = await hold(40, "trip");
    await assert.rejects(refundOnError(escrowId, OTHER), (e) => code(e) === "permission-denied");
    await assertWallet(160, 40);
  });
});

// ── Driver payouts ──────────────────────────────────────────────────────────

describe("cash takings are not wallet funds", () => {
  const payout = (amount, uid) =>
    h.callCallable(bridge.initiateBridgePayout, uid, { amount, phone: "0200000002", network: "MTN" });
  const seedDriver = (id, o) => h.seed(`drivers/${id}`, { displayName: "Driver", phone: "0200000002",
    isApproved: true, commissionOwed: 0, ...o });

  test("WI-P01 a cash-only driver (no walletBalance) cannot withdraw lifetime earnings", async () => {
    await seedDriver("cash1", { totalEarnings: 500 });
    await assert.rejects(payout(50, "cash1"), (e) => code(e) === "failed-precondition");
    const d = await h.read("drivers/cash1");
    assert.equal(d.totalEarnings, 500);
    assert.equal(d.activeWithdrawalId, undefined);
    assert.equal((await h.db().collection("withdrawals").get()).size, 0);
    assert.equal(stub.requests.length, 0);
  });

  test("WI-P02 walletBalance 0 with cash earnings is refused too", async () => {
    await seedDriver("cash2", { walletBalance: 0, totalEarnings: 800 });
    await assert.rejects(payout(50, "cash2"), (e) => code(e) === "failed-precondition");
    assert.equal((await h.db().collection("withdrawals").get()).size, 0);
  });

  test("WI-P03 only the wallet-funded part is withdrawable when a driver has both", async () => {
    await seedDriver("mixed", { walletBalance: 100, totalEarnings: 600 });
    await assert.rejects(payout(150, "mixed"), (e) => code(e) === "failed-precondition");
    const ok = await payout(100, "mixed");
    assert.equal(ok.status, "pending_review");
    const d = await h.read("drivers/mixed");
    assert.equal(d.walletBalance, 0);
    assert.equal(d.pendingWithdrawal, 100);
    // A second request while one is open is refused (one open withdrawal).
    await h.db().doc("drivers/mixed").update({ walletBalance: 100 });
    await assert.rejects(payout(50, "mixed"), (e) => code(e) === "failed-precondition");
    assert.equal((await h.db().collection("withdrawals").get()).size, 1);
    assert.equal(stub.requests.length, 0, "review only: nothing is sent to the gateway");
  });

  test("WI-P04 getDriverWallet reports walletBalance as the balance, lifetime earnings separately", async () => {
    await seedDriver("rep", { walletBalance: 30, totalEarnings: 700 });
    const r = await h.callCallable(wallet.getDriverWallet, "rep", {});
    assert.equal(r.balance, 30);
    assert.equal(r.totalEarnings, 700);
    assert.equal((await h.read("driver_wallets/rep")).balance, 30);
  });
});

// ── Legacy no-hold wallet settlement ────────────────────────────────────────

describe("legacy wallet orders without a hold", () => {
  async function completeTrip(id, data, changes) {
    await h.seed(`trips/${id}`, data);
    await update(trips.onTripCompleted, "trips", id, changes);
    return h.read(`trips/${id}`);
  }

  test("WI-L01 charged the booked fare, not driver-written outcome fields; driver paid as wallet funds", async () => {
    const t = await completeTrip("L1", tripDoc({ driverId: D, status: "tripStarted" }),
      { status: "completed", passengerConfirmed: true, actualFare: 999, actualDistanceKm: 80 });
    assert.equal(t.walletProcessed, true);
    assert.equal(t.actualFare, 40);
    await assertWallet(160, 0);
    const d = await h.read(`drivers/${D}`);
    assert.equal(d.walletBalance, 34);
    assert.equal(d.totalEarnings, 34);
    assert.equal(await h.count("ledger", "idempotencyKey", "wallet_trip_L1"), 1);
  });

  test("WI-L02 a booked fare below the route's minimum is not charged", async () => {
    const t = await completeTrip("L2", tripDoc({ driverId: D, status: "tripStarted",
      dropoffLocation: FAR, estimatedFare: 5 }), { status: "completed", passengerConfirmed: true });
    assert.equal(t.settlementStatus, "failed");
    assert.equal(t.settlementFailureReason, "legacy_wallet_fare_unverified");
    await assertWallet(200, 0);
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 0);
  });

  test("WI-L03 legacy delivery: below the minimum is blocked; the booked fare is charged otherwise", async () => {
    await seedOrder("deliveries/L3", deliveryDoc({ driverId: D, status: "arrivedAtDropoff", estimatedFare: 5 }));
    await update(trips.onDeliveryCompleted, "deliveries", "L3", { status: "completed", otpSubmitted: "4321" });
    assert.equal((await h.read("deliveries/L3")).settlementFailureReason, "legacy_wallet_fare_unverified");
    await assertWallet(200, 0);

    await seedOrder("deliveries/L4", deliveryDoc({ driverId: D, status: "arrivedAtDropoff", estimatedFare: 60 }));
    await update(trips.onDeliveryCompleted, "deliveries", "L4", { status: "completed", otpSubmitted: "4321" });
    assert.equal((await h.read("deliveries/L4")).walletProcessed, true);
    await assertWallet(140, 0);
  });

  test("WI-L04 insufficient balance: nothing charged, driver not credited", async () => {
    await h.seed(`wallets/${P}`, { userId: P, balance: 10, heldBalance: 0 });
    const t = await completeTrip("L5", tripDoc({ driverId: D, status: "tripStarted" }),
      { status: "completed", passengerConfirmed: true });
    assert.equal(t.settlementStatus, "failed");
    await assertWallet(10, 0);
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 0);
  });
});

// ── Cash settlement unchanged ───────────────────────────────────────────────

describe("cash settlement", () => {
  test("WI-C01 a cash ride records commission owed and touches no wallet", async () => {
    await h.seed("trips/C1", tripDoc({ paymentMethod: "cash", driverId: D, status: "tripStarted" }));
    await update(trips.onTripCompleted, "trips", "C1", { status: "completed", passengerConfirmed: true });
    assert.equal((await h.read("trips/C1")).walletProcessed, true);
    await assertWallet(200, 0);
    const d = await h.read(`drivers/${D}`);
    assert.equal(d.totalEarnings, 40);
    assert.equal(d.commissionOwed, 6);
    assert.equal(d.walletBalance, 0, "cash is never withdrawable");
    assert.equal(await h.count("ledger", "idempotencyKey", "commission_C1"), 1);
  });

  test("WI-C02 a cash delivery records commission owed and touches no wallet", async () => {
    await seedOrder("deliveries/C2", deliveryDoc({ paymentMethod: "cash", driverId: D, status: "arrivedAtDropoff" }));
    await update(trips.onDeliveryCompleted, "deliveries", "C2", { status: "completed", otpSubmitted: "4321" });
    assert.equal((await h.read("deliveries/C2")).walletProcessed, true);
    await assertWallet(200, 0);
    const d = await h.read(`drivers/${D}`);
    assert.equal(d.totalEarnings, 100);
    assert.equal(d.commissionOwed, 15);
    assert.equal(d.walletBalance, 0);
  });
});
