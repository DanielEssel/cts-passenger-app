// Admin alert visibility and payload safety (Phase 1G).
//
// The admin console's alert bell (ctsride-admin AdminAlertsBell) lists
// admin_alerts where read == false, newest createdAt first, and shows each
// alert's `message`. An escrow or settlement alert without those fields is
// stored but never seen. Every alert the five release targets and their
// shared settlement and recovery code write must therefore be visible, and
// must carry ids and reasons only: never a completion code, phone number,
// address or payment credential. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const h = require("./helpers");
const escrow = require("../../escrow");
const trips = require("../../trips");

const { Timestamp } = h.admin.firestore;
const HOUR = 60 * 60 * 1000;
const ago = (ms) => Timestamp.fromDate(new Date(Date.now() - ms));
const P = "alv-passenger";
const OTHER = "alv-other";
const D = "alv-driver";

// Cancellation triggers notify the passenger: capture instead of sending.
Object.defineProperty(h.admin, "messaging", {
  configurable: true, writable: true,
  value: () => ({ send: async () => "stub-id" }),
});

const FORBIDDEN_KEYS = ["deliveryOtp", "otpSubmitted", "completionCode", "code", "phone",
  "phoneNumber", "customer_number", "address", "pickupAddress", "dropoffAddress",
  "pickupLocation", "dropoffLocation", "fcmToken", "secret"];

/** The alerts the bell would list, as the bell queries them. */
async function bell() {
  const snap = await h.db().collection("admin_alerts")
    .where("read", "==", false).orderBy("createdAt", "desc").limit(50).get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

/**
 * Exactly one alert of [type] exists, the bell lists it, and it carries a
 * useful message and none of [secrets] (codes, phone numbers) anywhere.
 */
async function assertVisible(type, { secrets = [] } = {}) {
  const all = (await h.db().collection("admin_alerts").where("type", "==", type).get()).docs;
  assert.equal(all.length, 1, `one ${type} alert`);
  const a = all[0].data();
  assert.equal(a.read, false, `${type}: read is false`);
  assert.ok(a.createdAt instanceof Timestamp, `${type}: createdAt is a timestamp`);
  assert.equal(typeof a.message, "string");
  assert.ok(a.message.trim().length >= 20, `${type}: a useful message`);
  for (const k of FORBIDDEN_KEYS) assert.ok(!(k in a), `${type}: no ${k} field`);
  const json = JSON.stringify(a);
  for (const s of secrets) assert.ok(!json.includes(s), `${type}: does not contain ${s}`);
  assert.ok((await bell()).some((b) => b.id === all[0].id), `${type}: listed by the bell query`);
  return a;
}

const update = (fn, params, before, afterDoc) => fn.run({ params,
  data: { before: { data: () => before }, after: { data: () => afterDoc } } });

async function seedEscrow(id, o = {}) {
  await h.seed(`escrows/${id}`, { userId: P, amount: 100, platformFee: 15, driverNet: 85,
    status: "HELD", heldAt: ago(30 * 60e3), referenceId: "o1", ...o });
}

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed("settings/platform", { platformFeePercent: 15 });
  await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
  await h.seed(`wallets/${OTHER}`, { balance: 0, heldBalance: 100 });
  await h.seed(`drivers/${D}`, { walletBalance: 0, totalEarnings: 0 });
});

