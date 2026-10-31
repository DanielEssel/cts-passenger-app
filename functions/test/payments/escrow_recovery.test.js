// Escrow recovery and settlement (release blocker B1).
//
// The hourly job used to refund every HELD escrow older than two hours, even
// when it belonged to an order still in progress. The completion trigger
// then found nothing HELD, so the service was free and the driver unpaid.
// These tests run against the Firestore emulator only.

"use strict";

const { test, describe, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");

const escrow = require("../../escrow");
const trips = require("../../trips");

const { Timestamp } = h.admin.firestore;
const HOUR = 60 * 60 * 1000;
const ago = (ms) => Timestamp.fromDate(new Date(Date.now() - ms));

const PASSENGER = "passenger-1";
const DRIVER = "driver-1";

async function seedWallet({ balance = 0, held = 0 } = {}) {
  await h.seed(`wallets/${PASSENGER}`, { balance, heldBalance: held });
}

async function seedEscrow(id, {
  amount = 100,
  heldAt = ago(3 * HOUR),
  referenceType = "gas_order",
  referenceId = null,
  status = "HELD",
} = {}) {
  await h.seed(`escrows/${id}`, {
    id, userId: PASSENGER, serviceType: "delivery", referenceType,
    referenceId, amount, platformFee: 15, driverNet: 85,
    status, heldAt, releasedAt: null,
  });
}

async function wallet() {
  return h.read(`wallets/${PASSENGER}`);
}

async function ledgerCount(type, escrowId) {
  const snap = await h.db().collection("ledger")
    .where("type", "==", type).where("idempotencyKey", "==",
      `${type === "REFUND" ? "refund" : "capture"}_${escrowId}`).get();
  return snap.size;
}

/** Runs a v2 document-updated trigger with plain before/after data. */
function runUpdate(fn, params, beforeData, afterData) {
  return fn.run({
    params,
    data: {
      before: { data: () => beforeData },
      after: { data: () => afterData },
    },
  });
}

before(async () => {
  await h.clearFirestore();
});

after(() => h.fft.cleanup());

beforeEach(async () => {
  await h.clearFirestore();
});

describe("staleEscrowAction (pure policy)", () => {
  const act = (s) => escrow.staleEscrowAction(s).action;

  test("ESC-01 no order and never attached is an abandoned hold: refund", () => {
    assert.equal(act({ attached: false, orderFound: false }), "refund");
  });

  test("ESC-02 attached but the order no longer exists: refund", () => {
    assert.equal(act({ attached: true, orderFound: false }), "refund");
  });

  test("ESC-03 in-progress orders are kept, for every order type", () => {
    for (const [collection, status] of [
      ["gas_orders", "pendingApproval"], ["gas_orders", "driverEnRoute"],
      ["gas_orders", "refilling"], ["gas_orders", "returning"],
      ["gas_orders", "pendingOtp"], ["deliveries", "pending"],
      ["deliveries", "deliveryEnroute"], ["trips", "searching"],
      ["trips", "tripStarted"], ["trips", "flagged"],
    ]) {
      assert.equal(act({ attached: true, orderFound: true, collection, orderStatus: status }),
        "keep", `${collection}/${status}`);
    }
  });

  test("ESC-04 cancelled or failed orders are refunded", () => {
    for (const [collection, status] of [
      ["gas_orders", "cancelled"], ["gas_orders", "failed"],
      ["deliveries", "cancelled"], ["trips", "cancelledByPassenger"],
      ["trips", "noDriversAvailable"], ["trips", "expired"],
    ]) {
      assert.equal(act({ attached: true, orderFound: true, collection, orderStatus: status }),
        "refund", `${collection}/${status}`);
    }
  });

  test("ESC-05 completed orders are never refunded; they go to review", () => {
    for (const [collection, status] of [
      ["gas_orders", "delivered"], ["deliveries", "completed"], ["trips", "completed"],
    ]) {
      assert.equal(act({ attached: true, orderFound: true, collection, orderStatus: status }),
        "review", `${collection}/${status}`);
    }
  });

  test("ESC-06 a missing status or unknown order type goes to review", () => {
    assert.equal(act({ attached: true, orderFound: true, collection: "gas_orders" }), "review");
    assert.equal(act({ attached: true, orderFound: true, collection: "x", orderStatus: "y" }), "review");
  });
});

describe("recoverStaleEscrows (emulator)", () => {
  test("ESC-10 an attached escrow of an active order older than 2 h is NOT refunded", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("e-active", { referenceId: "g-active" });
    await h.seed("gas_orders/g-active", {
      status: "refilling", refillType: "pickupAndReturn", escrowId: "e-active",
      passengerId: PASSENGER, driverId: DRIVER,
    });

    const summary = await escrow.recoverStaleEscrows();

    assert.equal(summary.refunded, 0);
    assert.equal(summary.kept, 1);
    assert.equal((await h.read("escrows/e-active")).status, "HELD");
    assert.deepEqual(await wallet(), { balance: 0, heldBalance: 100 });
  });

  test("ESC-11 an unattached stale hold with no order is refunded once", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("e-orphan");

    const summary = await escrow.recoverStaleEscrows();

    assert.equal(summary.refunded, 1);
    assert.equal((await h.read("escrows/e-orphan")).status, "REFUNDED");
    assert.equal((await h.read("escrows/e-orphan")).releaseReason, "auto_abandoned_hold");
    const w = await wallet();
    assert.equal(w.balance, 100);
    assert.equal(w.heldBalance, 0);
    assert.equal(await ledgerCount("REFUND", "e-orphan"), 1);
  });

  test("ESC-12 an unattached escrow whose order exists and is active is kept", async () => {
    // Attach failed after the order was created; the order carries escrowId.
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("e-unlinked", { referenceId: null });
    await h.seed("gas_orders/g-unlinked", {
      status: "driverAssigned", escrowId: "e-unlinked",
      passengerId: PASSENGER, driverId: DRIVER,
    });

    const summary = await escrow.recoverStaleEscrows();

    assert.equal(summary.refunded, 0);
    assert.equal((await h.read("escrows/e-unlinked")).status, "HELD");
  });

  test("ESC-13 a failed gas order (no cancel trigger for 'failed') is recovered", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("e-failed", { referenceId: "g-failed" });
    await h.seed("gas_orders/g-failed", { status: "failed", escrowId: "e-failed", passengerId: PASSENGER });

    await escrow.recoverStaleEscrows();

    assert.equal((await h.read("escrows/e-failed")).status, "REFUNDED");
    assert.equal((await wallet()).balance, 100);
  });

  test("ESC-14 a completed order whose escrow is still held is flagged, not refunded", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("e-done", { referenceId: "g-done" });
    await h.seed("gas_orders/g-done", { status: "delivered", escrowId: "e-done" });

    const summary = await escrow.recoverStaleEscrows();

    assert.equal(summary.refunded, 0);
    assert.deepEqual(summary.review, [{ escrowId: "e-done", reason: "settled_order_still_held" }]);
    assert.equal((await h.read("escrows/e-done")).status, "HELD");
    assert.equal(await h.count("admin_alerts", "type", "escrows_need_review"), 1);
  });

  test("ESC-15 holds younger than two hours are not touched", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("e-fresh", { heldAt: ago(30 * 60 * 1000) });

    const summary = await escrow.recoverStaleEscrows();

    assert.equal(summary.refunded, 0);
    assert.equal((await h.read("escrows/e-fresh")).status, "HELD");
  });
});

