// End-to-end escrow flows starting from the real holdBalance callable.
//
//   Flow A: hold → create order → attach → complete → settle
//   Flow B: hold → create order → attach → cancel → refund
//
// Callables run through firebase-functions-test as a signed-in user;
// triggers run through their v2 `.run()` with the stored before/after
// documents. Orders are written the way the passenger app writes them
// (Admin SDK here, so Firestore rules are covered by the rules suite, not
// by this file). Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const escrow = require("../../escrow");
const trips = require("../../trips");

const { GeoPoint } = h.admin.firestore;
const P = "e2e-passenger";
const D = "e2e-driver";
const OTHER = "e2e-someone-else";

const hold = (amount, referenceType, uid = P) =>
  h.callCallable(escrow.holdBalance, uid, { amount, serviceType: "delivery", referenceType });
const attach = (escrowId, referenceId, referenceType, uid = P) =>
  h.callCallable(escrow.attachEscrowToOrder, uid, { escrowId, referenceId, referenceType });
const refundOnError = (escrowId, uid = P) =>
  h.callCallable(escrow.refundEscrowOnError, uid, { escrowId, reason: "order_creation_failed" });

/** Runs a document-updated trigger for a stored document change. */
async function update(fn, collection, id, changes) {
  const before = await h.read(`${collection}/${id}`);
  const afterDoc = { ...before, ...changes };
  await h.db().doc(`${collection}/${id}`).set(afterDoc);
  const params = { trips: { tripId: id }, deliveries: { deliveryId: id },
    gas_orders: { orderId: id } }[collection];
  if (fn) {
    await fn.run({ params, data: { before: { data: () => before }, after: { data: () => afterDoc } } });
  }
  return afterDoc;
}

const wallet = () => h.read(`wallets/${P}`);
const driver = () => h.read(`drivers/${D}`);
const ledger = (key) => h.count("ledger", "idempotencyKey", key);

/** Money is conserved: balance + held never changes inside the wallet. */
async function assertWallet(balance, held) {
  const w = await wallet();
  assert.equal(w.balance, balance, "wallet balance");
  assert.equal(w.heldBalance, held, "wallet heldBalance");
}

async function seedAccounts({ balance = 200 } = {}) {
  await h.seed("settings/platform", PLATFORM);
  await h.seed(`wallets/${P}`, { balance, heldBalance: 0 });
  await h.seed(`drivers/${D}`, { walletBalance: 0, totalEarnings: 0 });
}

