// Passenger confirmation window (Phase 1C). An unconfirmed trip is
// auto-confirmed only three minutes after server-trusted time: when the
// completion trigger first saw it completed, or the trip's completedAt if
// later. A completedAt written in the past by the driver's app cannot skip
// the passenger's chance to confirm or dispute. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const trips = require("../../trips");

const { GeoPoint, Timestamp } = h.admin.firestore;
const P = "cw-passenger";
const D = "cw-driver";
const ago = (min) => Timestamp.fromDate(new Date(Date.now() - min * 60e3));

async function complete(fields = {}, { runs = 1 } = {}) {
  const afterDoc = { passengerId: P, driverId: D, paymentMethod: "wallet", escrowId: "e1",
    estimatedFare: 100, serviceType: "taxi", status: "completed", passengerConfirmed: false,
    // Priced like a real booking (settlement checks the hold against it).
    pickupLocation: new GeoPoint(5.6037, -0.187), dropoffLocation: new GeoPoint(5.62, -0.19), ...fields };
  for (const k of Object.keys(afterDoc)) if (afterDoc[k] === undefined) delete afterDoc[k];
  await h.seed("trips/t1", afterDoc);
  const ev = { params: { tripId: "t1" },
    data: { before: { data: () => ({ ...afterDoc, status: "tripStarted" }) }, after: { data: () => afterDoc } } };
  await Promise.all(Array.from({ length: runs }, () => trips.onTripCompleted.run(ev)));
  return h.read("trips/t1");
}
const observed = () => h.read("settlement_observations/trips_t1");
const held = async () => (await h.read("escrows/e1")).status === "HELD";

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed("settings/platform", { platformFeePercent: 15 });
  await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
  await h.seed(`drivers/${D}`, { walletBalance: 0 });
  await h.seed("escrows/e1", { userId: P, amount: 100, platformFee: 15, driverNet: 85,
    status: "HELD", referenceId: "t1", referenceType: "trip" });
});

describe("confirmation window", () => {
  test("CW-01 a completedAt backdated by an hour does not auto-confirm at completion", async () => {
    const t = await complete({ completedAt: ago(60) });
    assert.notEqual(t.passengerConfirmed, true);
    assert.notEqual(t.autoConfirmed, true);
    assert.equal(await held(), true);
    assert.ok((await observed()).completionObservedAt, "server observation recorded");
  });

  test("CW-02 later events inside the window keep waiting", async () => {
    await complete({ completedAt: ago(60) });
    const t = await complete({ completedAt: ago(60), passengerRating: 5 });
    assert.notEqual(t.passengerConfirmed, true);
    assert.equal(await held(), true);
  });

  test("CW-03 three minutes after the server observation it auto-confirms, then settles once", async () => {
    await h.seed("settlement_observations/trips_t1", { collection: "trips", orderId: "t1",
      completionObservedAt: ago(4) });
    const t = await complete({ completedAt: ago(4) });
    assert.equal(t.passengerConfirmed, true);
    assert.equal(t.autoConfirmed, true);
    await complete({ completedAt: ago(4), passengerConfirmed: true, autoConfirmed: true });
    assert.equal((await h.read("escrows/e1")).status, "RELEASED");
    assert.equal(await h.count("ledger", "idempotencyKey", "capture_e1"), 1);
  });

  test("CW-04 the passenger's own confirmation settles immediately", async () => {
    await complete({ completedAt: Timestamp.now(), passengerConfirmed: true });
    assert.equal((await h.read("escrows/e1")).status, "RELEASED");
  });

  test("CW-05 a disputed trip is never auto-confirmed", async () => {
    await h.seed("settlement_observations/trips_t1", { collection: "trips", orderId: "t1",
      completionObservedAt: ago(30) });
    const t = await complete({ completedAt: ago(30), disputed: true });
    assert.notEqual(t.passengerConfirmed, true);
    assert.equal(await held(), true);
  });

  test("CW-06 a completedAt in the future only delays (the window uses the later time)", async () => {
    await h.seed("settlement_observations/trips_t1", { collection: "trips", orderId: "t1",
      completionObservedAt: ago(10) });
    const t = await complete({ completedAt: Timestamp.fromDate(new Date(Date.now() + 60 * 60e3)) });
    assert.notEqual(t.passengerConfirmed, true);
  });

  test("CW-07 older builds without completedAt now auto-confirm after the window", async () => {
    await complete({ completedAt: undefined });
    assert.notEqual((await h.read("trips/t1")).passengerConfirmed, true, "waits first");
    await h.seed("settlement_observations/trips_t1", { collection: "trips", orderId: "t1",
      completionObservedAt: ago(5) });
    const t = await complete({ completedAt: undefined });
    assert.equal(t.passengerConfirmed, true);
  });

  test("CW-08 concurrent first events record one observation time", async () => {
    await complete({ completedAt: ago(60) }, { runs: 4 });
    const first = (await observed()).completionObservedAt.toMillis();
    await complete({ completedAt: ago(60) });
    assert.equal((await observed()).completionObservedAt.toMillis(), first, "never moved");
  });
});
