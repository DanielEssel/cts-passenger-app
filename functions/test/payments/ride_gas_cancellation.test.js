// onTripCancelled and onGasOrderCancelled record escrowRefunded only when
// their own refund ran, and refund only the escrow that belongs to the
// cancelled order. The passenger's "Refund Processed" push (rides) is sent
// only after a real refund. Firestore emulator only; push is stubbed.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const trips = require("../../trips");

const P = "cx-passenger";

// Capture pushes instead of sending them.
const pushes = [];
Object.defineProperty(h.admin, "messaging", {
  configurable: true, writable: true,
  value: () => ({ send: async (m) => { pushes.push(m); return "stub-id"; } }),
});

const SERVICES = {
  ride: {
    fn: () => trips.onTripCancelled, collection: "trips", idParam: "tripId",
    referenceType: "trip", activeStatus: "tripAccepted", cancelStatus: "cancelledByPassenger",
    doneStatus: "completed", failedAlert: "escrow_refund_failed", skippedAlert: "trip_cancel_refund_skipped",
    alertPrefix: "trip",
  },
  gas: {
    fn: () => trips.onGasOrderCancelled, collection: "gas_orders", idParam: "orderId",
    referenceType: "gas_order", activeStatus: "driverAssigned", cancelStatus: "cancelled",
    doneStatus: "delivered", failedAlert: "gas_cancel_refund_failed", skippedAlert: "gas_cancel_refund_skipped",
    alertPrefix: "gas",
  },
};

async function seedEscrow(svc, { status = "HELD", wallet = true, userId = P,
  referenceId = "o1", referenceType = svc.referenceType } = {}) {
  if (wallet) await h.seed(`wallets/${userId}`, { balance: 0, heldBalance: 100 });
  await h.seed("escrows/e1", { userId, amount: 100, status, referenceId, referenceType });
}

function cancelEvent(svc, { beforeStatus = svc.activeStatus, status = svc.cancelStatus, extra = {} } = {}) {
  const before = { status: beforeStatus, passengerId: P, escrowId: "e1", estimatedFare: 100 };
  const afterDoc = { ...before, status, ...extra };
  return { params: { [svc.idParam]: "o1" },
    data: { before: { data: () => before }, after: { data: () => afterDoc } } };
}

async function run(svc, opts) {
  const ev = cancelEvent(svc, opts);
  await h.seed(`${svc.collection}/o1`, ev.data.after.data());
  await svc.fn().run(ev);
  return ev;
}

const order = (svc) => h.read(`${svc.collection}/o1`);
const alerts = (type) => h.count("admin_alerts", "type", type);
const refunds = () => h.count("ledger", "idempotencyKey", "refund_e1");
const wallet = () => h.read(`wallets/${P}`);

after(() => h.fft.cleanup());
beforeEach(async () => {
  pushes.length = 0;
  await h.clearFirestore();
  await h.seed(`users/${P}`, { fcmToken: "token-p" });
});