function deliveryDoc(fare) {
  // DeliveryRequest.toFirestore: no escrowId at creation.
  return {
    passengerId: P, driverId: null, status: "pending", paymentMethod: "wallet",
    estimatedFare: fare,
    pickupLocation: new GeoPoint(5.556, -0.1969), dropoffLocation: new GeoPoint(5.6037, -0.155),
    vehicleType: "Okada", weightTier: "Small", isFragile: false, requiresHelpers: false,
  };
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

after(() => h.fft.cleanup());
// Wallet Delivery and Gas are offered once app_config/mobile requires the
// app versions that keep the completion code secret (escrow.js); these tests
// cover that state.
beforeEach(async () => { await h.clearFirestore(); await h.enableDeliveryGasWallet(); });

// ── holdBalance itself ────────────────────────────────────────────────────────

describe("holdBalance", () => {
  test("E2E-01 holds the amount: balance down, held up, HELD escrow, HOLD ledger", async () => {
    await seedAccounts();
    const r = await hold(100, "delivery");
    assert.equal(r.success, true);
    await assertWallet(100, 100);
    const e = await h.read(`escrows/${r.escrowId}`);
    assert.equal(e.status, "HELD");
    assert.equal(e.userId, P);
    assert.equal(e.amount, 100);
    assert.equal(e.platformFee, 15);
    assert.equal(e.driverNet, 85);
    assert.equal(e.referenceId, null);
    assert.equal(e.referenceType, "delivery");
    assert.equal(await ledger(r.escrowId), 1, "HOLD ledger entry keyed by escrowId");
  });

  test("E2E-02 insufficient balance: refused with the shortfall, nothing changes", async () => {
    await seedAccounts({ balance: 30 });
    await assert.rejects(hold(100, "delivery"), (e) => {
      assert.equal(e.code, "failed-precondition");
      assert.equal(e.details.shortfall, 70);
      return true;
    });
    await assertWallet(30, 0);
    assert.equal((await h.db().collection("escrows").get()).size, 0);
  });

  test("E2E-03 invalid amounts and unauthenticated callers are refused", async () => {
    await seedAccounts();
    for (const amount of [0, -5, null, undefined, NaN]) {
      await assert.rejects(hold(amount, "delivery"), (e) => e.code === "invalid-argument",
        `amount ${amount}`);
    }
    await assert.rejects(hold(10, "delivery", null), (e) => e.code === "unauthenticated");
    await assertWallet(200, 0);
  });

  test("E2E-04 a string amount is refused with invalid-argument and changes nothing", async () => {
    await seedAccounts();
    await assert.rejects(hold("100", "delivery"), (e) => e.code === "invalid-argument");
    await assertWallet(200, 0);
    assert.equal((await h.db().collection("escrows").get()).size, 0);
  });
});

// ── Flow A: hold → create → attach → complete → settle ────────────────────────

describe("Flow A: settle on completion", () => {
  test("E2E-10 delivery", async () => {
    await seedAccounts();
    const { escrowId } = await hold(100, "delivery");
    await seedOrder("deliveries/A1", deliveryDoc(100));
    assert.equal((await attach(escrowId, "A1", "delivery")).success, true);
    await update(null, "deliveries", "A1", { escrowId }); // app's follow-up update
    await update(null, "deliveries", "A1", { driverId: D, status: "driverAssigned" });
    await update(null, "deliveries", "A1", { status: "arrivedAtDropoff" });
    await update(trips.onDeliveryCompleted, "deliveries", "A1",
      { status: "completed", otpSubmitted: "4321" });

    const e = await h.read(`escrows/${escrowId}`);
    assert.equal(e.status, "RELEASED");
    assert.equal(e.referenceId, "A1");
    await assertWallet(100, 0); // charged once, nothing left held
    assert.equal((await driver()).walletBalance, 85);
    assert.equal(await ledger(`capture_${escrowId}`), 1);
    const d = await h.read("deliveries/A1");
    assert.equal(d.walletProcessed, true);
    assert.equal(d.settlementStatus, "completed");
    assert.equal(d.actualFare, 100);

    // Idempotency: duplicate and concurrent completion events change nothing.
    const done = await h.read("deliveries/A1");
    const ev = { params: { deliveryId: "A1" },
      data: { before: { data: () => ({ ...done, status: "arrivedAtDropoff" }) },
        after: { data: () => done } } };
    await Promise.all([trips.onDeliveryCompleted.run(ev), trips.onDeliveryCompleted.run(ev)]);
    // A later recovery pass and reconciliation do not touch it.
    const rec = await escrow.recoverStaleEscrows({ now: Date.now() + 3 * 3600e3 });
    assert.equal(rec.refunded, 0);
    const report = await escrow.buildReconciliationReport({ now: Date.now() + 3 * 3600e3 });
    assert.equal(report.stuckEscrows, 0);
    await assertWallet(100, 0);
    assert.equal((await driver()).walletBalance, 85);
    assert.equal(await ledger(`capture_${escrowId}`), 1);
  });

  test("E2E-11 a cancel after completion does not refund or claim a refund", async () => {
    await seedAccounts();
    const { escrowId } = await hold(100, "delivery");
    await seedOrder("deliveries/A2", deliveryDoc(100));
    await attach(escrowId, "A2", "delivery");
    await update(null, "deliveries", "A2", { escrowId, driverId: D, status: "arrivedAtDropoff" });
    await update(trips.onDeliveryCompleted, "deliveries", "A2",
      { status: "completed", otpSubmitted: "4321" });
    // Party rules allow the passenger to write status "cancelled" afterwards.
    await update(trips.onDeliveryCancelled, "deliveries", "A2", { status: "cancelled" });

    await assertWallet(100, 0);
    assert.equal((await driver()).walletBalance, 85);
    assert.equal(await ledger(`refund_${escrowId}`), 0);
    // (Firestore rules now stop parties writing this; the trigger is still
    // checked for server-side or legacy writes.)
    assert.notEqual((await h.read("deliveries/A2")).escrowRefunded, true);
    // Recognised as a cancellation after completion before any refund
    // attempt (the escrow is already released here).
    assert.equal(await h.count("admin_alerts", "type", "delivery_cancel_after_completion"), 1);
  });

  test("E2E-12 gas order", async () => {
    await seedAccounts();
    const { escrowId } = await hold(60, "gas_order");
    await seedOrder("gas_orders/A3", { passengerId: P, driverId: null, status: "pendingApproval",
      paymentMethod: "wallet", totalPrice: 60, refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1 });
    await attach(escrowId, "A3", "gas_order");
    await update(null, "gas_orders", "A3", { escrowId });
    await update(null, "gas_orders", "A3", { driverId: D, status: "driverArrived" });
    await update(trips.onGasOrderCompleted, "gas_orders", "A3",
      { status: "delivered", otpSubmitted: "777" });

    assert.equal((await h.read(`escrows/${escrowId}`)).status, "RELEASED");
    await assertWallet(140, 0);
    assert.equal((await driver()).walletBalance, 51);
    assert.equal(await ledger(`capture_${escrowId}`), 1);
    assert.equal((await h.read("gas_orders/A3")).walletProcessed, true);
  });

  test("E2E-13 ride (trip carries escrowId from creation)", async () => {
    await seedAccounts();
    const { escrowId } = await hold(40, "trip");
    await h.seed("trips/A4", { passengerId: P, driverId: null, status: "searching",
      paymentMethod: "wallet", estimatedFare: 40, escrowId, serviceType: "taxi",
      pickupLocation: new GeoPoint(5.556, -0.1969), dropoffLocation: new GeoPoint(5.6037, -0.155) });
    await attach(escrowId, "A4", "trip");
    await update(null, "trips", "A4", { driverId: D, status: "tripStarted" });
    await update(trips.onTripCompleted, "trips", "A4",
      { status: "completed", passengerConfirmed: true });

    assert.equal((await h.read(`escrows/${escrowId}`)).status, "RELEASED");
    await assertWallet(160, 0);
    assert.equal((await driver()).walletBalance, 34);
    assert.equal(await ledger(`capture_${escrowId}`), 1);
  });
});

// ── Flow B: hold → create → attach → cancel → refund ──────────────────────────

describe("Flow B: refund on cancellation", () => {
  test("E2E-20 delivery", async () => {
    await seedAccounts();
    const { escrowId } = await hold(100, "delivery");
    await seedOrder("deliveries/B1", deliveryDoc(100));
    await attach(escrowId, "B1", "delivery");
    await update(null, "deliveries", "B1", { escrowId });
    await update(trips.onDeliveryCancelled, "deliveries", "B1", { status: "cancelled" });

    assert.equal((await h.read(`escrows/${escrowId}`)).status, "REFUNDED");
    await assertWallet(200, 0);
    assert.equal(await ledger(`refund_${escrowId}`), 1);
    assert.equal((await h.read("deliveries/B1")).escrowRefunded, true);

    // Repeated cancel events and a later recovery pass do not refund again.
    const cancelled = await h.read("deliveries/B1");
    await trips.onDeliveryCancelled.run({ params: { deliveryId: "B1" }, data: {
      before: { data: () => ({ ...cancelled, status: "pending", escrowRefunded: false }) },
      after: { data: () => ({ ...cancelled, escrowRefunded: false }) } } });
    await escrow.recoverStaleEscrows({ now: Date.now() + 3 * 3600e3 });
    await assertWallet(200, 0);
    assert.equal(await ledger(`refund_${escrowId}`), 1);

    // A completion written after the refund is refused, not paid.
    await update(trips.onDeliveryCompleted, "deliveries", "B1",
      { status: "completed", driverId: D, otpSubmitted: "4321" });
    const d = await h.read("deliveries/B1");
    assert.notEqual(d.walletProcessed, true);
    assert.equal(d.settlementFailureReason, "escrow_refunded");
    assert.equal((await driver()).walletBalance, 0);
  });

  test("E2E-21 gas order", async () => {
    await seedAccounts();
    const { escrowId } = await hold(60, "gas_order");
    await h.seed("gas_orders/B2", { passengerId: P, driverId: null, status: "pendingApproval",
      paymentMethod: "wallet", totalPrice: 60, refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1 });
    await attach(escrowId, "B2", "gas_order");
    await update(null, "gas_orders", "B2", { escrowId });
    await update(trips.onGasOrderCancelled, "gas_orders", "B2", { status: "cancelled" });
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "REFUNDED");
    await assertWallet(200, 0);
    assert.equal(await ledger(`refund_${escrowId}`), 1);
  });

  test("E2E-22 ride cancelled by the passenger", async () => {
    await seedAccounts();
    const { escrowId } = await hold(40, "trip");
    await h.seed("trips/B3", { passengerId: P, driverId: null, status: "searching",
      paymentMethod: "wallet", estimatedFare: 40, escrowId, serviceType: "taxi",
      pickupLocation: new GeoPoint(5.556, -0.1969), dropoffLocation: new GeoPoint(5.6037, -0.155) });
    await attach(escrowId, "B3", "trip");
    await update(trips.onTripCancelled, "trips", "B3", { status: "cancelledByPassenger" });
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "REFUNDED");
    await assertWallet(200, 0);
    assert.equal(await ledger(`refund_${escrowId}`), 1);
  });
});

