// Immediate refunds for the remaining terminal statuses (Ride "expired",
// Delivery "cancelledByDriver"/"cancelledByPassenger", Gas "failed"), and
// no refund through a cancellation of an order whose service was already
// performed — by the trigger or by the hourly recovery sweep.
// Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const trips = require("../../trips");
const escrow = require("../../escrow");

const P = "ts-passenger";
const D = "ts-driver";
const { Timestamp } = h.admin.firestore;

const SVC = {
  trips: { fn: () => trips.onTripCancelled, idParam: "tripId", referenceType: "trip",
    active: "tripStarted", done: ["completed", "flagged"], marker: "completedAt", prefix: "trip" },
  deliveries: { fn: () => trips.onDeliveryCancelled, idParam: "deliveryId", referenceType: "delivery",
    active: "deliveryEnroute", done: ["completed", "flagged"], marker: "completedAt", prefix: "delivery" },
  gas_orders: { fn: () => trips.onGasOrderCancelled, idParam: "orderId", referenceType: "gas_order",
    active: "returning", done: ["delivered", "pendingOtp", "flagged"], marker: "deliveredAt", prefix: "gas" },
};

async function seedHeld(svc, o = {}) {
  await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
  await h.seed("escrows/e1", { userId: P, amount: 100, status: "HELD",
    referenceId: "o1", referenceType: svc.referenceType, ...o });
}

async function cancel(collection, { from, to, extra = {} }) {
  const svc = SVC[collection];
  const base = { passengerId: P, driverId: D, escrowId: "e1" };
  const before = { ...base, status: from };
  const afterDoc = { ...base, status: to, ...extra };
  await h.seed(`${collection}/o1`, afterDoc);
  const ev = { params: { [svc.idParam]: "o1" },
    data: { before: { data: () => before }, after: { data: () => afterDoc } } };
  await svc.fn().run(ev);
  return ev;
}

const refunds = () => h.count("ledger", "idempotencyKey", "refund_e1");
const escrowStatus = async () => (await h.read("escrows/e1")).status;

after(() => h.fft.cleanup());
beforeEach(() => h.clearFirestore());

describe("terminal statuses refund immediately", () => {
  const cases = [
    ["trips", "searching", "expired", "no_drivers_found"],
    ["deliveries", "driverAssigned", "cancelledByDriver", "delivery_cancelled"],
    ["deliveries", "pending", "cancelledByPassenger", "delivery_cancelled"],
    ["gas_orders", "driverAssigned", "failed", "gas_order_failed"],
  ];
  for (const [collection, from, to, reason] of cases) {
    test(`TSR-01 ${collection} ${from} → ${to} refunds once (${reason})`, async () => {
      await seedHeld(SVC[collection]);
      const ev = await cancel(collection, { from, to });
      await SVC[collection].fn().run(ev); // duplicate delivery of the event
      assert.equal(await escrowStatus(), "REFUNDED");
      assert.equal((await h.read("escrows/e1")).releaseReason, reason);
      assert.equal(await refunds(), 1);
      assert.equal((await h.read(`wallets/${P}`)).balance, 100);
      assert.equal((await h.read(`${collection}/o1`)).escrowRefunded, true);
    });
  }
});

describe("a performed service cannot be refunded through a cancellation", () => {
  for (const [collection, svc] of Object.entries(SVC)) {
    for (const from of svc.done) {
      test(`TSR-10 ${collection} ${from} → cancelled leaves the HELD escrow for the driver`, async () => {
        await seedHeld(svc);
        await cancel(collection, { from, to: "cancelled" });
        assert.equal(await escrowStatus(), "HELD");
        assert.equal(await refunds(), 0);
        assert.notEqual((await h.read(`${collection}/o1`)).escrowRefunded, true);
        assert.equal(await h.count("admin_alerts", "type", `${svc.prefix}_cancel_after_completion`), 1);
      });
    }

    test(`TSR-11 ${collection}: a cancellation carrying the completion timestamp is not refunded`, async () => {
      await seedHeld(svc);
      await cancel(collection, { from: svc.active, to: "cancelled",
        extra: { [svc.marker]: Timestamp.now() } });
      assert.equal(await escrowStatus(), "HELD");
      assert.equal(await refunds(), 0);
    });

    test(`TSR-12 ${collection}: an ordinary in-progress cancellation still refunds`, async () => {
      await seedHeld(svc);
      await cancel(collection, { from: svc.active, to: "cancelled",
        extra: { [svc.marker]: null } });
      assert.equal(await escrowStatus(), "REFUNDED");
      assert.equal(await refunds(), 1);
    });
  }
});

describe("recovery sweep", () => {
  const old = () => Timestamp.fromDate(new Date(Date.now() - 3 * 3600e3));

  test("TSR-20 a stale escrow of an order cancelled after completion goes to review, not refund", async () => {
    for (const [collection, svc] of Object.entries(SVC)) {
      await h.clearFirestore();
      await seedHeld(svc, { heldAt: old() });
      await h.seed(`${collection}/o1`, { passengerId: P, driverId: D, escrowId: "e1",
        status: "cancelled", [svc.marker]: Timestamp.now() });
      const summary = await escrow.recoverStaleEscrows();
      assert.equal(summary.refunded, 0, collection);
      assert.deepEqual(summary.review, [{ escrowId: "e1", reason: "cancelled_after_completion" }], collection);
      assert.equal(await escrowStatus(), "HELD", collection);
    }
  });

  test("TSR-21 delayed statuses still refund through recovery, exactly once", async () => {
    const cases = [["trips", "expired"], ["deliveries", "cancelledByDriver"], ["gas_orders", "failed"]];
    for (const [collection, status] of cases) {
      await h.clearFirestore();
      await seedHeld(SVC[collection], { heldAt: old() });
      await h.seed(`${collection}/o1`, { passengerId: P, escrowId: "e1", status });
      const first = await escrow.recoverStaleEscrows();
      const second = await escrow.recoverStaleEscrows();
      assert.equal(first.refunded, 1, collection);
      assert.equal(second.refunded, 0, collection);
      assert.equal(await refunds(), 1, collection);
    }
  });

  test("TSR-22 trigger and recovery racing on the same cancellation refund once", async () => {
    const svc = SVC.gas_orders;
    await seedHeld(svc, { heldAt: old() });
    const base = { passengerId: P, driverId: D, escrowId: "e1" };
    const afterDoc = { ...base, status: "failed" };
    await h.seed("gas_orders/o1", afterDoc);
    const ev = { params: { orderId: "o1" }, data: { before: { data: () => ({ ...base, status: "returning" }) },
      after: { data: () => afterDoc } } };
    await Promise.all([svc.fn().run(ev), escrow.recoverStaleEscrows()]);
    assert.equal(await refunds(), 1);
    assert.equal((await h.read(`wallets/${P}`)).balance, 100);
  });
});
