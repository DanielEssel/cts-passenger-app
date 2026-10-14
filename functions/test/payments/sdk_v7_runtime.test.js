// firebase-functions v7 runtime checks for the deployment targets:
// the manifest the CLI deploys (schedules, time zone, region, retries,
// trigger types) and the scheduled handlers invoked through their real v7
// wrapper rather than only their inner functions. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Load the real entry point first (it calls admin.initializeApp()), with
// the same local-only environment the payment harness sets; the harness
// then reuses that app instead of initialising a second one.
process.env.GCLOUD_PROJECT = "demo-ctsgo-payments";
process.env.PAYMENTS_MODE = "stub";
process.env.BRIDGE_CLIENT_KEY = "fake-client-key";
process.env.BRIDGE_SECRET_KEY = "fake-secret-key";
process.env.BRIDGE_SERVICE_ID = "1";
const index = require("../../index");
const h = require("./helpers");

const { Timestamp } = h.admin.firestore;

after(() => h.fft.cleanup());
beforeEach(() => h.clearFirestore());

describe("SDK and manifest", () => {
  test("SDK-01 the lockfile pins firebase-functions 7.4.0", () => {
    const lock = JSON.parse(fs.readFileSync(path.join(__dirname, "../../package-lock.json"), "utf8"));
    assert.equal(lock.packages["node_modules/firebase-functions"].version, "7.4.0");
  });

  test("SDK-02 every target deploys to europe-west2 on gcfv2 with the expected trigger", () => {
    const expected = {
      onDeliveryCompleted: ["eventTrigger", "deliveries/{deliveryId}", "updated"],
      onDeliveryCancelled: ["eventTrigger", "deliveries/{deliveryId}", "updated"],
      onDeliveryFareValidation: ["eventTrigger", "deliveries/{deliveryId}", "created"],
      onGasOrderCompleted: ["eventTrigger", "gas_orders/{orderId}", "updated"],
      onGasOrderCancelled: ["eventTrigger", "gas_orders/{orderId}", "updated"],
      onTripCompleted: ["eventTrigger", "trips/{tripId}", "updated"],
      onTripCancelled: ["eventTrigger", "trips/{tripId}", "updated"],
      attachEscrowToOrder: ["callableTrigger"],
      refundEscrowOnError: ["callableTrigger"],
      releaseStuckEscrows: ["scheduleTrigger"],
      dailyReconciliation: ["scheduleTrigger"],
      detectStuckDeliverySettlements: ["scheduleTrigger"],
    };
    for (const [name, [kind, doc, op]] of Object.entries(expected)) {
      const ep = index[name].__endpoint;
      assert.equal(ep.platform, "gcfv2", name);
      assert.deepEqual(ep.region, ["europe-west2"], name);
      assert.ok(ep[kind], `${name} has ${kind}`);
      if (kind === "eventTrigger") {
        assert.equal(ep.eventTrigger.eventFilterPathPatterns.document, doc, name);
        assert.ok(ep.eventTrigger.eventType.endsWith(`.document.v1.${op}`), name);
        assert.equal(ep.eventTrigger.retry, false, `${name} is not retried`);
      }
    }
  });

  test("SDK-03 schedules and time zones are exactly as reviewed", () => {
    // As serialised into the deploy manifest (undefined fields drop out).
    const trig = (name) => JSON.parse(JSON.stringify(index[name].__endpoint.scheduleTrigger));
    assert.deepEqual(trig("releaseStuckEscrows"),
      { schedule: "every 1 hours", retryConfig: {} });
    assert.deepEqual(trig("dailyReconciliation"),
      { schedule: "0 0 * * *", timeZone: "Africa/Accra", retryConfig: {} });
    assert.deepEqual(trig("detectStuckDeliverySettlements"),
      { schedule: "every 30 minutes", retryConfig: {} });
  });
});

describe("scheduled handlers through the v7 wrapper", () => {
  const event = () => ({ scheduleTime: new Date().toISOString(), jobName: "local-test" });

  test("SDK-10 releaseStuckEscrows runs the recovery policy", async () => {
    await h.seed("wallets/p1", { balance: 0, heldBalance: 50 });
    await h.seed("escrows/orphan", { userId: "p1", amount: 50, status: "HELD",
      referenceId: null, referenceType: "delivery",
      heldAt: Timestamp.fromDate(new Date(Date.now() - 3 * 3600e3)) });
    await index.releaseStuckEscrows.run(event());
    assert.equal((await h.read("escrows/orphan")).status, "REFUNDED");
    assert.equal((await h.read("wallets/p1")).balance, 50);
  });

  test("SDK-11 dailyReconciliation writes one report", async () => {
    await h.seed("wallets/p1", { balance: 10, heldBalance: 0 });
    await index.dailyReconciliation.run(event());
    const reports = await h.db().collection("reconciliation").get();
    assert.equal(reports.size, 1);
    assert.equal(reports.docs[0].data().totalLiability, 10);
    assert.equal(reports.docs[0].data().stuckEscrows, 0);
  });

  test("SDK-12 detectStuckDeliverySettlements alerts without touching the order", async () => {
    const order = { status: "completed", settlementStatus: "processing",
      settlementStartedAt: Timestamp.fromDate(new Date(Date.now() - 3600e3)) };
    await h.seed("deliveries/d1", order);
    await index.detectStuckDeliverySettlements.run(event());
    assert.equal(await h.count("admin_alerts", "type", "delivery_settlement_stuck"), 1);
    assert.deepEqual((await h.read("deliveries/d1")).settlementStatus, "processing");
  });
});
