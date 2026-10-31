// Stale escrow recovery safety (Phase 1C).
//
// The deployed releaseStuckEscrows refunds every HELD escrow older than two
// hours. Recovery must instead never refund on age alone: it refunds only
// abandoned holds and holds of orders that ended without the service, and
// only when that order belongs to the escrow's owner and names this hold,
// decided again inside the refund transaction. Everything uncertain is put
// under review, durably and once. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const escrow = require("../../escrow");

const { Timestamp } = h.admin.firestore;
const HOUR = 60 * 60 * 1000;
const ago = (ms) => Timestamp.fromDate(new Date(Date.now() - ms));
const P = "ses-passenger";
const OTHER = "ses-other";

async function seedEscrow(id, o = {}) {
  await h.seed(`escrows/${id}`, { userId: P, amount: 100, platformFee: 15, driverNet: 85,
    status: "HELD", heldAt: ago(3 * HOUR), referenceId: null, referenceType: "gas_order", ...o });
}
const read = (p) => h.read(p);
const refunds = (id) => h.count("ledger", "idempotencyKey", `refund_${id}`);
const reviewAlerts = () => h.count("admin_alerts", "type", "escrow_review_required");

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
  await h.seed(`wallets/${OTHER}`, { balance: 0, heldBalance: 0 });
});

describe("classes", () => {
  test("SES-01 an active order delayed far beyond two hours is never refunded", async () => {
    await seedEscrow("e1", { referenceId: "g1", heldAt: ago(26 * HOUR) });
    await h.seed("gas_orders/g1", { status: "refilling", passengerId: P, escrowId: "e1" });
    const s = await escrow.recoverStaleEscrows();
    assert.equal(s.refunded, 0);
    assert.deepEqual(s.longHeld, ["e1"]);
    assert.equal((await read("escrows/e1")).status, "HELD");
    assert.equal((await read("escrows/e1")).reviewStatus, undefined, "active is not review");
  });

  test("SES-02 a completed order whose settlement failed goes under review once", async () => {
    await seedEscrow("e1", { referenceId: "g1" });
    await h.seed("gas_orders/g1", { status: "delivered", passengerId: P, escrowId: "e1",
      deliveredAt: ago(2.5 * HOUR), settlementStatus: "failed", settlementFailureReason: "x" });
    const s1 = await escrow.recoverStaleEscrows();
    assert.deepEqual(s1.review, [{ escrowId: "e1", reason: "settled_order_still_held" }]);
    const e = await read("escrows/e1");
    assert.equal(e.status, "HELD");
    assert.equal(e.reviewStatus, "pending");
    assert.equal(e.reviewReason, "settled_order_still_held");
    assert.ok(e.reviewFlaggedAt, "review time recorded");
    assert.equal(await reviewAlerts(), 1);
    const alert = (await h.db().collection("admin_alerts")
      .where("type", "==", "escrow_review_required").get()).docs[0].data();
    assert.deepEqual([alert.escrowId, alert.orderCollection, alert.orderId], ["e1", "gas_orders", "g1"]);

    const s2 = await escrow.recoverStaleEscrows();
    assert.deepEqual(s2.review, [], "not re-flagged");
    assert.equal(s2.underReview, 1);
    assert.equal(await reviewAlerts(), 1, "alerted once");
  });

  test("SES-03 a cancelled order of the same owner naming this hold is refunded once", async () => {
    await seedEscrow("e1", { referenceId: "g1" });
    await h.seed("gas_orders/g1", { status: "cancelled", passengerId: P, escrowId: "e1" });
    await escrow.recoverStaleEscrows();
    await escrow.recoverStaleEscrows();
    assert.equal((await read("escrows/e1")).status, "REFUNDED");
    assert.equal((await read("escrows/e1")).releaseReason, "auto_order_cancelled");
    assert.equal((await read(`wallets/${P}`)).balance, 100);
    assert.equal(await refunds("e1"), 1);
  });

  test("SES-04 a cancelled order of another passenger: review, never refund", async () => {
    await seedEscrow("e1", { referenceId: "g1" });
    await h.seed("gas_orders/g1", { status: "cancelled", passengerId: OTHER, escrowId: "e1" });
    const s = await escrow.recoverStaleEscrows();
    assert.deepEqual(s.review, [{ escrowId: "e1", reason: "escrow_owner_mismatch" }]);
    assert.equal((await read("escrows/e1")).status, "HELD");
    assert.equal(await refunds("e1"), 0);
    assert.equal((await read(`wallets/${OTHER}`)).balance, 0);
  });

  test("SES-05 a cancelled order without a passenger: review, never refund", async () => {
    await seedEscrow("e1", { referenceId: "g1" });
    await h.seed("gas_orders/g1", { status: "cancelled", escrowId: "e1" });
    const s = await escrow.recoverStaleEscrows();
    assert.deepEqual(s.review, [{ escrowId: "e1", reason: "escrow_owner_mismatch" }]);
    assert.equal((await read("escrows/e1")).status, "HELD");
  });

  test("SES-06 a cancelled order that names a different hold: review", async () => {
    await seedEscrow("e1", { referenceId: "g1" });
    await h.seed("gas_orders/g1", { status: "cancelled", passengerId: P, escrowId: "e-other" });
    const s = await escrow.recoverStaleEscrows();
    assert.deepEqual(s.review, [{ escrowId: "e1", reason: "order_names_other_escrow" }]);
    assert.equal((await read("escrows/e1")).status, "HELD");
  });

  test("SES-07 an unattached hold no order names is returned to its owner", async () => {
    await seedEscrow("e1");
    const s = await escrow.recoverStaleEscrows();
    assert.equal(s.refunded, 1);
    assert.equal((await read("escrows/e1")).releaseReason, "auto_abandoned_hold");
  });

  test("SES-08 an unattached hold named by an active order of another service is kept", async () => {
    // The hold's referenceType came from the client and says gas; the order is a trip.
    await seedEscrow("e1", { referenceType: "gas_order" });
    await h.seed("trips/t1", { status: "tripStarted", passengerId: P, escrowId: "e1" });
    const s = await escrow.recoverStaleEscrows();
    assert.equal(s.refunded, 0);
    assert.equal(s.kept, 1);
    assert.equal((await read("escrows/e1")).status, "HELD");
  });

  test("SES-09 a refunded or released escrow is never touched again", async () => {
    await seedEscrow("e1", { status: "REFUNDED" });
    await seedEscrow("e2", { status: "RELEASED", referenceId: "g2" });
    const s = await escrow.recoverStaleEscrows();
    assert.equal(s.refunded + s.kept + s.review.length + s.underReview, 0);
    assert.equal(await refunds("e1"), 0);
  });

  test("SES-10 once under review, a later cancellation does not trigger a refund", async () => {
    await seedEscrow("e1", { referenceId: "g1" });
    await h.seed("gas_orders/g1", { status: "teleporting", passengerId: P, escrowId: "e1" });
    await escrow.recoverStaleEscrows();
    assert.equal((await read("escrows/e1")).reviewStatus, "pending");
    await h.seed("gas_orders/g1", { status: "cancelled", passengerId: P, escrowId: "e1" });
    const s = await escrow.recoverStaleEscrows();
    assert.equal(s.refunded, 0);
    assert.equal(s.underReview, 1);
    assert.equal((await read("escrows/e1")).status, "HELD");
  });
});

