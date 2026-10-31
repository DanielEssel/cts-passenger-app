// adminAttachEscrow (Phase 1C): an active admin, checked on the server, may
// link a HELD, unattached escrow to the order it paid for, with every check
// of the passenger attach plus order state and exact amount, and an audit
// record. It never moves money, cancels, refunds or clears a failed
// settlement. Firestore emulator only.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const escrow = require("../../escrow");
const trips = require("../../trips");

const P = "adm-passenger";
const OTHER = "adm-other";
const D = "adm-driver";
const ADMIN = "admin-1";
const REASON = "App attach failed after booking; verified hold and order";

const call = (uid, data) => h.callCallable(escrow.adminAttachEscrow, uid, data);
const req = (o = {}) => ({ escrowId: "e1", referenceId: "g1", referenceType: "gas_order", reason: REASON, ...o });

async function seedEscrow(id = "e1", o = {}) {
  await h.seed(`escrows/${id}`, { id, userId: P, amount: 100, platformFee: 15, driverNet: 85,
    status: "HELD", referenceId: null, referenceType: "gas_order", ...o });
}
const gasOrder = (o = {}) => ({ passengerId: P, driverId: D, status: "delivered", totalPrice: 100,
  refillType: "exchangeEmpty", cylinderSize: "kg3", quantity: 1,
  paymentMethod: "wallet", deliveryOtp: "4821", otpSubmitted: "4821",
  settlementStatus: "failed", settlementFailureReason: "escrow_unattached", ...o });

async function rejects(promise, code) {
  await assert.rejects(promise, (e) => { assert.equal(e.code, code, e.message); return true; });
}
const audits = () => h.count("admin_escrow_actions", "action", "attach_escrow");

/** Escrow, order, link, wallet and audit unchanged by a refused call. */
async function assertUntouched() {
  const e = await h.read("escrows/e1");
  assert.equal(e.status, "HELD");
  assert.equal(e.referenceId, null);
  assert.equal((await h.read("gas_orders/g1"))?.escrowId, undefined);
  assert.equal(await h.read("escrowOrderLinks/gas_order:g1"), null);
  assert.deepEqual(await h.read(`wallets/${P}`), { balance: 0, heldBalance: 100 });
  assert.equal(await audits(), 0);
}

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed(`admins/${ADMIN}`, { active: true, email: "ops@example.test" });
  await h.seed("admins/admin-off", { active: false });
  await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
  await h.seed(`drivers/${D}`, { walletBalance: 0 });
  await h.seed("settings/platform", { platformFeePercent: 15 });
  await seedEscrow();
  await h.seed("gas_orders/g1", gasOrder());
});

describe("authorization", () => {
  test("ADM-01 unauthenticated, non-admin and inactive-admin callers are refused", async () => {
    await rejects(call(null, req()), "unauthenticated");
    await rejects(call(P, req()), "permission-denied");
    await rejects(call("admin-off", req()), "permission-denied");
    await rejects(call(P, req({ isAdmin: true, admin: true })), "permission-denied");
    await assertUntouched();
  });

  test("ADM-02 a reason is required", async () => {
    await rejects(call(ADMIN, req({ reason: "" })), "invalid-argument");
    await rejects(call(ADMIN, req({ reason: undefined })), "invalid-argument");
    await assertUntouched();
  });
});