describe("settlement failures", () => {
  test("ALV-01 trip_settlement_failed", async () => {
    await seedEscrow("e1", { userId: OTHER, referenceType: "trip" });
    const t = { passengerId: P, driverId: D, paymentMethod: "wallet", escrowId: "e1",
      status: "completed", passengerConfirmed: true, estimatedFare: 100, serviceType: "taxi" };
    await h.seed("trips/o1", t);
    await update(trips.onTripCompleted, { tripId: "o1" }, { ...t, status: "tripStarted" }, t);
    const a = await assertVisible("trip_settlement_failed");
    assert.deepEqual([a.tripId, a.escrowId, a.reason], ["o1", "e1", "escrow_owner_mismatch"]);
  });

  test("ALV-02 delivery_settlement_failed", async () => {
    await seedEscrow("e1", { userId: OTHER, referenceType: "delivery" });
    const d = { passengerId: P, driverId: D, paymentMethod: "wallet", escrowId: "e1",
      status: "completed", estimatedFare: 100, deliveryOtp: "7319", otpSubmitted: "7319" };
    await h.seed("deliveries/o1", d);
    await update(trips.onDeliveryCompleted, { deliveryId: "o1" }, { ...d, status: "arrivedAtDropoff" }, d);
    const a = await assertVisible("delivery_settlement_failed", { secrets: ["7319"] });
    assert.equal(a.reason, "escrow_owner_mismatch");
  });

  test("ALV-03 gas_settlement_failed", async () => {
    await seedEscrow("e1", { userId: OTHER, referenceType: "gas_order" });
    const g = { passengerId: P, driverId: D, paymentMethod: "wallet", escrowId: "e1",
      status: "delivered", totalPrice: 100, deliveryOtp: "5821", otpSubmitted: "5821" };
    await h.seed("gas_orders/o1", g);
    await update(trips.onGasOrderCompleted, { orderId: "o1" }, { ...g, status: "returning" }, g);
    const a = await assertVisible("gas_settlement_failed", { secrets: ["5821"] });
    assert.equal(a.reason, "escrow_owner_mismatch");
  });

  test("ALV-04 gas_self_order (delivered by the customer's own account)", async () => {
    const g = { passengerId: D, driverId: D, paymentMethod: "cash",
      status: "delivered", totalPrice: 100, deliveryOtp: "4407", otpSubmitted: "4407" };
    await h.seed("gas_orders/o1", g);
    await update(trips.onGasOrderCompleted, { orderId: "o1" }, { ...g, status: "returning" }, g);
    const a = await assertVisible("gas_self_order", { secrets: ["4407"] });
    assert.equal(a.orderId, "o1");
  });
});

describe("completion codes", () => {
  const delivery = (o) => ({ passengerId: P, driverId: D, paymentMethod: "cash",
    status: "completed", estimatedFare: 100, ...o });
  const gas = (o) => ({ passengerId: P, driverId: D, paymentMethod: "cash",
    status: "delivered", totalPrice: 100, ...o });

  test("ALV-10 delivery_otp_missing never carries the stored code", async () => {
    const d = delivery({ deliveryOtp: "6142", otpSubmitted: null });
    await h.seed("deliveries/o1", d);
    await update(trips.onDeliveryCompleted, { deliveryId: "o1" }, { ...d, status: "arrivedAtDropoff" }, d);
    await assertVisible("delivery_otp_missing", { secrets: ["6142"] });
  });

  test("ALV-11 delivery_otp_mismatch carries neither code", async () => {
    const d = delivery({ deliveryOtp: "6142", otpSubmitted: "9035" });
    await h.seed("deliveries/o1", d);
    await update(trips.onDeliveryCompleted, { deliveryId: "o1" }, { ...d, status: "arrivedAtDropoff" }, d);
    await assertVisible("delivery_otp_mismatch", { secrets: ["6142", "9035"] });
  });

  test("ALV-12 gas_code_missing never carries the submitted code", async () => {
    const g = gas({ otpSubmitted: "2468" });
    await h.seed("gas_orders/o1", g);
    await update(trips.onGasOrderCompleted, { orderId: "o1" }, { ...g, status: "returning" }, g);
    const a = await assertVisible("gas_code_missing", { secrets: ["2468"] });
    assert.equal(a.reason, "stored_code_missing");
  });

  test("ALV-13 otp_mismatch (gas) carries neither code", async () => {
    const g = gas({ deliveryOtp: "4321", otpSubmitted: "1111" });
    await h.seed("gas_orders/o1", g);
    await update(trips.onGasOrderCompleted, { orderId: "o1" }, { ...g, status: "returning" }, g);
    const a = await assertVisible("otp_mismatch", { secrets: ["4321", "1111"] });
    assert.equal(a.reason, "code_mismatch");
  });
});

describe("stale-escrow recovery and reconciliation", () => {
  test("ALV-20 escrow_review_required and escrows_need_review", async () => {
    await seedEscrow("e1", { heldAt: ago(3 * HOUR), referenceId: "g1", referenceType: "gas_order" });
    await h.seed("gas_orders/g1", { passengerId: P, status: "delivered", escrowId: "e1",
      deliveryOtp: "8080", otpSubmitted: "8080" });
    await escrow.recoverStaleEscrows();
    const a = await assertVisible("escrow_review_required", { secrets: ["8080"] });
    assert.deepEqual([a.escrowId, a.orderCollection, a.orderId], ["e1", "gas_orders", "g1"]);
    assert.match(a.message, /nothing was refunded/);
    const b = await assertVisible("escrows_need_review");
    assert.deepEqual(b.review.map((r) => r.escrowId), ["e1"]);
  });

  test("ALV-21 stuck_escrows_released", async () => {
    await seedEscrow("e1", { heldAt: ago(3 * HOUR), referenceId: null, referenceType: "gas_order" });
    await escrow.recoverStaleEscrows();
    const a = await assertVisible("stuck_escrows_released");
    assert.equal(a.count, 1);
  });

  test("ALV-22 reconciliation_anomaly", async () => {
    await seedEscrow("e1", { heldAt: ago(3 * HOUR), referenceId: null, referenceType: "gas_order" });
    await escrow.runDailyReconciliation();
    const a = await assertVisible("reconciliation_anomaly");
    assert.equal(a.stuckEscrowDetails[0].escrowId, "e1");
  });
});