describe("races, retries and duplicate runs", () => {
  test("SES-20 two concurrent scheduled runs refund once and alert once", async () => {
    await seedEscrow("e-cancel", { referenceId: "g1" });
    await h.seed("gas_orders/g1", { status: "cancelled", passengerId: P, escrowId: "e-cancel" });
    await seedEscrow("e-review", { referenceId: "g2" });
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 200 });
    await h.seed("gas_orders/g2", { status: "delivered", passengerId: P, escrowId: "e-review" });
    await Promise.all([escrow.recoverStaleEscrows(), escrow.recoverStaleEscrows(),
      escrow.recoverStaleEscrows()]);
    assert.equal(await refunds("e-cancel"), 1);
    assert.equal((await read(`wallets/${P}`)).balance, 100);
    assert.equal(await reviewAlerts(), 1);
  });

  test("SES-21 an order reactivated after assessment is not refunded", async () => {
    await seedEscrow("e1", { referenceId: "g1" });
    await h.seed("gas_orders/g1", { status: "cancelled", passengerId: P, escrowId: "e1" });
    const [item] = await escrow.assessStaleEscrows();
    assert.equal(item.action, "refund");
    // The order changes between the assessment and the refund.
    await h.seed("gas_orders/g1", { status: "driverAssigned", passengerId: P, escrowId: "e1" });
    const r = await escrow.refundStaleEscrow("e1");
    assert.equal(r.refunded, false);
    assert.equal(r.action, "keep");
    assert.equal((await read("escrows/e1")).status, "HELD");
  });

  test("SES-22 an order re-owned after assessment is reviewed, not refunded", async () => {
    await seedEscrow("e1", { referenceId: "g1" });
    await h.seed("gas_orders/g1", { status: "cancelled", passengerId: P, escrowId: "e1" });
    await escrow.assessStaleEscrows();
    await h.seed("gas_orders/g1", { status: "cancelled", passengerId: OTHER, escrowId: "e1" });
    const r = await escrow.refundStaleEscrow("e1");
    assert.deepEqual([r.refunded, r.action, r.reason], [false, "review", "escrow_owner_mismatch"]);
  });

  test("SES-23 a hold that is not stale, or no longer held, is never refunded directly", async () => {
    await seedEscrow("e-fresh", { heldAt: ago(30 * 60 * 1000) });
    assert.equal((await escrow.refundStaleEscrow("e-fresh")).refunded, false);
    await seedEscrow("e-gone", { status: "RELEASED" });
    assert.equal((await escrow.refundStaleEscrow("e-gone")).refunded, false);
    assert.equal((await escrow.refundStaleEscrow("e-missing")).refunded, false);
  });

  test("SES-24 one failing lookup does not stop the others", async () => {
    await seedEscrow("e-bad", { referenceId: "bad/id", referenceType: "gas_order" });
    await seedEscrow("e-ok");
    const s = await escrow.recoverStaleEscrows();
    assert.equal(s.failed, 1);
    assert.equal(s.refunded, 1);
    assert.equal((await read("escrows/e-bad")).status, "HELD");
  });

  test("SES-25 concurrent review flags write one state and one alert", async () => {
    await seedEscrow("e1", { referenceId: "g1" });
    const results = await Promise.all([1, 2, 3, 4].map(() =>
      escrow.markEscrowForReview("e1", "manual_check", { orderCollection: "gas_orders", orderId: "g1" })));
    assert.equal(results.filter(Boolean).length, 1);
    assert.equal(await reviewAlerts(), 1);
    assert.equal((await read("escrows/e1")).reviewStatus, "pending");
  });

  test("SES-26 a missing composite index fails the scan before any write", async () => {
    // Production has no escrows(status, heldAt) index yet: the scan fails.
    await seedEscrow("e-cancel", { referenceId: "g-cancel" });
    await h.seed("gas_orders/g-cancel", { passengerId: P, status: "cancelled", escrowId: "e-cancel" });
    await seedEscrow("e-done", { referenceId: "g-done" });
    await h.seed("gas_orders/g-done", { passengerId: P, status: "delivered", escrowId: "e-done" });
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 200 });

    const intercepted = await h.withMissingIndex({ collection: "escrows", field: "heldAt" },
      () => assert.rejects(escrow.recoverStaleEscrows(), /FAILED_PRECONDITION/));
    assert.ok(intercepted >= 1, "the stale-escrow scan itself failed");

    for (const id of ["e-cancel", "e-done"]) {
      const e = await read(`escrows/${id}`);
      assert.equal(e.status, "HELD");
      assert.equal(e.reviewStatus, undefined, "nothing put under review");
    }
    assert.equal((await h.db().collection("ledger").get()).size, 0);
    assert.equal((await h.db().collection("admin_alerts").get()).size, 0);
    assert.deepEqual(await read(`wallets/${P}`), { balance: 0, heldBalance: 200 });

    // Once the index exists, the same data is refunded and reviewed once.
    const s = await escrow.recoverStaleEscrows();
    assert.equal(s.refunded, 1);
    assert.deepEqual(s.review.map((r) => r.escrowId), ["e-done"]);
  });

  test("SES-27 a refund failing inside its transaction changes nothing; others still settle, once", async () => {
    // e-fail's owner has no wallet document: the refund transaction aborts
    // after the decision to refund, on its wallet write.
    await seedEscrow("e-fail", { userId: "ses-no-wallet", referenceId: "g-fail" });
    await h.seed("gas_orders/g-fail", { passengerId: "ses-no-wallet", status: "cancelled", escrowId: "e-fail" });
    await seedEscrow("e-ok", { referenceId: "g-ok" });
    await h.seed("gas_orders/g-ok", { passengerId: P, status: "cancelled", escrowId: "e-ok" });

    const s = await escrow.recoverStaleEscrows();
    assert.equal(s.refunded, 1);
    assert.equal(s.failed, 1);
    assert.deepEqual([s.review.length, s.underReview], [0, 0], "decided as a refund, not a review");

    const failed = await read("escrows/e-fail");
    assert.equal(failed.status, "HELD");
    assert.equal(failed.releaseReason, undefined);
    assert.equal(await read("wallets/ses-no-wallet"), null, "no partial wallet write");
    assert.equal(await refunds("e-fail"), 0);
    assert.equal((await read("escrows/e-ok")).status, "REFUNDED");
    assert.equal(await refunds("e-ok"), 1);

    // A repeated run refunds nothing twice and still cannot refund e-fail.
    const again = await escrow.recoverStaleEscrows();
    assert.deepEqual([again.refunded, again.failed], [0, 1]);
    assert.equal(await refunds("e-ok"), 1);
    assert.equal((await h.db().collection("ledger").get()).size, 1);
    const w = await read(`wallets/${P}`);
    assert.deepEqual([w.balance, w.heldBalance], [100, 0], "e-ok returned exactly once");
  });
});

describe("staleEscrowDecision (pure)", () => {
  const snap = (data) => ({ id: "o1", data: () => data });
  test("SES-30 checks run only before an automatic refund", () => {
    const d = (order, data = { userId: P }) => escrow.staleEscrowDecision("e1", data,
      { attached: true, collection: "trips", order: order ? snap(order) : null });
    assert.equal(d({ status: "tripStarted", passengerId: OTHER }).action, "keep");
    assert.equal(d({ status: "completed", passengerId: OTHER }).reason, "settled_order_still_held");
    assert.equal(d({ status: "cancelled", passengerId: OTHER }).reason, "escrow_owner_mismatch");
    assert.equal(d({ status: "cancelled", passengerId: P, escrowId: "x" }).reason, "order_names_other_escrow");
    assert.equal(d({ status: "cancelled", passengerId: P, escrowId: "e1" }).action, "refund");
    assert.equal(d(null).reason, "order_missing");
    assert.equal(d({ status: "cancelled", passengerId: P },
      { userId: P, reviewStatus: "pending", reviewReason: "r" }).action, "review");
  });
});