for (const [name, svc] of Object.entries(SERVICES)) {
  const tag = name === "ride" ? "RCX" : "GCX";

  describe(`${name} cancellation`, () => {
    test(`${tag}-01 normal cancellation refunds once and records escrowRefunded`, async () => {
      await seedEscrow(svc);
      await run(svc);
      assert.equal((await h.read("escrows/e1")).status, "REFUNDED");
      const w = await wallet();
      assert.equal(w.balance, 100);
      assert.equal(w.heldBalance, 0);
      assert.equal((await order(svc)).escrowRefunded, true);
      assert.ok((await order(svc)).escrowRefundedAt);
      assert.equal(await refunds(), 1);
      assert.equal(await alerts(svc.skippedAlert), 0);
      assert.equal(await alerts(svc.failedAlert), 0);
      if (name === "ride") {
        assert.equal(pushes.length, 1);
        assert.equal(pushes[0].notification.title, "Trip Cancelled — Refund Processed");
      }
    });

    test(`${tag}-02 cancellation after completion (escrow RELEASED) is not marked refunded`, async () => {
      await seedEscrow(svc, { status: "RELEASED" });
      await run(svc, { beforeStatus: svc.doneStatus });
      assert.notEqual((await order(svc)).escrowRefunded, true);
      assert.equal(await refunds(), 0);
      assert.equal((await wallet()).heldBalance, 100, "nothing moved");
      assert.equal((await wallet()).balance, 0);
      assert.equal(await alerts(`${svc.alertPrefix}_cancel_after_completion`), 1);
      assert.equal(pushes.length, 0, "no refund push");
    });

    test(`${tag}-03 failed refund (escrow missing) is not marked refunded and is alerted`, async () => {
      await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
      await run(svc);
      assert.notEqual((await order(svc)).escrowRefunded, true);
      assert.equal(await alerts(svc.failedAlert), 1);
      assert.equal(pushes.length, 0);
    });

    test(`${tag}-04 failed refund (wallet missing) leaves the escrow HELD and unflagged`, async () => {
      await seedEscrow(svc, { wallet: false });
      await run(svc);
      assert.equal((await h.read("escrows/e1")).status, "HELD");
      assert.notEqual((await order(svc)).escrowRefunded, true);
      assert.equal(await refunds(), 0);
      assert.equal(await alerts(svc.failedAlert), 1);
      assert.equal(pushes.length, 0);
    });

    test(`${tag}-05 an escrow already REFUNDED (duplicate) is neither re-flagged nor alerted`, async () => {
      await seedEscrow(svc, { status: "REFUNDED" });
      await run(svc);
      assert.notEqual((await order(svc)).escrowRefunded, true);
      assert.equal(await refunds(), 0);
      assert.equal(await alerts(svc.skippedAlert), 0);
      assert.equal(await alerts(svc.failedAlert), 0);
      assert.equal(pushes.length, 0);
    });

    test(`${tag}-06 the same event delivered twice refunds once`, async () => {
      await seedEscrow(svc);
      const ev = await run(svc);
      await svc.fn().run(ev);
      assert.equal(await refunds(), 1);
      assert.equal((await wallet()).balance, 100);
      assert.equal((await order(svc)).escrowRefunded, true);
      assert.equal(await alerts(svc.skippedAlert), 0);
      if (name === "ride") assert.equal(pushes.length, 1, "one push");
    });

    test(`${tag}-07 concurrent cancel events refund once`, async () => {
      await seedEscrow(svc);
      const ev = cancelEvent(svc);
      await h.seed(`${svc.collection}/o1`, ev.data.after.data());
      await Promise.all([svc.fn().run(ev), svc.fn().run(ev), svc.fn().run(ev)]);
      assert.equal(await refunds(), 1);
      const w = await wallet();
      assert.equal(w.balance, 100);
      assert.equal(w.heldBalance, 0);
      assert.equal((await order(svc)).escrowRefunded, true);
      if (name === "ride") assert.equal(pushes.length, 1, "one push");
    });

    test(`${tag}-08 an event that already carries escrowRefunded does nothing`, async () => {
      await seedEscrow(svc);
      await run(svc, { extra: { escrowRefunded: true } });
      assert.equal((await h.read("escrows/e1")).status, "HELD");
      assert.equal(await refunds(), 0);
      assert.equal(pushes.length, 0);
    });

    test(`${tag}-09 an escrow attached to another order is not refunded`, async () => {
      await seedEscrow(svc, { referenceId: "other-order" });
      await run(svc);
      assert.equal((await h.read("escrows/e1")).status, "HELD");
      assert.equal(await refunds(), 0);
      assert.notEqual((await order(svc)).escrowRefunded, true);
      assert.equal(await alerts(svc.failedAlert), 1);
    });

    test(`${tag}-10 an escrow held for another service is not refunded`, async () => {
      await seedEscrow(svc, { referenceType: "delivery" });
      await run(svc);
      assert.equal((await h.read("escrows/e1")).status, "HELD");
      assert.equal(await alerts(svc.failedAlert), 1);
    });

    test(`${tag}-11 another passenger's escrow is not refunded`, async () => {
      await seedEscrow(svc, { userId: "someone-else" });
      await run(svc);
      assert.equal((await h.read("escrows/e1")).status, "HELD");
      assert.equal((await h.read("wallets/someone-else")).balance, 0);
      assert.equal(await alerts(svc.failedAlert), 1);
    });

    test(`${tag}-12 the passenger's own unattached escrow (attach failed) is refunded`, async () => {
      await seedEscrow(svc, { referenceId: null });
      await run(svc);
      assert.equal((await h.read("escrows/e1")).status, "REFUNDED");
      assert.equal((await order(svc)).escrowRefunded, true);
    });

    test(`${tag}-13 a non-cancel status change does nothing`, async () => {
      await seedEscrow(svc);
      await run(svc, { status: svc.doneStatus === "completed" ? "tripStarted" : "refilling" });
      assert.equal((await h.read("escrows/e1")).status, "HELD");
      assert.equal(await refunds(), 0);
    });
  });
}

describe("ride cancellation reasons", () => {
  const svc = SERVICES.ride;
  const cases = {
    cancelled: "passenger_cancelled",
    cancelledByPassenger: "passenger_cancelled",
    cancelledByDriver: "driver_cancelled",
    noDrivers: "no_drivers_found",
    noDriversAvailable: "no_drivers_found",
  };
  for (const [status, reason] of Object.entries(cases)) {
    test(`RCX-20 ${status} refunds with reason ${reason}`, async () => {
      await h.clearFirestore();
      await seedEscrow(svc);
      await run(svc, { status });
      const e = await h.read("escrows/e1");
      assert.equal(e.status, "REFUNDED");
      assert.equal(e.releaseReason, reason);
    });
  }

  test("RCX-21 a push failure does not undo or hide the recorded refund", async () => {
    await seedEscrow(svc);
    Object.defineProperty(h.admin, "messaging", {
      configurable: true, writable: true,
      value: () => ({ send: async () => { throw new Error("push down"); } }),
    });
    try {
      await run(svc);
    } finally {
      Object.defineProperty(h.admin, "messaging", {
        configurable: true, writable: true,
        value: () => ({ send: async (m) => { pushes.push(m); return "stub-id"; } }),
      });
    }
    assert.equal((await order(svc)).escrowRefunded, true);
    assert.equal(await refunds(), 1);
    assert.equal(await alerts(svc.failedAlert), 0);
  });
});

describe("delivery cancellation ownership", () => {
  const ev = (extra = {}) => {
    const before = { status: "driverAssigned", passengerId: P, escrowId: "e1" };
    const a = { ...before, status: "cancelled", ...extra };
    return { params: { deliveryId: "o1" }, data: { before: { data: () => before }, after: { data: () => a } } };
  };

  test("DCX-10 an escrow attached to another delivery is not refunded", async () => {
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
    await h.seed("escrows/e1", { userId: P, amount: 100, status: "HELD",
      referenceId: "other-order", referenceType: "delivery" });
    const e = ev();
    await h.seed("deliveries/o1", e.data.after.data());
    await trips.onDeliveryCancelled.run(e);
    assert.equal((await h.read("escrows/e1")).status, "HELD");
    assert.notEqual((await h.read("deliveries/o1")).escrowRefunded, true);
    assert.equal(await alerts("delivery_cancel_refund_failed"), 1);
  });
});