describe("shared escrow paths outside the five targets", () => {
  test("ALV-30 wallet_payment_rejected", async () => {
    await h.seed("deliveries/o1", { passengerId: P, status: "pending", paymentMethod: "wallet" });
    assert.equal(await escrow.cancelOrderForPayment("deliveries", "o1", "amount_below_minimum"), true);
    const a = await assertVisible("wallet_payment_rejected");
    assert.deepEqual([a.collection, a.orderId, a.reason], ["deliveries", "o1", "amount_below_minimum"]);
  });

  const cancel = (status, extra = {}) => {
    const before = { status, passengerId: P, escrowId: "e1", estimatedFare: 100 };
    return { before, after: { ...before, status: "cancelled", ...extra } };
  };
  async function cancelGas(status, extra) {
    const { before, after: a } = cancel(status, extra);
    await h.seed("gas_orders/o1", a);
    await update(trips.onGasOrderCancelled, { orderId: "o1" }, before, a);
  }

  test("ALV-31 gas_cancel_after_completion", async () => {
    await seedEscrow("e1", { referenceType: "gas_order", status: "RELEASED" });
    await cancelGas("delivered");
    await assertVisible("gas_cancel_after_completion");
  });

  test("ALV-32 gas_cancel_refund_skipped", async () => {
    await seedEscrow("e1", { referenceType: "gas_order", status: "RELEASED" });
    await cancelGas("driverAssigned");
    const a = await assertVisible("gas_cancel_refund_skipped");
    assert.equal(a.escrowStatus, "RELEASED");
  });

  test("ALV-33 gas_cancel_refund_failed", async () => {
    await seedEscrow("e1", { referenceType: "gas_order", userId: OTHER });
    await cancelGas("driverAssigned");
    const a = await assertVisible("gas_cancel_refund_failed");
    assert.equal(a.refundCompleted, false);
  });
});

describe("source guard", () => {
  // Alert types with no reachable path in tests: suspicious_trip is behind
  // the hard-coded TEST_MODE = true in onTripCompleted; the rejected-booking
  // refund failure needs a refund that throws after the booking is
  // cancelled. Both are built by adminAlert, which the guard enforces.
  const SOURCE_ONLY = new Set(["suspicious_trip", "wallet_payment_rejected_refund_failed"]);

  test("ALV-40 every admin alert in the settlement and recovery modules uses adminAlert", () => {
    for (const file of ["escrow.js", "trips.js"]) {
      const src = fs.readFileSync(path.join(__dirname, "../..", file), "utf8");
      // Both forms: .collection("admin_alerts").add(adminAlert(…)) and
      // tx.set(….collection("admin_alerts").doc(), adminAlert(…)).
      const writes = [...src.matchAll(/collection\("admin_alerts"\)/g)];
      assert.ok(writes.length > 0, `${file} writes alerts`);
      for (const w of writes) {
        const next = src.slice(w.index, w.index + 80);
        assert.match(next, /^collection\("admin_alerts"\)\s*(\.add\(|\.doc\(\),\s*)adminAlert\(/,
          `${file}:${src.slice(0, w.index).split("\n").length} writes an alert without adminAlert`);
      }
    }
  });

  test("ALV-41 every literal alert type is covered here or listed as source-only", () => {
    const covered = new Set(["trip_settlement_failed", "delivery_settlement_failed",
      "gas_settlement_failed", "gas_self_order", "delivery_otp_missing",
      "delivery_otp_mismatch", "gas_code_missing", "otp_mismatch", "escrow_review_required",
      "escrows_need_review", "stuck_escrows_released", "reconciliation_anomaly",
      "wallet_payment_rejected"]);
    for (const file of ["escrow.js", "trips.js"]) {
      const src = fs.readFileSync(path.join(__dirname, "../..", file), "utf8");
      for (const m of src.matchAll(/adminAlert\(\s*"([a-z_]+)"/g)) {
        assert.ok(covered.has(m[1]) || SOURCE_ONLY.has(m[1]), `${file}: ${m[1]} has no visibility test`);
      }
    }
  });
});
