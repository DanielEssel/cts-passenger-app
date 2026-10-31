// Stale-escrow recovery (releaseStuckEscrows -> recoverStaleEscrows) for Gas
// supplier orders. Holds are bound by gas_supplier_fulfilment.js
// payGasSupplierOrder: escrow.referenceType "gas_supplier_order",
// escrow.referenceId = order id, order.payment.escrowId = escrow id.
// Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const escrow = require("../../escrow");

const { Timestamp } = h.admin.firestore;
const HOUR = 60 * 60 * 1000;
const ago = (ms) => Timestamp.fromDate(new Date(Date.now() - ms));
const PAX = "sso-passenger";
const OTHER = "sso-other";
const TYPE = "gas_supplier_order";

async function seedWallet(uid = PAX, { balance = 0, held = 0 } = {}) {
  await h.seed(`wallets/${uid}`, { userId: uid, balance, heldBalance: held });
}

async function seedEscrow(id, { amount = 220, heldAt = ago(3 * HOUR), referenceId = null, status = "HELD", userId = PAX, referenceType = TYPE } = {}) {
  await h.seed(`escrows/${id}`, {
    id, userId, serviceType: "gas", referenceType, referenceId, amount,
    platformFee: 33, driverNet: 187, status, heldAt, releasedAt: null,
  });
}

/** A supplier order as gas_supplier_orders.js / gas_supplier_fulfilment.js write it. */
async function seedOrder(id, { status = "confirmed", escrowId = null, passengerId = PAX, extra = {} } = {}) {
  await h.seed(`gas_supplier_orders/${id}`, {
    passengerId, supplierId: "sup1", stationId: "st1", productId: "p1", orderType: "exchangeEmpty", cylinderSize: "kg12_5", quantity: 1,
    priceSnapshot: { supplierId: "sup1", total: 220, productAmount: 200, deliveryFee: 20, handlingFee: 0 },
    status, createdAt: ago(4 * HOUR),
    ...(escrowId ? { payment: { escrowId, amount: 220, verifiedAt: ago(4 * HOUR) } } : {}),
    ...extra,
  });
}

/** A hold bound to an order, exactly as payGasSupplierOrder binds it. */
async function seedBound(escrowId, orderId, orderOpts = {}, escrowOpts = {}) {
  await seedEscrow(escrowId, { referenceId: orderId, ...escrowOpts });
  await seedOrder(orderId, { escrowId, ...orderOpts });
}

const refundRows = async (escrowId) => h.db().collection("ledger").where("idempotencyKey", "==", `refund_${escrowId}`).get().then((s) => s.size);
const reviewAlerts = async (escrowId) => (await h.db().collection("admin_alerts").where("type", "==", "escrow_review_required").get())
  .docs.filter((d) => d.data().details?.escrowId === escrowId || JSON.stringify(d.data()).includes(escrowId)).length;

after(() => h.fft.cleanup());
beforeEach(async () => { await h.clearFirestore(); await seedWallet(PAX, { balance: 0, held: 220 }); });

describe("supplier orders still in progress", () => {
  test("SSO-01 a bound hold on an active order older than two hours is kept, not refunded or flagged", async () => {
    const active = ["pendingApproval", "confirmed", "driverAssigned", "atStation", "outForDelivery"];
    for (const [i, status] of active.entries()) await seedBound(`e${i}`, `o${i}`, { status });
    await seedWallet(PAX, { balance: 0, held: 220 * active.length });
    const summary = await escrow.recoverStaleEscrows();
    assert.equal(summary.refunded, 0);
    assert.equal(summary.kept, active.length);
    assert.deepEqual(summary.review, []);
    for (const i of active.keys()) {
      const e = await h.read(`escrows/e${i}`);
      assert.equal(e.status, "HELD");
      assert.equal(e.reviewStatus, undefined, `e${i} must not be put under review`);
    }
    assert.equal((await h.read(`wallets/${PAX}`)).balance, 0);
    assert.equal(await h.count("admin_alerts", "type", "escrow_review_required"), 0);
  });

  test("SSO-02 an active order held over 24 hours is reported as long-held, still not refunded", async () => {
    await seedBound("e1", "o1", { status: "outForDelivery" }, { heldAt: ago(30 * HOUR) });
    const summary = await escrow.recoverStaleEscrows();
    assert.deepEqual(summary.longHeld, ["e1"]);
    assert.equal((await h.read("escrows/e1")).status, "HELD");
  });

  test("SSO-03 a recent hold is not touched at all", async () => {
    await seedEscrow("fresh", { heldAt: ago(30 * 60 * 1000) });
    const summary = await escrow.recoverStaleEscrows();
    assert.equal(summary.refunded + summary.kept + summary.review.length, 0);
  });
});