// ── Ownership and failure recovery ────────────────────────────────────────────

describe("ownership and failure recovery", () => {
  test("E2E-30 another user cannot attach or roll back someone's escrow", async () => {
    await seedAccounts();
    const { escrowId } = await hold(100, "delivery");
    await seedOrder("deliveries/C1", { ...deliveryDoc(100), passengerId: OTHER });
    await assert.rejects(attach(escrowId, "C1", "delivery", OTHER),
      (e) => e.code === "permission-denied");
    await assert.rejects(attach(escrowId, "C1", "delivery", P),
      (e) => e.code === "permission-denied", "not the caller's order");
    await assert.rejects(refundOnError(escrowId, OTHER), (e) => e.code === "permission-denied");
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "HELD");
    await assertWallet(100, 100);
  });

  test("E2E-31 order creation failed: the app's rollback refunds once", async () => {
    await seedAccounts();
    const { escrowId } = await hold(100, "delivery");
    // createDelivery threw; the app calls refundEscrowOnError (twice for gas).
    assert.equal((await refundOnError(escrowId)).success, true);
    assert.equal((await refundOnError(escrowId)).success, true);
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "REFUNDED");
    await assertWallet(200, 0);
    assert.equal(await ledger(`refund_${escrowId}`), 1);
  });

  test("E2E-32 rollback is refused once the escrow is attached to an order", async () => {
    await seedAccounts();
    const { escrowId } = await hold(100, "delivery");
    await seedOrder("deliveries/C2", deliveryDoc(100));
    await attach(escrowId, "C2", "delivery");
    await assert.rejects(refundOnError(escrowId), (e) => e.code === "failed-precondition");
    assert.equal((await h.read(`escrows/${escrowId}`)).status, "HELD");
    await assertWallet(100, 100);
  });

  test("E2E-33 attach failed after the order was created: settlement blocks, money stays held", async () => {
    await seedAccounts();
    const { escrowId } = await hold(100, "delivery");
    await seedOrder("deliveries/C3", deliveryDoc(100));
    // The attach call never reached the server; the app still wrote escrowId.
    await update(null, "deliveries", "C3", { escrowId, driverId: D, status: "arrivedAtDropoff" });
    await update(trips.onDeliveryCompleted, "deliveries", "C3",
      { status: "completed", otpSubmitted: "4321" });
    assert.equal((await h.read("deliveries/C3")).settlementFailureReason, "escrow_unattached");
    await assertWallet(100, 100);
    assert.equal((await driver()).walletBalance, 0);
    // Recovery does not auto-refund a completed order's escrow.
    const rec = await escrow.recoverStaleEscrows({ now: Date.now() + 3 * 3600e3 });
    assert.equal(rec.refunded, 0);
    assert.deepEqual(rec.review.map((r) => r.reason), ["settled_order_still_held"]);
  });

  test("E2E-34 two holds, two orders: each settles from its own escrow only", async () => {
    await seedAccounts({ balance: 300 });
    const a = await hold(100, "delivery");
    const b = await hold(50, "delivery");
    await seedOrder("deliveries/C4", deliveryDoc(100));
    await seedOrder("deliveries/C5", deliveryDoc(50));
    await attach(a.escrowId, "C4", "delivery");
    await attach(b.escrowId, "C5", "delivery");
    // Cross-attaching is refused.
    await assert.rejects(attach(b.escrowId, "C4", "delivery"), (e) => e.code === "failed-precondition");
    await update(null, "deliveries", "C4", { escrowId: a.escrowId, driverId: D, status: "arrivedAtDropoff" });
    await update(null, "deliveries", "C5", { escrowId: b.escrowId });
    await update(trips.onDeliveryCompleted, "deliveries", "C4", { status: "completed", otpSubmitted: "4321" });
    await update(trips.onDeliveryCancelled, "deliveries", "C5", { status: "cancelled" });
    await assertWallet(200, 0); // 300 − 100 settled; 50 refunded
    assert.equal((await driver()).walletBalance, 85);
  });
});
