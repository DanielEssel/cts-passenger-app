// onDeliveryCancelled records escrowRefunded only when its own refund ran.
// Firestore emulator only. (The rule that stops parties cancelling a
// completed delivery is tested in rules-tests: DLV-S08 / DLV-P08 / DLV-P09.)

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const trips = require("../../trips");

const P = "cx-passenger";

async function seed({ escrowStatus = "HELD", wallet = true, escrowDoc = true } = {}) {
  if (wallet) await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
  if (escrowDoc) {
    await h.seed("escrows/e1", { userId: P, amount: 100, status: escrowStatus,
      referenceId: "d1", referenceType: "delivery" });
  }
}

function cancelEvent(extraAfter = {}) {
  const before = { status: "driverAssigned", passengerId: P, escrowId: "e1" };
  const afterDoc = { ...before, status: "cancelled", ...extraAfter };
  return { params: { deliveryId: "d1" },
    data: { before: { data: () => before }, after: { data: () => afterDoc } } };
}

async function cancel(extraAfter) {
  const ev = cancelEvent(extraAfter);
  await h.seed("deliveries/d1", ev.data.after.data());
  await trips.onDeliveryCancelled.run(ev);
}

const delivery = () => h.read("deliveries/d1");
const alerts = (type) => h.count("admin_alerts", "type", type);
const refunds = () => h.count("ledger", "idempotencyKey", "refund_e1");

after(() => h.fft.cleanup());
beforeEach(() => h.clearFirestore());

describe("onDeliveryCancelled", () => {
  test("DCX-01 normal cancellation refunds once and records escrowRefunded", async () => {
    await seed();
    await cancel();
    assert.equal((await h.read("escrows/e1")).status, "REFUNDED");
    assert.deepEqual(await h.read(`wallets/${P}`), {
      ...(await h.read(`wallets/${P}`)), balance: 100, heldBalance: 0 });
    assert.equal((await delivery()).escrowRefunded, true);
    assert.equal(await refunds(), 1);
    assert.equal(await alerts("delivery_cancel_refund_skipped"), 0);
  });

  test("DCX-02 a completed (released) delivery cancelled server-side is not marked refunded", async () => {
    await seed({ escrowStatus: "RELEASED" });
    await cancel();
    const d = await delivery();
    assert.notEqual(d.escrowRefunded, true);
    assert.equal(await refunds(), 0);
    assert.equal((await h.read(`wallets/${P}`)).heldBalance, 100, "nothing moved");
    assert.equal(await alerts("delivery_cancel_refund_skipped"), 1);
  });

  test("DCX-03 a failed refund (missing escrow) is not marked refunded and is alerted", async () => {
    await seed({ escrowDoc: false });
    await cancel();
    assert.notEqual((await delivery()).escrowRefunded, true);
    assert.equal(await alerts("delivery_cancel_refund_failed"), 1);
  });

  test("DCX-04 a failed refund (wallet missing) leaves the escrow HELD and unflagged", async () => {
    await seed({ wallet: false });
    await cancel();
    assert.equal((await h.read("escrows/e1")).status, "HELD");
    assert.notEqual((await delivery()).escrowRefunded, true);
    assert.equal(await alerts("delivery_cancel_refund_failed"), 1);
  });

  test("DCX-05 repeated cancel events refund once; the duplicate raises no alert", async () => {
    await seed();
    const ev = cancelEvent();
    await h.seed("deliveries/d1", ev.data.after.data());
    await trips.onDeliveryCancelled.run(ev);
    await trips.onDeliveryCancelled.run(ev); // same event delivered again
    assert.equal(await refunds(), 1);
    assert.equal((await h.read(`wallets/${P}`)).balance, 100);
    assert.equal((await delivery()).escrowRefunded, true);
    assert.equal(await alerts("delivery_cancel_refund_skipped"), 0);
  });

  test("DCX-06 concurrent cancel events refund once", async () => {
    await seed();
    const ev = cancelEvent();
    await h.seed("deliveries/d1", ev.data.after.data());
    await Promise.all([trips.onDeliveryCancelled.run(ev), trips.onDeliveryCancelled.run(ev),
      trips.onDeliveryCancelled.run(ev)]);
    assert.equal(await refunds(), 1);
    assert.equal((await h.read(`wallets/${P}`)).balance, 100);
    assert.equal((await h.read(`wallets/${P}`)).heldBalance, 0);
    assert.equal((await delivery()).escrowRefunded, true);
  });

  test("DCX-07 an event that already carries escrowRefunded does nothing", async () => {
    await seed();
    await cancel({ escrowRefunded: true });
    assert.equal((await h.read("escrows/e1")).status, "HELD");
    assert.equal(await refunds(), 0);
  });
});