describe("unattached holds (the app's refundEscrowOnError did not run or failed)", () => {
  test("SSO-10 a stale unbound supplier hold with no order naming it is refunded to its owner, once", async () => {
    // The order exists but was never paid: payGasSupplierOrder refused, so nothing was bound.
    await seedOrder("o-unpaid", { status: "awaiting_payment" });
    await seedEscrow("orphan");
    const summary = await escrow.recoverStaleEscrows();
    assert.equal(summary.refunded, 1);
    assert.equal((await h.read("escrows/orphan")).status, "REFUNDED");
    const w = await h.read(`wallets/${PAX}`);
    assert.deepEqual([w.balance, w.heldBalance], [220, 0]);
    assert.equal(await refundRows("orphan"), 1);
    assert.equal((await h.read("gas_supplier_orders/o-unpaid")).status, "awaiting_payment");
  });

  test("SSO-11 an unbound hold that a supplier order nevertheless names is not treated as abandoned", async () => {
    // Inconsistent: payment.escrowId written without the binding.
    await seedEscrow("half");
    await seedOrder("o-half", { status: "pendingApproval", escrowId: "half" });
    const summary = await escrow.recoverStaleEscrows();
    assert.equal(summary.refunded, 0);
    assert.equal((await h.read("escrows/half")).status, "HELD");
  });
});

describe("captured payments", () => {
  test("SSO-20 a CAPTURED supplier-order payment is never refunded or released, however old, on every rerun", async () => {
    await seedBound("cap", "o-cap", { status: "delivered", extra: { deliveredAt: ago(48 * HOUR) } }, { status: "CAPTURED", heldAt: ago(72 * HOUR) });
    for (let i = 0; i < 3; i++) await escrow.recoverStaleEscrows();
    const e = await h.read("escrows/cap");
    assert.equal(e.status, "CAPTURED");
    assert.equal(e.reviewStatus, undefined);
    assert.equal(await refundRows("cap"), 0);
    assert.equal(await h.count("ledger", "type", "RELEASE"), 0);
    assert.equal((await h.read(`wallets/${PAX}`)).balance, 0);
    assert.equal((await escrow.assessStaleEscrows()).length, 0, "captured holds are not even assessed");
    assert.deepEqual(await escrow.refundStaleEscrow("cap"), { refunded: false, reason: "escrow_not_held" });
  });
});

describe("terminal supplier orders", () => {
  test("SSO-30 a delivered order whose hold is still HELD goes to review, never refunded", async () => {
    await seedBound("e-del", "o-del", { status: "delivered", extra: { deliveredAt: ago(3 * HOUR) } });
    const summary = await escrow.recoverStaleEscrows();
    assert.deepEqual(summary.review, [{ escrowId: "e-del", reason: "settled_order_still_held" }]);
    assert.equal((await h.read("escrows/e-del")).status, "HELD");
    assert.equal((await h.read("escrows/e-del")).reviewStatus, "pending");
  });

  test("SSO-31 a cancelled order whose own refund did not finish is refunded, and the order records it", async () => {
    await seedBound("e-can", "o-can", { status: "cancelled", extra: { refundPending: true, cancelledAt: ago(3 * HOUR) } });
    const summary = await escrow.recoverStaleEscrows();
    assert.equal(summary.refunded, 1);
    assert.equal((await h.read("escrows/e-can")).status, "REFUNDED");
    const o = await h.read("gas_supplier_orders/o-can");
    assert.equal(o.refundPending, false);
    assert.equal(o.refundedBy, "stale_escrow_recovery");
    assert.deepEqual(await h.read(`wallets/${PAX}`).then((w) => [w.balance, w.heldBalance]), [220, 0]);
  });

  test("SSO-32 a cancelled order that was delivered, or whose refund is under review, is not refunded automatically", async () => {
    await seedBound("e-late", "o-late", { status: "cancelled", extra: { deliveredAt: ago(5 * HOUR) } });
    await seedBound("e-rev", "o-rev", { status: "cancelled", extra: { refundPending: true, refundReview: "escrow_released" } });
    await seedWallet(PAX, { balance: 0, held: 440 });
    const summary = await escrow.recoverStaleEscrows();
    assert.equal(summary.refunded, 0);
    const reasons = Object.fromEntries(summary.review.map((r) => [r.escrowId, r.reason]));
    assert.deepEqual(reasons, { "e-late": "cancelled_after_completion", "e-rev": "supplier_refund_under_review" });
  });
});