describe("cancellation and completion settle through the escrow", () => {
  test("ESC-20 cancelling a gas order refunds its hold once", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("e-cancel", { referenceId: "g-cancel", heldAt: ago(10 * 60 * 1000) });
    const beforeData = { status: "driverEnRoute", escrowId: "e-cancel", passengerId: PASSENGER };
    const afterData = { ...beforeData, status: "cancelled" };
    await h.seed("gas_orders/g-cancel", afterData);

    await runUpdate(trips.onGasOrderCancelled, { orderId: "g-cancel" }, beforeData, afterData);
    // A repeat delivery of the same event, or a later recovery pass, does
    // not credit again.
    await runUpdate(trips.onGasOrderCancelled, { orderId: "g-cancel" }, beforeData, afterData);
    await escrow.recoverStaleEscrows({ now: Date.now() + 3 * HOUR });

    assert.equal((await h.read("escrows/e-cancel")).status, "REFUNDED");
    assert.equal((await h.read("gas_orders/g-cancel")).escrowRefunded, true);
    assert.deepEqual(await wallet(), { balance: 100, heldBalance: 0, lastUpdatedAt: (await wallet()).lastUpdatedAt });
    assert.equal(await ledgerCount("REFUND", "e-cancel"), 1);
  });

  test("ESC-21 completing a long Pickup & Return order pays the driver from escrow", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await h.seed(`drivers/${DRIVER}`, { walletBalance: 0, totalEarnings: 0 });
    // Held 3 h ago (over the old cut-off) and still in progress.
    await seedEscrow("e-pr", { referenceId: "g-pr" });
    const active = {
      status: "returning", refillType: "pickupAndReturn", cylinderSize: "kg3", quantity: 1, escrowId: "e-pr",
      passengerId: PASSENGER, driverId: DRIVER, totalPrice: 100,
      paymentMethod: "wallet", deliveryOtp: "1234",
    };
    await h.seed("gas_orders/g-pr", active);

    // The hourly job runs while the order is still in progress …
    await escrow.recoverStaleEscrows();
    assert.equal((await h.read("escrows/e-pr")).status, "HELD");

    // … then the driver delivers.
    const delivered = { ...active, status: "delivered", otpSubmitted: "1234" };
    await h.seed("gas_orders/g-pr", delivered);
    await runUpdate(trips.onGasOrderCompleted, { orderId: "g-pr" }, active, delivered);

    assert.equal((await h.read("escrows/e-pr")).status, "RELEASED");
    const w = await wallet();
    assert.equal(w.balance, 0, "passenger is not refunded");
    assert.equal(w.heldBalance, 0, "hold is consumed");
    const d = await h.read(`drivers/${DRIVER}`);
    assert.equal(d.walletBalance, 85, "driver receives driverNet");
    assert.equal(await ledgerCount("CAPTURE", "e-pr"), 1);
    assert.equal((await h.read("gas_orders/g-pr")).walletProcessed, true);
  });
});

