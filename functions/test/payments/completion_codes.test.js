// Completion codes held where the assigned driver cannot read them
// (completion_codes.js). An order's code is stored server-side at creation;
// settlement checks against it; the driver verifies a code through
// verifyCompletionCode, which never reveals it and limits wrong tries.
// A driver who completes without the customer's code is not paid.
// Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
process.env.GCLOUD_PROJECT = "demo-ctsgo-payments";
process.env.PAYMENTS_MODE = "stub";
process.env.BRIDGE_CLIENT_KEY = "fake-client-key";
process.env.BRIDGE_SECRET_KEY = "fake-secret-key";
process.env.BRIDGE_SERVICE_ID = "1";
const index = require("../../index");
const h = require("./helpers");
const trips = require("../../trips");
const codes = require("../../completion_codes");

const { GeoPoint, Timestamp } = h.admin.firestore;
const ACCRA = new GeoPoint(5.6037, -0.187);
const P = "cc-passenger";
const D = "cc-driver";

Object.defineProperty(h.admin, "messaging", {
  configurable: true, writable: true,
  value: () => ({ sendEachForMulticast: async (m) => ({ successCount: 0, failureCount: 0,
    responses: m.tokens.map(() => ({ success: true })) }), send: async () => "stub-id" }),
});

const delivery = (o = {}) => ({ passengerId: P, driverId: null, status: "pending", vehicleType: "Okada",
  weightTier: "Small", paymentMethod: "cash", estimatedFare: 100, pickupLocation: ACCRA, dropoffLocation: ACCRA,
  createdAt: Timestamp.now(), ...o });
const gasOrder = (o = {}) => ({ passengerId: P, driverId: null, status: "pendingApproval", refillType: "newCylinder",
  paymentMethod: "cash", totalPrice: 100, deliveryLocation: ACCRA, pickupLocation: ACCRA, createdAt: Timestamp.now(), ...o });
const secret = (coll, id) => h.read(`order_completion_codes/${coll}_${id}`);
const verify = (uid, data) => h.callCallable(index.verifyCompletionCode, uid, data);

async function create(coll, id, data) {
  await h.seed(`${coll}/${id}`, data);
  const trigger = coll === "deliveries" ? index.onDeliveryCreated : index.onGasOrderCreated;
  const param = coll === "deliveries" ? "deliveryId" : "orderId";
  await trigger.run({ params: { [param]: id }, data: { data: () => data } });
}

/** Assign the order to D and move it to the hand-over step. */
const handOverStep = (coll, id) => h.db().doc(`${coll}/${id}`).update({ driverId: D,
  status: coll === "deliveries" ? "arrivedAtDropoff" : "returning" });

async function completeAndSettle(coll, id) {
  const ref = h.db().doc(`${coll}/${id}`);
  const before = (await ref.get()).data();
  const done = coll === "deliveries" ? "completed" : "delivered";
  await ref.update({ status: done });
  const afterDoc = (await ref.get()).data();
  const fn = coll === "deliveries" ? trips.onDeliveryCompleted : trips.onGasOrderCompleted;
  const param = coll === "deliveries" ? "deliveryId" : "orderId";
  await fn.run({ params: { [param]: id }, data: { before: { data: () => before }, after: { data: () => afterDoc } } });
  return (await ref.get()).data();
}

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed("settings/platform", { platformFeePercent: 15 });
  await h.seed(`drivers/${D}`, { uid: D, role: "driver_delivery", walletBalance: 0, totalEarnings: 0,
    isAvailable: false, currentTripId: "x" });
});

describe("the code is stored server-side at creation", () => {
  for (const coll of ["deliveries", "gas_orders"]) {
    const make = coll === "deliveries" ? delivery : gasOrder;

    test(`CC-01 ${coll}: an order without a code (current Passenger App) gets one, held server-side`, async () => {
      await create(coll, "o1", make());
      const s = await secret(coll, "o1");
      assert.match(s.code, /^\d{4}$/);
      assert.equal(s.passengerId, P);
      assert.equal((await h.read(`${coll}/o1`)).deliveryOtp, undefined, "nothing written on the order");
    });

    test(`CC-02 ${coll}: an older build's code is reused, and a repeat event changes nothing`, async () => {
      await create(coll, "o1", make({ deliveryOtp: "4821" }));
      assert.equal((await secret(coll, "o1")).code, "4821");
      await create(coll, "o1", make({ deliveryOtp: "4821" }));
      assert.equal((await secret(coll, "o1")).code, "4821");
      assert.equal(await codes.ensureCompletionCode(coll, "o1", make({ deliveryOtp: "1111" })), false);
      assert.equal((await secret(coll, "o1")).code, "4821", "never replaced");
    });
  }
});