describe("missing or inconsistent state fails safe", () => {
  const cases = [
    ["bound hold, order missing", async () => seedEscrow("x", { referenceId: "gone" }), "supplier_order_missing"],
    ["order names a different hold", async () => { await seedEscrow("x", { referenceId: "o" }); await seedOrder("o", { escrowId: "other" }); }, "order_names_other_escrow"],
    ["order names no hold at all", async () => { await seedEscrow("x", { referenceId: "o" }); await seedOrder("o", { status: "confirmed" }); }, "order_names_other_escrow"],
    ["bound hold on an unpaid order", async () => seedBound("x", "o", { status: "awaiting_payment" }), "unknown_order_status"],
    ["order without a status", async () => seedBound("x", "o", { status: "" }), "order_without_status"],
    ["status the code does not know", async () => seedBound("x", "o", { status: "lost_in_transit" }), "unknown_order_status"],
    ["cancelled order of another passenger", async () => seedBound("x", "o", { status: "cancelled", passengerId: OTHER, extra: { refundPending: true } }), "escrow_owner_mismatch"],
  ];
  for (const [name, setup, reason] of cases) {
    test(`SSO-40 ${name}: review (${reason}), nothing refunded`, async () => {
      await setup();
      const summary = await escrow.recoverStaleEscrows();
      assert.equal(summary.refunded, 0);
      assert.deepEqual(summary.review, [{ escrowId: "x", reason }]);
      assert.equal((await h.read("escrows/x")).status, "HELD");
      assert.equal(await refundRows("x"), 0);
    });
  }

  test("SSO-41 an unknown reference type still goes to review, as before", async () => {
    await seedEscrow("x", { referenceId: "o", referenceType: "something_new" });
    const summary = await escrow.recoverStaleEscrows();
    assert.deepEqual(summary.review, [{ escrowId: "x", reason: "unknown_reference_type" }]);
  });
});

describe("reruns and concurrency", () => {
  test("SSO-50 reruns flag a review once and refund once", async () => {
    await seedBound("e-del", "o-del", { status: "delivered", extra: { deliveredAt: ago(3 * HOUR) } });
    await seedEscrow("orphan");
    await seedWallet(PAX, { balance: 0, held: 440 });
    await escrow.recoverStaleEscrows();
    const second = await escrow.recoverStaleEscrows();
    assert.equal(second.refunded, 0);
    assert.equal(second.underReview, 1);
    assert.equal(await h.count("admin_alerts", "type", "escrow_review_required"), 1);
    assert.equal(await refundRows("orphan"), 1);
    assert.equal((await h.read(`wallets/${PAX}`)).balance, 220);
  });

  test("SSO-51 concurrent sweeps refund a hold exactly once", async () => {
    await seedBound("e-can", "o-can", { status: "cancelled", extra: { refundPending: true } });
    await seedEscrow("orphan");
    await seedWallet(PAX, { balance: 0, held: 440 });
    const runs = await Promise.all([1, 2, 3].map(() => escrow.recoverStaleEscrows()));
    assert.equal(runs.reduce((t, r) => t + r.refunded, 0), 2);
    assert.equal(await refundRows("e-can"), 1);
    assert.equal(await refundRows("orphan"), 1);
    assert.deepEqual(await h.read(`wallets/${PAX}`).then((w) => [w.balance, w.heldBalance]), [440, 0]);
  });

  test("SSO-52 a payment that becomes active between assessment and refund wins", async () => {
    await seedEscrow("race");
    const assessed = await escrow.assessStaleEscrows();
    assert.equal(assessed.find((a) => a.escrowId === "race").action, "refund");
    // payGasSupplierOrder binds it before the refund transaction runs.
    await h.db().doc("escrows/race").update({ referenceId: "o-race" });
    await seedOrder("o-race", { status: "pendingApproval", escrowId: "race" });
    const r = await escrow.refundStaleEscrow("race");
    assert.equal(r.refunded, false);
    assert.equal(r.action, "keep");
    assert.equal((await h.read("escrows/race")).status, "HELD");
  });
});

describe("other order types are unchanged", () => {
  test("SSO-60 the classification of trips, deliveries and gas orders is as before", () => {
    const a = escrow.staleEscrowAction;
    assert.deepEqual(a({ attached: true, orderFound: false }), { action: "refund", reason: "order_missing" });
    assert.deepEqual(a({ attached: true, orderFound: true, collection: "trips", orderStatus: "inProgress" }), { action: "keep", reason: "order_in_progress" });
    assert.deepEqual(a({ attached: true, orderFound: true, collection: "gas_orders", orderStatus: "cancelled" }), { action: "refund", reason: "order_cancelled" });
    assert.deepEqual(a({ attached: true, orderFound: true, collection: "deliveries", orderStatus: "completed" }), { action: "review", reason: "settled_order_still_held" });
  });

  test("SSO-61 a trip escrow whose order is missing is still refunded (existing policy)", async () => {
    await seedEscrow("t", { referenceType: "trip", referenceId: "trip-gone" });
    const summary = await escrow.recoverStaleEscrows();
    assert.equal(summary.refunded, 1);
  });
});