describe("repeated and concurrent settlement", () => {
  test("ESC-30 concurrent refunds credit the wallet exactly once", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("e-race");

    const results = await Promise.all([
      escrow.refundEscrow("e-race", "a"),
      escrow.refundEscrow("e-race", "b"),
      escrow.refundEscrow("e-race", "c"),
      escrow.recoverStaleEscrows(),
    ]);

    const refundedByCalls = results.slice(0, 3).filter((r) => r === true).length;
    const refundedByJob = results[3].refunded;
    assert.equal(refundedByCalls + refundedByJob, 1);
    const w = await wallet();
    assert.equal(w.balance, 100);
    assert.equal(w.heldBalance, 0);
    assert.equal(await ledgerCount("REFUND", "e-race"), 1);
  });

  test("ESC-31 a refund racing a release: exactly one wins", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await h.seed(`drivers/${DRIVER}`, { walletBalance: 0 });
    await seedEscrow("e-split", { heldAt: ago(10 * 60 * 1000), referenceId: "order-split" });

    const [refunded, released] = await Promise.all([
      escrow.refundEscrow("e-split", "cancel"),
      escrow.releaseEscrow("e-split", DRIVER, "done",
        { userId: PASSENGER, referenceId: "order-split", referenceType: "gas_order" }),
    ]);

    assert.equal(Number(refunded) + Number(released), 1);
    const w = await wallet();
    const d = await h.read(`drivers/${DRIVER}`);
    if (refunded) {
      assert.equal(w.balance, 100);
      assert.equal(d.walletBalance, 0);
    } else {
      assert.equal(w.balance, 0);
      assert.equal(d.walletBalance, 85);
    }
    assert.equal(w.heldBalance, 0);
  });

  test("ESC-32 a repeated refund after success is a no-op", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("e-twice");

    assert.equal(await escrow.refundEscrow("e-twice"), true);
    assert.equal(await escrow.refundEscrow("e-twice"), false);

    assert.equal((await wallet()).balance, 100);
    assert.equal(await ledgerCount("REFUND", "e-twice"), 1);
  });
});

describe("unknown order states", () => {
  test("ESC-07 a status the code does not know goes to review, never refund or keep", () => {
    for (const collection of ["gas_orders", "deliveries", "trips"]) {
      const d = escrow.staleEscrowAction({
        attached: true, orderFound: true, collection, orderStatus: "teleporting",
      });
      assert.deepEqual(d, { action: "review", reason: "unknown_order_status" }, collection);
    }
  });

  test("ESC-16 recovery leaves an escrow of an unknown-status order held and flags it", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("e-odd", { referenceId: "g-odd" });
    await h.seed("gas_orders/g-odd", { status: "teleporting", escrowId: "e-odd" });

    const summary = await escrow.recoverStaleEscrows();

    assert.equal(summary.refunded, 0);
    assert.deepEqual(summary.review, [{ escrowId: "e-odd", reason: "unknown_order_status" }]);
    assert.equal((await h.read("escrows/e-odd")).status, "HELD");
  });
});