describe("verifyCompletionCode", () => {
  test("CC-10 the assigned driver's right code is recorded; the code is never returned", async () => {
    await create("deliveries", "o1", delivery());
    await handOverStep("deliveries", "o1");
    const { code } = await secret("deliveries", "o1");
    const r = await verify(D, { collection: "deliveries", orderId: "o1", code });
    assert.deepEqual(r, { ok: true });
    assert.equal((await h.read("deliveries/o1")).otpSubmitted, code);
  });

  test("CC-11 wrong codes are counted and locked after five; the code is never revealed", async () => {
    await create("gas_orders", "o1", gasOrder({ deliveryOtp: "4821" }));
    await handOverStep("gas_orders", "o1");
    for (let i = 4; i >= 0; i--) {
      const r = await verify(D, { collection: "gas_orders", orderId: "o1", code: "0000" });
      assert.deepEqual(r, { ok: false, reason: "code_mismatch", attemptsLeft: i });
      assert.ok(!JSON.stringify(r).includes("4821"));
    }
    assert.equal((await verify(D, { collection: "gas_orders", orderId: "o1", code: "4821" })).reason, "too_many_attempts");
    assert.equal((await h.read("gas_orders/o1")).otpSubmitted, undefined);
  });

  test("CC-12 only the assigned driver, only before the hand-over is final", async () => {
    await create("deliveries", "o1", delivery());
    const { code } = await secret("deliveries", "o1");
    await assert.rejects(verify("other", { collection: "deliveries", orderId: "o1", code }), /not assigned/);
    await assert.rejects(verify(null, { collection: "deliveries", orderId: "o1", code }), /signed in/);
    await h.db().doc("deliveries/o1").update({ driverId: D, status: "completed" });
    assert.equal((await verify(D, { collection: "deliveries", orderId: "o1", code })).reason, "order_not_open");
    await assert.rejects(verify(D, { collection: "trips", orderId: "o1", code }), /required/);
    assert.equal((await verify(D, { collection: "deliveries", orderId: "o1", code: "12" })).reason, "code_malformed");
  });
});

describe("settlement pays only against the server-held code", () => {
  for (const coll of ["deliveries", "gas_orders"]) {
    const make = coll === "deliveries" ? delivery : gasOrder;

    test(`CC-20 ${coll}: completed with the customer's code (verified), the driver is paid`, async () => {
      await create(coll, "o1", make());
      await handOverStep(coll, "o1");
      const { code } = await secret(coll, "o1");
      await verify(D, { collection: coll, orderId: "o1", code });
      const o = await completeAndSettle(coll, "o1");
      assert.notEqual(o.status, "flagged");
      assert.ok((await h.read(`drivers/${D}`)).totalEarnings > 0);
    });

    test(`CC-21 ${coll}: completed without the code, or with a guessed one, the driver is not paid`, async () => {
      await create(coll, "o1", make());
      await handOverStep(coll, "o1");
      let o = await completeAndSettle(coll, "o1");
      assert.ok(["flagged", "pendingOtp"].includes(o.status), o.status);
      await create(coll, "o2", make());
      await handOverStep(coll, "o2");
      await h.db().doc(`${coll}/o2`).update({ otpSubmitted: "0000" }); // a direct client write
      if ((await secret(coll, "o2")).code === "0000") return; // 1 in 10,000
      o = await completeAndSettle(coll, "o2");
      assert.equal(o.status, "flagged");
      assert.equal((await h.read(`drivers/${D}`)).totalEarnings, 0, "never paid");
    });
  }

  test("CC-22 an order from before this release still settles against its own deliveryOtp", async () => {
    await h.seed("deliveries/old", delivery({ driverId: D, status: "arrivedAtDropoff", deliveryOtp: "4821",
      otpSubmitted: "4821" }));
    const o = await completeAndSettle("deliveries", "old");
    assert.notEqual(o.status, "flagged");
  });
});

describe("passenger contact on deliveries", () => {
  test("CC-30 an open delivery carries no passenger contact; it is copied once a driver is assigned", async () => {
    await h.seed(`users/${P}`, { displayName: "Test Passenger", phoneNumber: "0200000000" });
    await create("deliveries", "o1", delivery());
    const open = await h.read("deliveries/o1");
    assert.equal(open.passengerPhone, undefined, "not readable by unassigned drivers");
    assert.equal(open.passengerName, undefined);
    const before = open;
    await h.db().doc("deliveries/o1").update({ driverId: D, status: "driverAssigned" });
    const afterDoc = await h.read("deliveries/o1");
    await index.onDeliveryStatusChanged.run({ params: { deliveryId: "o1" },
      data: { before: { data: () => before }, after: { data: () => afterDoc } } });
    const assigned = await h.read("deliveries/o1");
    assert.equal(assigned.passengerName, "Test Passenger");
    assert.equal(assigned.passengerPhone, "0200000000");
  });
});