describe("a valid recovery", () => {
  test("ADM-10 links escrow and order, writes one audit, moves no money, keeps the failure", async () => {
    const r = await call(ADMIN, req());
    assert.equal(r.success, true);
    const e = await h.read("escrows/e1");
    assert.deepEqual([e.status, e.referenceId, e.referenceType], ["HELD", "g1", "gas_order"]);
    const o = await h.read("gas_orders/g1");
    assert.equal(o.escrowId, "e1", "order points at its payment");
    assert.equal(o.settlementStatus, "failed", "failed settlement is not cleared");
    assert.equal(o.walletProcessed, undefined);
    const link = await h.read("escrowOrderLinks/gas_order:g1");
    assert.deepEqual([link.escrowId, link.userId, link.linkedBy], ["e1", P, ADMIN]);
    assert.deepEqual(await h.read(`wallets/${P}`), { balance: 0, heldBalance: 100 });
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 0);
    assert.equal(await audits(), 1);
    const audit = (await h.db().collection("admin_escrow_actions").get()).docs[0].data();
    assert.equal(audit.adminUid, ADMIN);
    assert.equal(audit.reason, REASON);
    assert.deepEqual([audit.escrowId, audit.referenceId, audit.passengerId, audit.amount], ["e1", "g1", P, 100]);
    assert.ok(!JSON.stringify(audit).includes("4821"), "no completion code in the audit");
  });

  test("ADM-11 retrying settlement after recovery pays once, still fully verified", async () => {
    await call(ADMIN, req());
    // Operations clear the failure; the next event runs settlement again.
    const o = { ...(await h.read("gas_orders/g1")), settlementStatus: null, settlementFailureReason: null };
    await h.seed("gas_orders/g1", o);
    await trips.onGasOrderCompleted.run({ params: { orderId: "g1" },
      data: { before: { data: () => ({ ...o, status: "returning" }) }, after: { data: () => o } } });
    assert.equal((await h.read("escrows/e1")).status, "RELEASED");
    assert.equal((await h.read(`drivers/${D}`)).walletBalance, 85);
    assert.equal(await h.count("ledger", "idempotencyKey", "capture_e1"), 1);
  });

  test("ADM-12 a repeated call is idempotent: one link, one audit", async () => {
    await call(ADMIN, req());
    const r = await call(ADMIN, req());
    assert.equal(r.alreadyAttached, true);
    assert.equal(await audits(), 1);
  });

  test("ADM-13 concurrent identical calls link once and audit once", async () => {
    const rs = await Promise.allSettled([1, 2, 3].map(() => call(ADMIN, req())));
    assert.ok(rs.every((r) => r.status === "fulfilled"), JSON.stringify(rs.map((r) => r.reason?.message)));
    assert.equal(await audits(), 1);
    assert.equal((await h.read("escrows/e1")).referenceId, "g1");
  });

  test("ADM-14 two escrows racing for one order: exactly one is linked", async () => {
    await seedEscrow("e2");
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 200 });
    const rs = await Promise.allSettled([call(ADMIN, req()), call(ADMIN, req({ escrowId: "e2" }))]);
    assert.equal(rs.filter((r) => r.status === "fulfilled").length, 1);
    assert.equal(await audits(), 1);
    const linked = [(await h.read("escrows/e1")).referenceId, (await h.read("escrows/e2")).referenceId];
    assert.equal(linked.filter((x) => x === "g1").length, 1);
  });
});

describe("refusals change nothing", () => {
  test("ADM-20 the order belongs to another passenger", async () => {
    await h.seed("gas_orders/g1", gasOrder({ passengerId: OTHER }));
    await rejects(call(ADMIN, req()), "permission-denied");
    await assertUntouched();
  });

  test("ADM-21 the held amount differs from the booked price", async () => {
    await h.seed("gas_orders/g1", gasOrder({ totalPrice: 120 }));
    await rejects(call(ADMIN, req()), "failed-precondition");
    await assertUntouched();
  });

  test("ADM-22 wrong reference: another service or a missing order", async () => {
    await rejects(call(ADMIN, req({ referenceType: "delivery" })), "not-found");
    await rejects(call(ADMIN, req({ referenceId: "nope" })), "not-found");
    await rejects(call(ADMIN, req({ referenceType: "toString" })), "invalid-argument");
    await assertUntouched();
  });

  test("ADM-23 the escrow is already attached to another order", async () => {
    await seedEscrow("e1", { referenceId: "g-other" });
    await rejects(call(ADMIN, req()), "failed-precondition");
    assert.equal((await h.read("escrows/e1")).referenceId, "g-other");
    assert.equal(await audits(), 0);
  });

  test("ADM-24 the order already names a different escrow", async () => {
    await h.seed("gas_orders/g1", gasOrder({ escrowId: "e-else" }));
    await rejects(call(ADMIN, req()), "failed-precondition");
    assert.equal(await audits(), 0);
  });

  test("ADM-25 cancelled, settled or unknown-status orders are not recovered here", async () => {
    for (const o of [{ status: "cancelled" }, { walletProcessed: true }, { status: "teleporting" }]) {
      await h.seed("gas_orders/g1", gasOrder(o));
      await rejects(call(ADMIN, req()), "failed-precondition");
    }
    assert.equal(await audits(), 0);
    assert.equal((await h.read("escrows/e1")).referenceId, null);
  });

  test("ADM-26 an escrow that is not HELD", async () => {
    await seedEscrow("e1", { status: "REFUNDED" });
    await rejects(call(ADMIN, req()), "failed-precondition");
    assert.equal(await audits(), 0);
  });

  test("ADM-27 a failed price check refuses without cancelling or refunding the booking", async () => {
    await h.clearFirestore();
    await h.seed(`admins/${ADMIN}`, { active: true });
    await h.seed(`wallets/${P}`, { balance: 0, heldBalance: 100 });
    // No settings: a ride's price cannot be verified.
    await seedEscrow("e1", { referenceType: "trip" });
    await h.seed("trips/t1", { passengerId: P, status: "tripStarted", estimatedFare: 100,
      paymentMethod: "wallet", serviceType: "taxi" });
    await rejects(call(ADMIN, req({ referenceId: "t1", referenceType: "trip" })), "failed-precondition");
    assert.equal((await h.read("trips/t1")).status, "tripStarted", "booking not cancelled");
    assert.equal((await h.read("escrows/e1")).status, "HELD", "not refunded");
    assert.deepEqual(await h.read(`wallets/${P}`), { balance: 0, heldBalance: 100 });
    assert.equal(await audits(), 0);
  });
});
