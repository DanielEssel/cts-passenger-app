// Alert-only sweep for delivery settlements stuck in "processing".
// Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const monitor = require("../../settlement_monitor");

const { Timestamp } = h.admin.firestore;
const MIN = 60 * 1000;
const NOW = Date.now();
const startedAgo = (ms) => Timestamp.fromDate(new Date(NOW - ms));

async function seedProcessing(id, { started = startedAgo(45 * MIN), escrowId = "e-" + id,
  escrow = { status: "RELEASED", referenceId: id }, extra = {} } = {}) {
  await h.seed(`deliveries/${id}`, {
    status: "completed", passengerId: "p1", driverId: "d1",
    settlementStatus: "processing",
    // null = no start time recorded (undefined would pick up the default).
    ...(started === null ? {} : { settlementStartedAt: started }),
    ...(escrowId ? { escrowId } : {}),
    ...extra,
  });
  if (escrowId && escrow) {
    await h.seed(`escrows/${escrowId}`, { userId: "p1", amount: 100, referenceType: "delivery", ...escrow });
  }
}

const sweep = (now = NOW) => monitor.sweepStuckDeliverySettlements({ now });
const stuckAlerts = async () => (await h.db().collection("admin_alerts")
  .where("type", "==", "delivery_settlement_stuck").get()).docs.map((d) => d.data());

after(() => h.fft.cleanup());
beforeEach(() => h.clearFirestore());

describe("classifyProcessingDelivery (pure)", () => {
  const c = (delivery, escrow) => monitor.classifyProcessingDelivery({
    deliveryId: "d1", delivery: { settlementStatus: "processing", escrowId: "e1", ...delivery },
    escrow, now: NOW });

  test("STK-01 under the threshold it may still be running: not stuck", () => {
    for (const age of [0, 5 * MIN, monitor.STUCK_AFTER_MS - 1000]) {
      assert.deepEqual(c({ settlementStartedAt: startedAgo(age) }, { status: "HELD" }),
        { stuck: false, state: "may_still_be_running" }, `age ${age}`);
    }
  });

  test("STK-02 past the threshold every state is named", () => {
    const old = { settlementStartedAt: startedAgo(monitor.STUCK_AFTER_MS + 1000) };
    assert.equal(c(old, { status: "RELEASED", referenceId: "d1" }).state, "released_not_recorded");
    assert.equal(c(old, { status: "HELD" }).state, "interrupted_before_release");
    assert.equal(c(old, null).state, "interrupted_escrow_missing");
    assert.equal(c(old, { status: "REFUNDED" }).state, "interrupted_escrow_refunded");
    assert.equal(c(old, { status: "RELEASED", referenceId: "other" }).state,
      "interrupted_escrow_released");
    assert.equal(c({ ...old, escrowId: null }, null).state, "interrupted_without_escrow");
    assert.equal(c({}, null).state, "processing_without_start_time");
  });

  test("STK-03 settled or non-processing deliveries are ignored", () => {
    const old = { settlementStartedAt: startedAgo(2 * 60 * MIN) };
    assert.equal(c({ ...old, walletProcessed: true }, null).stuck, false);
    assert.equal(c({ ...old, settlementStatus: "failed" }, null).stuck, false);
  });
});

describe("sweepStuckDeliverySettlements (emulator)", () => {
  test("STK-10 a settlement released but never recorded is alerted", async () => {
    await seedProcessing("d1");
    const summary = await sweep();
    assert.deepEqual(summary, { checked: 1, stuck: 1, alerted: 1, alreadyAlerted: 0 });
    const [alert] = await stuckAlerts();
    assert.equal(alert.state, "released_not_recorded");
    assert.equal(alert.deliveryId, "d1");
    // Ids and state only.
    assert.deepEqual(Object.keys(alert).sort(),
      ["createdAt", "deliveryId", "escrowId", "settlementStartedAt", "state", "type"]);
  });

  test("STK-11 a run that started recently is left alone", async () => {
    await seedProcessing("d-fresh", { started: startedAgo(2 * MIN) });
    const summary = await sweep();
    assert.equal(summary.stuck, 0);
    assert.equal((await stuckAlerts()).length, 0);
  });

  test("STK-12 repeated sweeps alert once per stuck attempt", async () => {
    await seedProcessing("d1");
    await sweep();
    const second = await sweep(NOW + 30 * MIN);
    assert.deepEqual(second, { checked: 1, stuck: 1, alerted: 0, alreadyAlerted: 1 });
    assert.equal((await stuckAlerts()).length, 1);
  });

  test("STK-13 a later retry that gets stuck again is a new alert", async () => {
    await seedProcessing("d1");
    await sweep();
    await h.db().doc("deliveries/d1").update({ settlementStartedAt: startedAgo(35 * MIN) });
    await sweep();
    assert.equal((await stuckAlerts()).length, 2);
  });

  test("STK-14 a missing start time is alerted once", async () => {
    await seedProcessing("d-nostart", { started: null });
    await sweep();
    await sweep();
    const alerts = await stuckAlerts();
    assert.equal(alerts.length, 1);
    assert.equal(alerts[0].state, "processing_without_start_time");
  });

  test("STK-15 the sweep moves no money and changes no order", async () => {
    await h.seed("wallets/p1", { balance: 5, heldBalance: 100 });
    await h.seed("drivers/d1", { walletBalance: 0 });
    await seedProcessing("d1", { escrow: { status: "HELD", referenceId: "d1" } });
    await seedProcessing("d2", { started: startedAgo(2 * MIN) });
    await h.seed("deliveries/d3", { status: "completed", walletProcessed: true,
      settlementStatus: "completed" });
    const snapshot = async () => {
      const out = {};
      for (const c of ["wallets", "drivers", "escrows", "deliveries", "ledger"]) {
        out[c] = (await h.db().collection(c).get()).docs
          .map((d) => [d.id, JSON.stringify(d.data())]).sort();
      }
      return out;
    };
    const before = await snapshot();

    const summary = await sweep();

    assert.equal(summary.checked, 2);
    assert.equal(summary.alerted, 1);
    assert.deepEqual(await snapshot(), before);
  });
});