describe("nightly reconciliation", () => {
  // One escrow of each kind, all held for three hours.
  async function seedMix() {
    await seedWallet({ balance: 50, held: 400 });
    await seedEscrow("r-active", { referenceId: "g-active" });
    await h.seed("gas_orders/g-active", { status: "returning", escrowId: "r-active" });
    await seedEscrow("r-active-delivery", { referenceType: "delivery", referenceId: "d-active" });
    await h.seed("deliveries/d-active", { status: "deliveryEnroute", escrowId: "r-active-delivery" });
    await seedEscrow("r-done", { referenceId: "g-done" });
    await h.seed("gas_orders/g-done", { status: "delivered", escrowId: "r-done" });
    await seedEscrow("r-orphan");
    await seedEscrow("r-odd", { referenceId: "g-odd" });
    await h.seed("gas_orders/g-odd", { status: "teleporting", escrowId: "r-odd" });
  }

  test("REC-01 active orders older than two hours are not reported as stuck", async () => {
    await seedWallet({ balance: 0, held: 200 });
    await seedEscrow("r-active", { referenceId: "g-active" });
    await h.seed("gas_orders/g-active", { status: "refilling", escrowId: "r-active" });
    await seedEscrow("r-active-delivery", { referenceType: "delivery", referenceId: "d-active" });
    await h.seed("deliveries/d-active", { status: "pickupEnroute", escrowId: "r-active-delivery" });

    const report = await escrow.runDailyReconciliation();

    assert.equal(report.stuckEscrows, 0);
    assert.equal(report.heldActiveEscrows, 2);
    assert.equal(await h.count("admin_alerts", "type", "reconciliation_anomaly"), 0);
  });

  test("REC-02 completed-but-held, orphaned and unknown-state escrows are reported", async () => {
    await seedMix();

    const report = await escrow.runDailyReconciliation();

    assert.equal(report.stuckEscrows, 3);
    assert.equal(report.heldActiveEscrows, 2);
    const reasons = Object.fromEntries(
      report.stuckEscrowDetails.map((d) => [d.escrowId, d.reason]));
    assert.deepEqual(reasons, {
      "r-done": "settled_order_still_held",
      "r-orphan": "abandoned_hold",
      "r-odd": "unknown_order_status",
    });
    assert.equal(await h.count("admin_alerts", "type", "reconciliation_anomaly"), 1);
    const saved = await h.db().collection("reconciliation").get();
    assert.equal(saved.size, 1);
    assert.equal(saved.docs[0].data().stuckEscrows, 3);
    assert.equal(saved.docs[0].data().totalLiability, 450);
  });

  test("REC-03 an attached escrow whose order is missing is reported", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("r-gone", { referenceType: "delivery", referenceId: "d-gone" });

    const report = await escrow.buildReconciliationReport();

    assert.deepEqual(report.stuckEscrowDetails,
      [{ escrowId: "r-gone", action: "refund", reason: "order_missing" }]);
  });

  test("REC-04 reconciliation reads only: no escrow or wallet changes", async () => {
    await seedMix();
    const before = (await h.db().collection("escrows").get()).docs
      .map((d) => [d.id, d.data().status]);

    await escrow.buildReconciliationReport();

    const after = (await h.db().collection("escrows").get()).docs
      .map((d) => [d.id, d.data().status]);
    assert.deepEqual(after, before);
    assert.deepEqual(await wallet(), { balance: 50, heldBalance: 400 });
  });

  test("REC-05 active escrows held over 24 h still raise an alert", async () => {
    await seedWallet({ balance: 0, held: 100 });
    await seedEscrow("r-old", { referenceId: "g-old", heldAt: ago(30 * HOUR) });
    await h.seed("gas_orders/g-old", { status: "driverAssigned", escrowId: "r-old" });

    const report = await escrow.runDailyReconciliation();

    assert.equal(report.stuckEscrows, 0);
    assert.equal(report.longHeldEscrows, 1);
    assert.equal(await h.count("admin_alerts", "type", "reconciliation_anomaly"), 1);
  });

  test("REC-06 a missing composite index fails reconciliation before it writes anything", async () => {
    // Production lacks both indexes the report needs; each alone must stop it.
    await seedMix();
    for (const index of [{ collection: "ledger", field: "createdAt" },
      { collection: "escrows", field: "heldAt" }]) {
      const intercepted = await h.withMissingIndex(index,
        () => assert.rejects(escrow.runDailyReconciliation(), /FAILED_PRECONDITION/));
      assert.ok(intercepted >= 1, `${index.collection} query failed`);
    }
    assert.equal((await h.db().collection("reconciliation").get()).size, 0);
    assert.equal((await h.db().collection("admin_alerts").get()).size, 0);
    assert.deepEqual(await wallet(), { balance: 50, heldBalance: 400 });
  });
});
