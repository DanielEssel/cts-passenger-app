// Gas supplier settlement (gas_settlement_ledger.js): the agreed allocation
// in exact pesewas (commission on the product subtotal only; handling fee to
// the supplier; delivery fee to the driver), versioned commission terms
// approved by a second super admin, idempotent posting from the order's
// locked allocation, append-only reversals, derived statuses, and daily
// statements that claim each entry once and reconcile against the
// allocation. Accounting only: no wallet, driver balance or shared ledger
// is touched. Firestore emulator only. Delivered orders, escrows and
// allocations are seeded here (the end-to-end path is in
// gas_supplier_fulfilment.test.js). Rates are test fixtures, not commercial.

"use strict";

const { test, describe, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const h = require("./helpers");
const L = require("../../gas_settlement_ledger");

const { Timestamp } = h.admin.firestore;
const P = "gsl-passenger", D = "gsl-driver", S = "sup1";
const SUPER = "gsl-super", SUPER2 = "gsl-super2", PLAIN = "gsl-admin", INACTIVE = "gsl-inactive";
const DAY = "2026-10-20";
const DELIVERED = Date.parse(`${DAY}T10:00:00Z`);
const NEXT_DAY_NOON = Date.parse("2026-10-21T12:00:00Z");

const call = (fn, data, uid) => h.callCallable(fn, uid, data);
const ids = (o) => ["supplier__entitlement", "driver__entitlement", "platform__commission"].map((k) => `${o}__${k}`);

function snapshot(o = {}) {
  return { total: 336.4, unitPrice: 150, unitHandlingFee: 0, quantity: 2, productAmount: 300, handlingFee: 0, deliveryFee: 36.4,
    priceVersion: 3, quoteId: "q1", supplierId: S, stationId: "st1", productId: "exchangeEmpty_kg12_5_goGas", currency: "GHS", ...o };
}
const TERMS_V1 = { termsId: "v1", version: 1, rateBps: 1000, termsReference: "Test terms (not commercial)", settlementHoldHours: 24,
  commissionBase: "product_subtotal", handlingFeeCommissionable: false, deliveryFeeCommissionable: false, approvedBy: "test-approver", active: true };
/** The allocation createGasSupplierOrder would have written (from the default snapshot if this one cannot be allocated). */
function allocationFor(s, terms = TERMS_V1) {
  const a = L.computeAllocation(s, terms);
  return a.problem ? L.computeAllocation(snapshot(), terms) : a;
}
async function seedOrder(id = "o1", { order = {}, escrow = {}, snap = {}, allocation } = {}) {
  const s = snapshot(snap);
  if (allocation !== null) {
    await h.seed(`gas_supplier_orders/${id}/finance/allocation`, { orderId: id, supplierId: S, ...allocationFor(s),
      settlement: { status: "not_posted", reconciliation: null }, ...allocation });
  }
  await h.seed(`gas_supplier_orders/${id}`, {
    passengerId: P, supplierId: S, stationId: "st1", productId: s.productId, driverId: D, deliveryMode: "ctsgo_driver",
    status: "delivered", deliveredAt: Timestamp.fromMillis(DELIVERED), priceSnapshot: s,
    payment: { escrowId: `esc-${id}` }, ...order,
  });
  await h.seed(`escrows/esc-${id}`, { userId: P, amount: s.total, status: "HELD",
    referenceType: "gas_supplier_order", referenceId: id, ...escrow });
}
const seedTerms = (o = {}) => h.seedGasCommissionTerms({ termsReference: TERMS_V1.termsReference, approvedBy: TERMS_V1.approvedBy, ...o });
async function entries(orderId) {
  const snap = await h.db().collection(L.LEDGER).where("orderId", "==", orderId).get();
  return Object.fromEntries(snap.docs.map((d) => [d.id, d.data()]));
}
async function rejects(promise, code, reason) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, e.message);
    if (reason) assert.equal(e.details?.reason, reason, JSON.stringify(e.details));
    return true;
  });
}

after(() => h.fft.cleanup());
beforeEach(async () => {
  await h.clearFirestore();
  await h.seed(`admins/${SUPER}`, { active: true, role: "super_admin", email: "s@test" });
  await h.seed(`admins/${SUPER2}`, { active: true, role: "super_admin", email: "s2@test" });
  await h.seed(`admins/${PLAIN}`, { active: true, role: "admin", email: "a@test" });
  await h.seed(`admins/${INACTIVE}`, { active: false, role: "super_admin", email: "i@test" });
});

describe("allocation arithmetic (pure)", () => {
  const amounts = (a) => Object.fromEntries(L.ALLOCATION_AMOUNTS.map((k) => [k, a[k]]));

  test("GSL-A01 commission comes out of the product subtotal; the driver gets the delivery fee; parts add up exactly", () => {
    const a = L.computeAllocation(snapshot(), TERMS_V1);
    assert.deepEqual(amounts(a), {
      productSubtotalPesewas: 30000, handlingFeePesewas: 0, deliveryFeePesewas: 3640, customerTotalPesewas: 33640,
      commissionBasePesewas: 30000, commissionPesewas: 3000, supplierGrossPesewas: 30000, supplierAdjustmentsPesewas: 0,
      supplierNetPesewas: 27000, driverAdjustmentsPesewas: 0, driverNetPesewas: 3640,
    });
    assert.equal(a.commissionRateBps, 1000);
    assert.equal(a.commissionRounding, "floor");
    assert.equal(a.commissionBase, "product_subtotal");
    assert.deepEqual([a.commissionTermsId, a.commissionTermsVersion, a.commissionTermsReference], ["v1", 1, TERMS_V1.termsReference]);
    assert.equal(a.currency, "GHS");
  });

  test("GSL-A02 rounding never over-deducts, and the allocation is exact for every rate and amount", () => {
    assert.equal(L.allocate(snapshot({ unitPrice: 0.99, quantity: 1, productAmount: 0.99, deliveryFee: 12, total: 12.99 }), 1250).commissionPesewas, 12); // 12.375 → 12
    let seed = 7;
    const rnd = (n) => (seed = (seed * 1103515245 + 12345) % 2 ** 31) % n;
    for (let i = 0; i < 2000; i++) {
      const unit = rnd(2_000_000) + 1, qty = rnd(5) + 1, unitH = rnd(3) ? 0 : rnd(5000), delivery = rnd(500_000), rate = rnd(10_001);
      const product = unit * qty, handling = unitH * qty;
      const a = L.allocate({ unitPrice: unit / 100, quantity: qty, productAmount: product / 100, unitHandlingFee: unitH / 100,
        handlingFee: handling / 100, deliveryFee: delivery / 100, total: (product + handling + delivery) / 100 }, rate);
      assert.ok(!a.problem, JSON.stringify({ unit, qty, unitH, delivery, rate, a }));
      assert.equal(a.supplierNetPesewas + a.commissionPesewas + a.driverNetPesewas, product + handling + delivery);
      assert.ok(a.commissionPesewas <= (product * rate) / 10000 && a.commissionPesewas > (product * rate) / 10000 - 1);
      assert.equal(a.driverNetPesewas, delivery, "commission never reduces the driver's fee");
      assert.ok(a.supplierNetPesewas >= handling, "the handling fee is never commissioned");
    }
  });

  test("GSL-A03 zero and full-rate commission", () => {
    const zero = L.allocate(snapshot(), 0);
    assert.equal(zero.commissionPesewas, 0);
    assert.equal(zero.supplierNetPesewas, 30000);
    const full = L.allocate(snapshot({ unitHandlingFee: 2.5, handlingFee: 5, total: 341.4 }), 10000);
    assert.equal(full.commissionPesewas, 30000);
    assert.equal(full.supplierNetPesewas, 500, "only the handling fee is left");
    assert.equal(full.driverNetPesewas, 3640);
  });

  test("GSL-A04 handling and delivery fees are excluded from the commission base", () => {
    const withHandling = L.allocate(snapshot({ unitHandlingFee: 2.5, handlingFee: 5, total: 341.4 }), 1000);
    const without = L.allocate(snapshot(), 1000);
    assert.equal(withHandling.commissionBasePesewas, 30000);
    assert.equal(withHandling.commissionPesewas, without.commissionPesewas);
    assert.equal(withHandling.supplierGrossPesewas, 30500);
    assert.equal(withHandling.supplierNetPesewas, 27500);
    const bigDelivery = L.allocate(snapshot({ deliveryFee: 200, total: 500 }), 1000);
    assert.equal(bigDelivery.commissionPesewas, 3000, "a larger delivery fee changes no commission");
    assert.equal(bigDelivery.driverNetPesewas, 20000);
  });

  test("GSL-A05 snapshots that do not add up, have inconsistent lines, odd pesewas or a bad rate are refused", () => {
    assert.equal(L.allocate(snapshot({ total: 336.41 }), 1000).problem, "snapshot_does_not_add_up");
    assert.equal(L.allocate(snapshot({ productAmount: 300.01, total: 336.41 }), 1000).problem, "snapshot_lines_inconsistent");
    assert.equal(L.allocate(snapshot({ handlingFee: 5, total: 341.4 }), 1000).problem, "snapshot_lines_inconsistent", "handling without a unit fee");
    assert.equal(L.allocate(snapshot({ quantity: 0 }), 1000).problem, "snapshot_lines_inconsistent");
    assert.equal(L.allocate(snapshot({ quantity: 2.5 }), 1000).problem, "snapshot_lines_inconsistent");
    assert.equal(L.allocate(snapshot({ productAmount: 300.005 }), 1000).problem, "snapshot_amounts_invalid");
    assert.equal(L.allocate(snapshot({ deliveryFee: -1 }), 1000).problem, "snapshot_amounts_invalid");
    assert.equal(L.allocate(snapshot({ currency: "USD" }), 1000).problem, "snapshot_amounts_invalid");
    assert.equal(L.allocate(null, 1000).problem, "snapshot_amounts_invalid");
    for (const r of [-1, 10001, 12.5, null, "1000"]) assert.equal(L.allocate(snapshot(), r).problem, "commission_rate_invalid");
  });

  test("GSL-A06 commission terms are unusable until active, approved, referenced, versioned, with a hold period and the agreed base", () => {
    const ok = TERMS_V1;
    assert.equal(L.termsProblem(ok), null);
    assert.equal(L.termsProblem({ ...ok, rateBps: 0 }), null, "zero commission is a valid approved rate");
    assert.equal(L.termsProblem(null), "commission_terms_missing");
    assert.equal(L.termsProblem({ ...ok, active: false }), "commission_terms_inactive");
    assert.equal(L.termsProblem({ ...ok, rateBps: null }), "commission_rate_invalid");
    assert.equal(L.termsProblem({ ...ok, termsReference: " " }), "commission_terms_unreferenced");
    assert.equal(L.termsProblem({ ...ok, approvedBy: "" }), "commission_terms_unapproved");
    assert.equal(L.termsProblem({ ...ok, version: 0 }), "commission_terms_unversioned");
    assert.equal(L.termsProblem({ ...ok, termsId: "v2" }), "commission_terms_unversioned");
    assert.equal(L.termsProblem({ ...ok, settlementHoldHours: undefined }), "settlement_hold_undefined");
    assert.equal(L.termsProblem({ ...ok, commissionBase: "customer_total" }), "commission_base_unsupported");
    assert.equal(L.termsProblem({ ...ok, handlingFeeCommissionable: true }), "commission_base_unsupported");
    assert.equal(L.termsProblem({ ...ok, deliveryFeeCommissionable: undefined }), "commission_base_unsupported");
    for (const t of [null, { ...ok, active: false }, { ...ok, approvedBy: undefined }]) assert.ok(L.computeAllocation(snapshot(), t).problem);
  });

  test("GSL-A07 a stored allocation must match its snapshot at its own rate, field by field", () => {
    const a = L.computeAllocation(snapshot(), TERMS_V1);
    assert.equal(L.allocationProblem(snapshot(), a), null);
    assert.equal(L.allocationProblem(snapshot(), null), "allocation_missing");
    for (const k of L.ALLOCATION_AMOUNTS) {
      assert.equal(L.allocationProblem(snapshot(), { ...a, [k]: a[k] + 1 }), "allocation_does_not_reconcile", k);
    }
    assert.equal(L.allocationProblem(snapshot(), { ...a, commissionRateBps: 2000 }), "allocation_does_not_reconcile");
    assert.equal(L.allocationProblem(snapshot({ total: 340 }), a), "snapshot_does_not_add_up");
    assert.equal(L.allocationProblem(snapshot(), { ...a, commissionRounding: "half_up" }), "allocation_unsupported");
    assert.equal(L.allocationProblem(snapshot(), { ...a, commissionTermsId: "v9" }), "allocation_terms_missing");
  });
});

describe("posting", () => {
  test("GSL-P01 nothing is posted without an allocation or an approved terms version behind it", async () => {
    await seedOrder("o1", { allocation: null });
    await seedTerms();
    await rejects(call(L.adminPostGasSupplierEntitlements, { orderId: "o1" }, SUPER), "failed-precondition", "allocation_missing");
    await seedOrder("o1");
    await h.db().doc("gas_commission_terms/v1").delete();
    await rejects(call(L.adminPostGasSupplierEntitlements, { orderId: "o1" }, SUPER), "failed-precondition", "allocation_terms_not_approved");
    for (const status of ["proposed", "rejected"]) {
      await h.seed("gas_commission_terms/v1", { ...TERMS_V1, status });
      await rejects(call(L.adminPostGasSupplierEntitlements, { orderId: "o1" }, SUPER), "failed-precondition", "allocation_terms_not_approved");
    }
    await h.seed("gas_commission_terms/v1", { ...TERMS_V1, status: "approved", rateBps: 500 });
    await rejects(call(L.adminPostGasSupplierEntitlements, { orderId: "o1" }, SUPER), "failed-precondition", "allocation_terms_mismatch");
    assert.deepEqual(await entries("o1"), {});
  });

  test("GSL-P02 posts three exact entries from the snapshot and touches no balance", async () => {
    await seedTerms();
    await seedOrder();
    await h.seed(`wallets/${P}`, { balance: 10, heldBalance: 336.4 });
    await h.seed(`drivers/${D}`, { walletBalance: 5, totalEarnings: 5 });
    const r = await call(L.adminPostGasSupplierEntitlements, { orderId: "o1" }, SUPER);
    assert.equal(r.posted, true);
    const e = await entries("o1");
    assert.deepEqual(Object.keys(e).sort(), ids("o1").sort());
    assert.equal(e["o1__supplier__entitlement"].amountPesewas, 27000);
    assert.equal(e["o1__supplier__entitlement"].partyId, S);
    assert.equal(e["o1__driver__entitlement"].amountPesewas, 3640);
    assert.equal(e["o1__driver__entitlement"].partyId, D);
    assert.equal(e["o1__platform__commission"].amountPesewas, 3000);
    for (const x of Object.values(e)) {
      assert.equal(x.businessDate, DAY);
      assert.equal(x.basis.snapshotTotalPesewas, 33640);
      assert.equal(x.basis.commissionPesewas, 3000);
      assert.equal(x.basis.handlingPesewas, 0);
      assert.deepEqual(x.basis.commission, { termsId: "v1", termsVersion: 1, rateBps: 1000, termsReference: "Test terms (not commercial)", rounding: "floor", base: "product_subtotal" });
      assert.equal(x.postedBy, SUPER);
    }
    assert.deepEqual(await h.read(`wallets/${P}`), { balance: 10, heldBalance: 336.4 });
    assert.deepEqual(await h.read(`drivers/${D}`), { walletBalance: 5, totalEarnings: 5 });
    assert.equal((await h.db().collection("ledger").get()).size, 0, "the shared ledger is not written");
    assert.equal((await h.read(`escrows/esc-o1`)).status, "HELD", "the escrow is not moved");
  });

  test("GSL-P03 orders that are not delivered or whose payment does not match are refused", async () => {
    await seedTerms();
    const cases = [
      [{ order: { status: "awaiting_payment" } }, "order_not_delivered"],
      [{ order: { driverId: null } }, "order_driver_missing"],
      [{ order: { payment: null } }, "payment_missing"],
      [{ order: { passengerId: null } }, "order_passenger_missing"],
      [{ escrow: { userId: "someone-else" } }, "escrow_owner_mismatch"],
      [{ escrow: { referenceId: "other-order" } }, "escrow_reference_mismatch"],
      [{ escrow: { referenceType: "gas_order" } }, "escrow_reference_mismatch"],
      [{ escrow: { amount: 336.39 } }, "escrow_amount_mismatch"],
      [{ escrow: { amount: 1000 } }, "escrow_amount_mismatch"],
      [{ escrow: { status: "REFUNDED" } }, "escrow_not_active"],
      [{ escrow: { status: "RELEASED" } }, "escrow_not_active"],
      [{ snap: { total: 400 }, escrow: { amount: 400 } }, "snapshot_does_not_add_up"],
      [{ allocation: { supplierNetPesewas: 28000, commissionPesewas: 2000 } }, "allocation_does_not_reconcile"],
      [{ allocation: { supplierId: "sup2" } }, "allocation_mismatch"],
    ];
    for (const [v, reason] of cases) {
      await seedOrder("o1", v);
      await rejects(call(L.adminPostGasSupplierEntitlements, { orderId: "o1" }, SUPER), "failed-precondition", reason);
    }
    assert.deepEqual(await entries("o1"), {});
  });

  test("GSL-P04 client-supplied amounts are refused, not used", async () => {
    await seedTerms(); await seedOrder();
    for (const extra of [{ amountPesewas: 1 }, { commission: 0 }, { supplierAmount: 999 }, { total: 1 }]) {
      await rejects(call(L.adminPostGasSupplierEntitlements, { orderId: "o1", ...extra }, SUPER), "invalid-argument", "unexpected_fields");
    }
    assert.deepEqual(await entries("o1"), {});
  });

  test("GSL-P05 retries and concurrent duplicate completions post exactly once", async () => {
    await seedTerms(); await seedOrder();
    const results = await Promise.allSettled(Array.from({ length: 6 }, () => L.postOrderEntitlements("o1")));
    const ok = results.filter((r) => r.status === "fulfilled").map((r) => r.value);
    assert.ok(ok.length >= 1);
    assert.equal(ok.filter((r) => r.posted).length, 1);
    assert.deepEqual((await L.postOrderEntitlements("o1")), { alreadyPosted: true });
    assert.equal(Object.keys(await entries("o1")).length, 3);
  });

  test("GSL-P06 a later commission or price change never alters posted entries", async () => {
    await seedTerms(); await seedOrder();
    await L.postOrderEntitlements("o1");
    const before = await entries("o1");
    await seedTerms({ rateBps: 2500, version: 2 });
    await h.db().doc("gas_supplier_orders/o1").update({ "priceSnapshot.productAmount": 999 });
    assert.deepEqual(await L.postOrderEntitlements("o1"), { alreadyPosted: true });
    assert.deepEqual(await entries("o1"), before);
  });
});

describe("posting from the locked allocation", () => {
  test("GSL-P07 a handling fee goes to the supplier, uncommissioned; the driver gets the delivery fee", async () => {
    await seedTerms();
    await seedOrder("o1", { snap: { unitHandlingFee: 2.5, handlingFee: 5, total: 341.4 }, escrow: { amount: 341.4 } });
    const r = await L.postOrderEntitlements("o1");
    assert.equal(r.posted, true);
    const e = await entries("o1");
    assert.equal(e["o1__supplier__entitlement"].amountPesewas, 27500, "300 + 5 − 30");
    assert.equal(e["o1__platform__commission"].amountPesewas, 3000, "10% of 300 only");
    assert.equal(e["o1__driver__entitlement"].amountPesewas, 3640);
    assert.equal(Object.values(e).reduce((t, x) => t + x.amountPesewas, 0), 34140, "= customer total");
    const alloc = await h.read("gas_supplier_orders/o1/finance/allocation");
    assert.equal(alloc.settlement.status, "accrued");
    assert.equal(alloc.settlement.reconciliation, "balanced");
  });

  test("GSL-P08 version-changed terms: an order posts at the terms it was created under", async () => {
    await seedTerms(); // v1, 10%
    await seedOrder("o1");
    await seedTerms({ version: 2, termsId: "v2", rateBps: 2500, termsReference: "Test terms v2 (not commercial)" });
    await h.db().doc("gas_commission_terms/v1").update({ status: "superseded" });
    await L.postOrderEntitlements("o1");
    const e = await entries("o1");
    assert.equal(e["o1__platform__commission"].amountPesewas, 3000, "10%, not 25%");
    assert.equal(e["o1__platform__commission"].basis.commission.termsVersion, 1);
  });

  test("GSL-P09 a zero-commission order posts a zero commission entry and the full product to the supplier", async () => {
    await seedTerms({ rateBps: 0 });
    await seedOrder("o1", { allocation: allocationFor(snapshot(), { ...TERMS_V1, rateBps: 0 }) });
    await L.postOrderEntitlements("o1");
    const e = await entries("o1");
    assert.equal(e["o1__platform__commission"].amountPesewas, 0);
    assert.equal(e["o1__supplier__entitlement"].amountPesewas, 30000);
  });

  test("GSL-P10 a reversal marks the allocation reversed", async () => {
    await seedTerms(); await seedOrder();
    await L.postOrderEntitlements("o1");
    await L.reverseOrderEntitlements("o1", { reason: "Admin correction", actor: { uid: SUPER } });
    const alloc = await h.read("gas_supplier_orders/o1/finance/allocation");
    assert.equal(alloc.settlement.status, "reversed");
    assert.equal(alloc.settlement.reversalReason, "Admin correction");
  });
});

describe("commission terms", () => {
  const propose = (data, uid = SUPER) => call(L.adminProposeGasCommissionTerms, data, uid);
  const decide = (data, uid = SUPER2) => call(L.adminDecideGasCommissionTerms, data, uid);
  const proposal = { rateBps: 1000, termsReference: "Test terms (not commercial)", settlementHoldHours: 24 };

  test("GSL-T01 proposed by one super admin, approved by another, then current and usable", async () => {
    assert.deepEqual(await propose(proposal), { termsId: "v1", version: 1, status: "proposed" });
    assert.equal(await h.read(L.TERMS_DOC), null, "a proposal changes nothing");
    const v = await h.read("gas_commission_terms/v1");
    assert.equal(v.status, "proposed");
    assert.equal(v.proposedBy, SUPER);
    assert.equal(v.commissionBase, "product_subtotal");
    assert.equal(v.handlingFeeCommissionable, false);
    await rejects(decide({ termsId: "v1", decision: "approve" }, SUPER), "permission-denied", "approver_is_proposer");
    assert.deepEqual(await decide({ termsId: "v1", decision: "approve" }), { termsId: "v1", status: "approved" });
    const cur = await h.read(L.TERMS_DOC);
    assert.equal(L.termsProblem(cur), null);
    assert.equal(cur.approvedBy, SUPER2);
    assert.equal(cur.proposedBy, SUPER);
    assert.equal(cur.rateBps, 1000);
    assert.deepEqual(await decide({ termsId: "v1", decision: "approve" }), { termsId: "v1", status: "approved", alreadyDecided: true });
  });

  test("GSL-T02 a new version supersedes the old; an older proposal cannot replace newer current terms", async () => {
    await propose(proposal); await propose({ ...proposal, rateBps: 800 });
    await decide({ termsId: "v2", decision: "approve" });
    await rejects(decide({ termsId: "v1", decision: "approve" }), "failed-precondition", "newer_terms_current");
    assert.equal((await h.read(L.TERMS_DOC)).version, 2);
    await propose({ ...proposal, rateBps: 900 });
    await decide({ termsId: "v3", decision: "approve" });
    assert.equal((await h.read("gas_commission_terms/v2")).status, "superseded");
    assert.equal((await h.read("gas_commission_terms/v2")).supersededBy, "v3");
    assert.equal((await h.read(L.TERMS_DOC)).rateBps, 900);
  });

  test("GSL-T03 concurrent proposals get distinct versions", async () => {
    const r = await Promise.all(Array.from({ length: 4 }, (_, i) => propose({ ...proposal, rateBps: 100 * (i + 1) })));
    assert.deepEqual(r.map((x) => x.version).sort(), [1, 2, 3, 4]);
  });

  test("GSL-T04 rejection needs a reason; a rejected version cannot be approved", async () => {
    await propose(proposal);
    await rejects(decide({ termsId: "v1", decision: "reject" }), "invalid-argument", "reason_required");
    await decide({ termsId: "v1", decision: "reject", reason: "Rate not agreed with supplier" });
    await rejects(decide({ termsId: "v1", decision: "approve" }), "failed-precondition", "terms_not_proposed");
    assert.equal(await h.read(L.TERMS_DOC), null);
    await rejects(decide({ termsId: "v9", decision: "approve" }), "not-found", "terms_not_found");
  });

  test("GSL-T05 unauthorized or malformed commission changes are refused and change nothing", async () => {
    await propose(proposal);
    for (const uid of [null, P, D, PLAIN, INACTIVE]) {
      const code = uid ? "permission-denied" : "unauthenticated";
      await rejects(propose({ ...proposal, rateBps: 5000 }, uid), code);
      await rejects(decide({ termsId: "v1", decision: "approve" }, uid), code);
    }
    for (const bad of [{ rateBps: 10001 }, { rateBps: -1 }, { rateBps: 12.5 }, { rateBps: "1000" }, { termsReference: "" },
      { termsReference: undefined }, { settlementHoldHours: -1 }, { settlementHoldHours: undefined }]) {
      const data = { ...proposal, ...bad };
      for (const k of Object.keys(data)) if (data[k] === undefined) delete data[k];
      await rejects(propose(data), "invalid-argument");
    }
    for (const extra of [{ approvedBy: SUPER }, { active: true }, { commissionBase: "customer_total" }, { version: 7 }]) {
      await rejects(propose({ ...proposal, ...extra }), "invalid-argument", "unexpected_fields");
    }
    for (const bad of [{ termsId: "current", decision: "approve" }, { termsId: "v1", decision: "activate" }, { termsId: "../x", decision: "approve" }]) {
      await rejects(decide(bad), "invalid-argument");
    }
    assert.equal((await h.db().collection(L.TERMS).get()).size, 1, "only the one proposal");
    assert.equal(await h.read(L.TERMS_DOC), null);
  });
});

describe("authorization", () => {
  test("GSL-Z01 only an active super admin may post, reverse or prepare", async () => {
    await seedTerms(); await seedOrder();
    for (const uid of [null, P, D, PLAIN, INACTIVE]) {
      const code = uid ? "permission-denied" : "unauthenticated";
      await rejects(call(L.adminPostGasSupplierEntitlements, { orderId: "o1" }, uid), code);
      await rejects(call(L.adminReverseGasSupplierEntitlements, { orderId: "o1", reason: "test reversal" }, uid), code);
      await rejects(call(L.adminPrepareGasSettlementStatements, { businessDate: DAY }, uid), code);
    }
    assert.deepEqual(await entries("o1"), {});
    assert.equal((await h.db().collection(L.STATEMENTS).get()).size, 0);
  });
});

describe("reversals", () => {
  test("GSL-R01 a refund appends negating entries and leaves the originals untouched", async () => {
    await seedTerms(); await seedOrder();
    await L.postOrderEntitlements("o1");
    const originals = await entries("o1");
    await rejects(L.reverseOrderEntitlements("o1", { reason: "refunded" }), "failed-precondition", "payment_not_refunded");
    await h.db().doc("escrows/esc-o1").update({ status: "REFUNDED" });
    assert.deepEqual(await L.reverseOrderEntitlements("o1", { reason: "Order cancelled and refunded" }), { reversed: true });
    const all = await entries("o1");
    for (const id of ids("o1")) assert.deepEqual(all[id], originals[id], "original unchanged");
    assert.equal(all["o1__supplier__reversal"].amountPesewas, -27000);
    assert.equal(all["o1__driver__reversal"].amountPesewas, -3640);
    assert.equal(all["o1__platform__reversal"].amountPesewas, -3000);
    assert.equal(all["o1__supplier__reversal"].reversesEntryId, "o1__supplier__entitlement");
    assert.equal(Object.values(all).reduce((s, e) => s + e.amountPesewas, 0), 0, "nets to zero");
  });

  test("GSL-R02 reversals are idempotent, need a reason, and need something posted", async () => {
    await seedTerms(); await seedOrder();
    await rejects(L.reverseOrderEntitlements("o1", { reason: "x", actor: { uid: SUPER } }), "invalid-argument", "reason_required");
    await rejects(call(L.adminReverseGasSupplierEntitlements, { orderId: "o1", reason: "Admin correction" }, SUPER), "failed-precondition", "nothing_posted");
    await L.postOrderEntitlements("o1");
    const runs = await Promise.allSettled(Array.from({ length: 4 }, () =>
      call(L.adminReverseGasSupplierEntitlements, { orderId: "o1", reason: "Admin correction" }, SUPER)));
    assert.equal(runs.filter((r) => r.status === "fulfilled" && r.value.reversed).length, 1);
    assert.deepEqual(await call(L.adminReverseGasSupplierEntitlements, { orderId: "o1", reason: "Again" }, SUPER), { alreadyReversed: true });
    assert.equal(Object.keys(await entries("o1")).length, 6);
  });
});

describe("statuses", () => {
  test("GSL-S01 pending → eligible → prepared → payout in progress → paid, and reversed", () => {
    const e = { kind: "entitlement" };
    const base = { reversed: false, claim: null, escrow: { status: "CAPTURED" }, deliveredAtMs: DELIVERED, holdHours: 24, now: DELIVERED + 25 * 3600e3 };
    assert.equal(L.entryStatus(e, { ...base, escrow: { status: "HELD" } }), "pending", "payment not captured");
    assert.equal(L.entryStatus(e, { ...base, now: DELIVERED + 23 * 3600e3 }), "pending", "hold period open");
    assert.equal(L.entryStatus(e, { ...base, holdHours: undefined }), "pending", "no hold period: fail closed");
    assert.equal(L.entryStatus(e, base), "eligible");
    assert.equal(L.entryStatus(e, { ...base, reversed: true }), "reversed");
    assert.equal(L.entryStatus(e, { ...base, claim: {}, statement: { payoutStatus: "not_started" } }), "settlement_prepared");
    assert.equal(L.entryStatus(e, { ...base, claim: {}, statement: { payoutStatus: "payout_in_progress" } }), "payout_in_progress");
    assert.equal(L.entryStatus(e, { ...base, claim: {}, statement: { payoutStatus: "paid" } }), "paid");
    assert.equal(L.statementStatus(100), "prepared");
    assert.equal(L.statementStatus(0), "prepared_no_payout");
    assert.equal(L.statementStatus(-5), "prepared_no_payout");
  });
});

describe("daily statements", () => {
  async function postCaptured(id, o = {}) {
    await seedOrder(id, o);
    await L.postOrderEntitlements(id);
    await h.db().doc(`escrows/esc-${id}`).update({ status: "CAPTURED" });
  }

  test("GSL-D01 only eligible entries are included: captured, past the hold period, closed day", async () => {
    await seedTerms();
    await postCaptured("o1");
    await seedOrder("o2"); await L.postOrderEntitlements("o2"); // escrow still HELD: pending
    await rejects(L.prepareStatements(DAY, { now: DELIVERED + 3600e3 }), "failed-precondition", "day_not_closed");
    const early = await L.prepareStatements(DAY, { now: Date.parse("2026-10-21T01:00:00Z") }); // inside 24 h hold
    assert.equal(early.statements.length, 0);
    const r = await L.prepareStatements(DAY, { now: NEXT_DAY_NOON });
    const st = await h.read(`${L.STATEMENTS}/${DAY}__supplier__${S}`);
    assert.deepEqual(st.lines.map((l) => l.entryId), ["o1__supplier__entitlement"]);
    assert.equal(st.netPesewas, 27000);
    assert.equal(st.status, "prepared");
    assert.equal(st.payoutStatus, "not_started");
    assert.equal(st.payoutMethod, null);
    assert.equal((await h.read(`${L.STATEMENTS}/${DAY}__driver__${D}`)).netPesewas, 3640);
    assert.equal(await h.read(`${L.STATEMENTS}/${DAY}__platform__ctsgo`), null, "commission is not paid out");
    assert.equal(r.exceptions.length, 0);
    assert.equal(await h.read(`${L.CLAIMS}/o2__supplier__entitlement`), null, "pending entry left for later");
  });

  test("GSL-D02 reruns and concurrent runs never include an entry twice", async () => {
    await seedTerms();
    await postCaptured("o1"); await postCaptured("o2");
    await Promise.allSettled(Array.from({ length: 4 }, () => L.prepareStatements(DAY, { now: NEXT_DAY_NOON })));
    await L.prepareStatements(DAY, { now: NEXT_DAY_NOON });
    const statements = (await h.db().collection(L.STATEMENTS).get()).docs.map((d) => d.data());
    const lines = statements.flatMap((s) => s.lines.map((l) => l.entryId));
    assert.equal(new Set(lines).size, lines.length, "no entry in two statements");
    assert.equal(lines.length, 4, "two orders × supplier + driver");
    const claims = (await h.db().collection(L.CLAIMS).get()).docs.map((d) => d.data());
    assert.equal(claims.length, 4);
    for (const c of claims) assert.ok(statements.some((s) => s.statementId === c.statementId && s.lines.some((l) => l.entryId === c.entryId)));
  });

  test("GSL-D03 a refund after settlement becomes an outstanding debt and is never netted on a later statement", async () => {
    // F3 (spec §3.6) replaces the earlier automatic netting: intentional, approved change.
    await seedTerms();
    await postCaptured("o1");
    await L.prepareStatements(DAY, { now: NEXT_DAY_NOON });
    await h.db().doc("escrows/esc-o1").update({ status: "REFUNDED" });
    await L.reverseOrderEntitlements("o1", { reason: "Refunded after dispute" });
    const before = await h.read(`${L.STATEMENTS}/${DAY}__supplier__${S}`);
    const debt = await h.read(`${L.DEBTS}/o1__supplier__reversal`);
    assert.equal(debt.status, "outstanding");
    assert.equal(debt.amountPesewas, 27000);
    assert.equal(debt.statementId, `${DAY}__supplier__${S}`);
    // The reversal is dated when it is posted (today, in real time), so prepare that day once it is closed.
    const revDay = (await entries("o1"))["o1__supplier__reversal"].businessDate;
    const later = Date.parse(`${revDay}T00:00:00Z`) + 36 * 3600e3;
    await L.prepareStatements(revDay, { now: later });
    assert.equal(await h.read(`${L.STATEMENTS}/${revDay}__supplier__${S}`), null, "the reversal is not put on a later statement");
    assert.equal((await h.read(`${L.DEBTS}/o1__supplier__reversal`)).status, "outstanding");
    assert.deepEqual(await h.read(`${L.STATEMENTS}/${DAY}__supplier__${S}`), before, "the earlier statement is unchanged");
  });

  test("GSL-D04 an entitlement reversed before settlement is claimed with its reversal and nets to zero", async () => {
    await seedTerms();
    await postCaptured("o1");
    await L.reverseOrderEntitlements("o1", { reason: "Admin correction", actor: { uid: SUPER } });
    const revDay = (await entries("o1"))["o1__supplier__reversal"].businessDate;
    await L.prepareStatements(revDay, { now: Date.parse(`${revDay}T00:00:00Z`) + 36 * 3600e3 });
    const st = await h.read(`${L.STATEMENTS}/${revDay}__supplier__${S}`);
    assert.deepEqual(st.lines.map((l) => l.entryId).sort(), ["o1__supplier__entitlement", "o1__supplier__reversal"]);
    assert.equal(st.netPesewas, 0);
    assert.equal(st.status, "prepared_no_payout");
  });

  test("GSL-D05 entries that do not reconcile are left out and reported", async () => {
    await seedTerms();
    await postCaptured("o1"); await postCaptured("o2");
    await h.db().doc("escrows/esc-o2").update({ amount: 300 }); // payment no longer equals the snapshot
    const r = await L.prepareStatements(DAY, { now: NEXT_DAY_NOON });
    assert.deepEqual(r.exceptions, [{ orderId: "o2", reason: "does_not_reconcile", detail: "payment_differs_from_total" }]);
    const alloc = await h.read("gas_supplier_orders/o2/finance/allocation");
    assert.equal(alloc.settlement.reconciliation, "does_not_reconcile");
    assert.equal(alloc.settlement.reconciliationReason, "payment_differs_from_total");
    const lines = (await h.db().collection(L.STATEMENTS).get()).docs.flatMap((d) => d.data().lines.map((l) => l.orderId));
    assert.ok(!lines.includes("o2"));
    const alerts = (await h.db().collection("admin_alerts").where("type", "==", "gas_settlement_exceptions").get()).docs;
    assert.equal(alerts.length, 1);
  });

  test("GSL-D07 an allocation changed after posting is caught by reconciliation", async () => {
    await seedTerms();
    await postCaptured("o1");
    await h.db().doc("gas_supplier_orders/o1/finance/allocation").update({ supplierNetPesewas: 27100, commissionPesewas: 2900 });
    const r = await L.prepareStatements(DAY, { now: NEXT_DAY_NOON });
    assert.deepEqual(r.exceptions, [{ orderId: "o1", reason: "does_not_reconcile", detail: "allocation_does_not_reconcile" }]);
    assert.equal(r.statements.length, 0);
  });

  test("GSL-D08 a supplier statement nets entitlements and reversals and equals its lines", async () => {
    await seedTerms();
    await postCaptured("o1");
    await postCaptured("o2", { snap: { unitHandlingFee: 2.5, handlingFee: 5, total: 341.4 }, escrow: { amount: 341.4 } });
    await L.prepareStatements(DAY, { now: NEXT_DAY_NOON });
    const st = await h.read(`${L.STATEMENTS}/${DAY}__supplier__${S}`);
    assert.equal(st.netPesewas, 27000 + 27500);
    assert.equal(st.netPesewas, st.lines.reduce((t, l) => t + l.amountPesewas, 0));
    assert.equal((await h.read(`${L.STATEMENTS}/${DAY}__driver__${D}`)).netPesewas, 3640 * 2);
  });

  test("GSL-D06 a missing hold period keeps everything pending", async () => {
    await seedTerms();
    await postCaptured("o1");
    await seedTerms({ settlementHoldHours: undefined });
    const r = await L.prepareStatements(DAY, { now: NEXT_DAY_NOON });
    assert.equal(r.statements.length, 0);
  });
});

// ── Linked riders (deliveryMode "linked_rider"): the fee is the rider's own entitlement ──

const LINKED = Object.freeze({ deliveryMode: "linked_rider", linkedSupplierId: S, acceptedFeePesewas: 3640 });

describe("linked riders", () => {
  test("GSL-LR01 a linked rider's fee posts to the rider; the supplier gets product + handling − commission only", async () => {
    await seedTerms();
    await seedOrder("o1", { order: LINKED });
    assert.equal((await L.postOrderEntitlements("o1")).posted, true);
    const alloc = await h.read("gas_supplier_orders/o1/finance/allocation");
    const e = await entries("o1");
    assert.deepEqual(Object.keys(e).sort(), ids("o1").sort(), "exactly three entries");
    assert.equal(e["o1__supplier__entitlement"].amountPesewas, alloc.supplierNetPesewas);
    assert.equal(e["o1__supplier__entitlement"].partyId, S);
    assert.equal(e["o1__driver__entitlement"].party, "driver");
    assert.equal(e["o1__driver__entitlement"].partyId, D);
    assert.equal(e["o1__driver__entitlement"].amountPesewas, alloc.deliveryFeePesewas);
    assert.equal(e["o1__platform__commission"].amountPesewas, alloc.commissionPesewas);
    assert.equal(e["o1__supplier__delivery_fee"], undefined, "the supplier never gets the rider's fee");
    assert.equal(Object.values(e).reduce((t, x) => t + x.amountPesewas, 0), alloc.customerTotalPesewas);
    for (const x of Object.values(e)) assert.equal(x.basis.deliveryMode, "linked_rider");
    assert.equal(e["o1__driver__entitlement"].basis.linkedSupplierId, S);
    assert.equal(e["o1__supplier__entitlement"].basis.linkedSupplierId, undefined);
    assert.equal(e["o1__platform__commission"].basis.linkedSupplierId, undefined);
  });

  test("GSL-LR02 the same snapshot gives the same commission and supplier entitlement in every delivery mode", async () => {
    await seedTerms();
    const modes = { o1: { deliveryMode: "ctsgo_driver" }, o2: LINKED, o3: { deliveryMode: "supplier_rider", driverId: null } };
    for (const [id, order] of Object.entries(modes)) {
      await seedOrder(id, { order });
      await L.postOrderEntitlements(id);
    }
    const all = Object.fromEntries(await Promise.all(Object.keys(modes).map(async (id) => [id, await entries(id)])));
    for (const id of Object.keys(modes)) {
      assert.equal(all[id][`${id}__supplier__entitlement`].amountPesewas, 27000, id);
      assert.equal(all[id][`${id}__platform__commission`].amountPesewas, 3000, id);
      assert.equal(Object.keys(all[id]).length, 3, id);
      for (const x of Object.values(all[id])) assert.equal(x.basis.deliveryMode, modes[id].deliveryMode, id);
    }
    for (const id of ["o1", "o2"]) {
      assert.deepEqual(["party", "partyId", "amountPesewas"].map((k) => all[id][`${id}__driver__entitlement`][k]), ["driver", D, 3640]);
    }
    assert.deepEqual(["party", "partyId", "amountPesewas"].map((k) => all.o3.o3__supplier__delivery_fee[k]), ["supplier", S, 3640],
      "offline supplier rider: unchanged, the supplier gets the delivery fee");
    assert.equal(all.o3.o3__driver__entitlement, undefined);
    assert.equal(all.o1.o1__driver__entitlement.basis.linkedSupplierId, undefined);
  });

  test("GSL-LR05 unknown modes and inconsistent linked-rider orders are refused and post nothing", async () => {
    await seedTerms();
    const cases = [
      [{ deliveryMode: "other" }, "order_delivery_mode_unknown"],
      [{ deliveryMode: null }, "order_delivery_mode_unknown"],
      [{ deliveryMode: h.admin.firestore.FieldValue.delete() }, "order_delivery_mode_unknown"],
      [{ ...LINKED, driverId: null }, "order_driver_missing"],
      [{ ...LINKED, linkedSupplierId: "sup2" }, "order_linked_supplier_mismatch"],
      [{ ...LINKED, linkedSupplierId: null }, "order_linked_supplier_mismatch"],
      [{ ...LINKED, acceptedFeePesewas: 3639 }, "rider_fee_mismatch"],
      [{ ...LINKED, acceptedFeePesewas: "3640" }, "rider_fee_mismatch"],
      [{ ...LINKED, acceptedFeePesewas: null }, "rider_fee_mismatch"],
      [{ deliveryMode: "supplier_rider" }, "order_driver_unexpected"],
      [{ deliveryMode: "ctsgo_driver", driverId: null }, "order_driver_missing"],
    ];
    for (const [order, reason] of cases) {
      await seedOrder("o1");
      await h.db().doc("gas_supplier_orders/o1").update(order);
      await rejects(L.postOrderEntitlements("o1"), "failed-precondition", reason);
    }
    assert.deepEqual(await entries("o1"), {});
  });

  test("GSL-LR03 concurrent and repeated postings of a linked-rider order post exactly once", async () => {
    await seedTerms();
    await seedOrder("o1", { order: LINKED });
    const results = await Promise.allSettled(Array.from({ length: 5 }, () => L.postOrderEntitlements("o1")));
    const ok = results.filter((r) => r.status === "fulfilled").map((r) => r.value);
    assert.equal(ok.filter((r) => r.posted).length, 1);
    for (let i = 0; i < 3; i++) assert.deepEqual(await L.postOrderEntitlements("o1"), { alreadyPosted: true });
    assert.deepEqual(Object.keys(await entries("o1")).sort(), ids("o1").sort());
  });
});

// ── Settled-entry reversals (F3): outstanding debts with an explicit, audited resolution ──

describe("settlement debts", () => {
  const SUP_ST = `${DAY}__supplier__${S}`, DRV_ST = `${DAY}__driver__${D}`;
  const SUP_DEBT = "o1__supplier__reversal", DRV_DEBT = "o1__driver__reversal";
  const today = () => L.businessDate(Date.now());
  const closed = (day) => Date.parse(`${day}T00:00:00Z`) + 36 * 3600e3;
  const resolveDebt = (data, uid = SUPER) => call(L.adminResolveGasSettlementDebt, data, uid);
  const reverse = (id = "o1", uid = SUPER) => call(L.adminReverseGasSupplierEntitlements, { orderId: id, reason: "Admin correction" }, uid);
  const audits = async () => (await h.db().collection("audit_log").where("action", "==", "gas_settlement_debt_resolved").get()).docs.map((d) => d.data());
  async function postCaptured(id, o = {}) {
    await seedOrder(id, o);
    await L.postOrderEntitlements(id);
    await h.db().doc(`escrows/esc-${id}`).update({ status: "CAPTURED" });
  }
  /** o1 (and any others) posted, captured and claimed by the DAY statements. */
  async function settled(...more) {
    await seedTerms();
    await h.seed(`drivers/${D}`, { walletBalance: 5, commissionOwed: 2 });
    for (const id of ["o1", ...more]) await postCaptured(id);
    await L.prepareStatements(DAY, { now: NEXT_DAY_NOON });
  }
  /** The supplier debt before payout, the driver debt after its wallet credit. */
  async function bothStages() {
    await settled();
    await h.db().doc(`${L.STATEMENTS}/${DRV_ST}`).update({ payoutStatus: "paid", payoutMethod: "driver_wallet" });
    await reverse();
  }

  test("GSL-OD01 a reversal before any statement creates no debt; both are claimed together and net to zero", async () => {
    await seedTerms();
    await postCaptured("o1");
    await reverse();
    assert.equal((await h.db().collection(L.DEBTS).get()).size, 0);
    assert.equal(await h.read(`${L.CLAIMS}/${SUP_DEBT}`), null);
    await L.prepareStatements(today(), { now: closed(today()) });
    for (const [party, id] of [["supplier", S], ["driver", D]]) {
      const st = await h.read(`${L.STATEMENTS}/${today()}__${party}__${id}`);
      assert.equal(st.lines.length, 2, party);
      assert.equal(st.netPesewas, 0, party);
      assert.equal(st.status, "prepared_no_payout", party);
    }
    assert.equal((await h.db().collection(L.DEBTS).get()).size, 0);
  });

  test("GSL-OD02 a reversal after the line is claimed creates one outstanding debt, a held claim and an alert, exactly once", async () => {
    await settled();
    const stBefore = await h.read(`${L.STATEMENTS}/${DRV_ST}`);
    const runs = await Promise.allSettled(Array.from({ length: 4 }, () => reverse()));
    assert.equal(runs.filter((r) => r.status === "fulfilled" && r.value.reversed).length, 1);
    assert.deepEqual(await reverse(), { alreadyReversed: true });
    const debt = await h.read(`${L.DEBTS}/${DRV_DEBT}`);
    assert.equal(debt.debtId, DRV_DEBT);
    assert.equal(debt.reversalEntryId, DRV_DEBT);
    assert.equal(debt.originalEntryId, "o1__driver__entitlement");
    assert.deepEqual([debt.party, debt.partyId, debt.orderId], ["driver", D, "o1"]);
    assert.equal(debt.amountPesewas, 3640);
    assert.equal(debt.stage, "before_payout");
    assert.equal(debt.status, "outstanding");
    assert.equal(debt.statementId, DRV_ST);
    assert.equal(debt.version, 1);
    const claim = await h.read(`${L.CLAIMS}/${DRV_DEBT}`);
    assert.equal(claim.debtId, DRV_DEBT);
    assert.equal(claim.entryId, DRV_DEBT);
    assert.equal("statementId" in claim, false, "automatic statements skip it");
    const alert = await h.read(`admin_alerts/gas_settlement_debt_${DRV_DEBT}`);
    assert.equal(alert.severity, "high");
    assert.equal(alert.resolved, false);
    assert.equal(alert.read, false, "the admin bell lists only unread alerts");
    assert.equal(typeof alert.message, "string");
    assert.equal((await h.read(`${L.DEBTS}/${SUP_DEBT}`)).amountPesewas, 27000);
    assert.equal((await h.db().collection(L.DEBTS).get()).size, 2, "supplier and driver; commission is never claimed");
    assert.deepEqual(await h.read(`${L.STATEMENTS}/${DRV_ST}`), stBefore, "the claiming statement is not edited");
    assert.deepEqual(await h.read(`drivers/${D}`), { walletBalance: 5, commissionOwed: 2 }, "no wallet or commissionOwed change");
  });

  test("GSL-OD03 a reversal after the wallet credit is an after-payout debt; a later earning is paid in full", async () => {
    await bothStages();
    assert.equal((await h.read(`${L.DEBTS}/${DRV_DEBT}`)).stage, "after_payout");
    assert.equal((await h.read(`${L.DEBTS}/${SUP_DEBT}`)).stage, "before_payout");
    const day = today();
    await postCaptured("o2", { order: { deliveredAt: Timestamp.fromMillis(Date.parse(`${day}T10:00:00Z`)) } });
    await L.prepareStatements(day, { now: closed(day) });
    const drv = await h.read(`${L.STATEMENTS}/${day}__driver__${D}`);
    assert.deepEqual(drv.lines.map((l) => l.entryId), ["o2__driver__entitlement"]);
    assert.equal(drv.netPesewas, 3640, "only the new fee: nothing deducted");
    const sup = await h.read(`${L.STATEMENTS}/${day}__supplier__${S}`);
    assert.deepEqual(sup.lines.map((l) => l.entryId), ["o2__supplier__entitlement"]);
    assert.equal(sup.netPesewas, 27000);
    assert.equal((await h.read(`${L.DEBTS}/${DRV_DEBT}`)).status, "outstanding");
    assert.equal((await h.read(`${L.DEBTS}/${SUP_DEBT}`)).status, "outstanding");
  });

  test("GSL-OD04 a statement never nets below zero, and a reversal of a settled entry is never netted", async () => {
    await settled();
    const day = today();
    const orig = await h.read(`${L.LEDGER}/o1__supplier__entitlement`);
    // Forged: a reversal of a claimed original without its debt (what the pre-F3 code could leave behind).
    await h.seed(`${L.LEDGER}/${SUP_DEBT}`, { ...orig, entryId: SUP_DEBT, kind: "reversal", reversesEntryId: orig.entryId,
      amountPesewas: -27000, businessDate: day, postedAt: new Date(), reason: "forged" });
    // Forged: a reversal larger than its unclaimed original.
    await postCaptured("o2", { order: { deliveredAt: Timestamp.fromMillis(Date.parse(`${day}T10:00:00Z`)) } });
    const o2d = await h.read(`${L.LEDGER}/o2__driver__entitlement`);
    await h.seed(`${L.LEDGER}/o2__driver__reversal`, { ...o2d, entryId: "o2__driver__reversal", kind: "reversal",
      reversesEntryId: o2d.entryId, amountPesewas: -10000, reason: "forged" });
    const r = await L.prepareStatements(day, { now: closed(day) });
    assert.equal(await h.read(`${L.STATEMENTS}/${day}__driver__${D}`), null, "no negative statement");
    assert.equal(r.statements.find((x) => x.key === `driver__${D}`).skipped, "negative_net");
    const sup = await h.read(`${L.STATEMENTS}/${day}__supplier__${S}`);
    assert.deepEqual(sup.lines.map((l) => l.entryId), ["o2__supplier__entitlement"], "the settled reversal is left out");
    assert.equal(sup.netPesewas, 27000);
    assert.equal(await h.read(`${L.CLAIMS}/${SUP_DEBT}`), null, "left unclaimed, not lost");
    assert.equal(await h.read(`${L.CLAIMS}/o2__driver__entitlement`), null);
    const alerts = (await h.db().collection("admin_alerts").where("type", "==", "gas_settlement_negative_statement").get()).docs.map((d) => d.data());
    assert.deepEqual(alerts.map((a) => a.details.party).sort(), ["driver", "supplier"]);
    assert.equal(alerts.find((a) => a.details.party === "driver").details.reason, "negative_net");
    assert.deepEqual(alerts.find((a) => a.details.party === "supplier").details.settledReversalIds, [SUP_DEBT]);
    await L.prepareStatements(day, { now: closed(day) }); // a rerun raises no second alert
    assert.equal((await h.db().collection("admin_alerts").where("type", "==", "gas_settlement_negative_statement").get()).size, 2);
  });

  test("GSL-OD05 only the allowed resolution for each stage, with a reason, evidence and a super admin", async () => {
    await bothStages();
    const v1 = { expectedVersion: 1, reason: "Agreed with finance" };
    const notAllowed = [
      [SUP_DEBT, "propose", "written_off"], [SUP_DEBT, "resolve", "written_off"], [SUP_DEBT, "resolve", "recovered_externally"],
      [SUP_DEBT, "propose", "withhold"], [SUP_DEBT, "resolve", "forgive"],
      [DRV_DEBT, "resolve", "withhold"], [DRV_DEBT, "resolve", "pay_in_full"], [DRV_DEBT, "propose", "withhold"],
      [DRV_DEBT, "propose", "pay_in_full"], [DRV_DEBT, "resolve", "written_off"],
    ];
    for (const [debtId, action, resolution] of notAllowed) {
      await rejects(resolveDebt({ debtId, action, resolution, evidence: "Ticket 123456", ...v1 }), "failed-precondition", "resolution_not_allowed");
    }
    for (const reason of ["ab", "  a  ", undefined]) {
      const data = { debtId: SUP_DEBT, action: "resolve", resolution: "pay_in_full", expectedVersion: 1, reason };
      if (reason === undefined) delete data.reason;
      await rejects(resolveDebt(data), "invalid-argument", "reason_required");
    }
    for (const evidence of ["12345", "     x     ", undefined]) {
      const data = { debtId: DRV_DEBT, action: "propose", resolution: "written_off", evidence, ...v1 };
      if (evidence === undefined) delete data.evidence;
      await rejects(resolveDebt(data), "invalid-argument", "evidence_required");
    }
    for (const uid of [PLAIN, INACTIVE, D, null]) {
      await rejects(resolveDebt({ debtId: SUP_DEBT, action: "resolve", resolution: "pay_in_full", ...v1 }, uid), uid ? "permission-denied" : "unauthenticated");
    }
    await rejects(resolveDebt({ debtId: SUP_DEBT, action: "resolve", resolution: "pay_in_full", ...v1, amountPesewas: 1 }), "invalid-argument", "unexpected_fields");
    for (const bad of [{ action: "settle" }, { expectedVersion: 0 }, { expectedVersion: "1" }, { debtId: "../x" }]) {
      await rejects(resolveDebt({ debtId: SUP_DEBT, action: "resolve", resolution: "pay_in_full", ...v1, ...bad }), "invalid-argument", "invalid_request");
    }
    await rejects(resolveDebt({ debtId: "nope__driver__reversal", action: "resolve", resolution: "pay_in_full", ...v1 }), "not-found", "debt_not_found");
    for (const id of [SUP_DEBT, DRV_DEBT]) {
      const d = await h.read(`${L.DEBTS}/${id}`);
      assert.deepEqual([d.status, d.version], ["outstanding", 1], id);
    }
    assert.equal((await audits()).length, 0, "no refusal is audited as a resolution");

    const stBefore = await h.read(`${L.STATEMENTS}/${SUP_ST}`);
    assert.deepEqual(await resolveDebt({ debtId: SUP_DEBT, action: "resolve", resolution: "pay_in_full", ...v1 }),
      { debtId: SUP_DEBT, status: "resolved", resolution: "pay_in_full", version: 2 });
    const sup = await h.read(`${L.DEBTS}/${SUP_DEBT}`);
    assert.deepEqual([sup.status, sup.resolution, sup.reason, sup.resolvedBy, sup.version], ["resolved", "pay_in_full", "Agreed with finance", SUPER, 2]);
    assert.deepEqual(await h.read(`${L.STATEMENTS}/${SUP_ST}`), stBefore, "pay in full withholds nothing");
    const supAlert = await h.read(`admin_alerts/gas_settlement_debt_${SUP_DEBT}`);
    assert.deepEqual([supAlert.resolved, supAlert.resolvedBy], [true, SUPER], "the debt's alert is resolved with it");
    assert.ok(supAlert.resolvedAt);
    assert.deepEqual(await resolveDebt({ debtId: DRV_DEBT, action: "propose", resolution: "recovered_externally", evidence: "Receipt MM-778899", ...v1 }),
      { debtId: DRV_DEBT, status: "resolution_proposed", resolution: "recovered_externally", version: 2 });
    const a = await audits();
    assert.equal(a.length, 2, "one audit entry per success");
    assert.deepEqual(a.map((x) => [x.debtId, x.step, x.adminUid]).sort(), [[DRV_DEBT, "propose", SUPER], [SUP_DEBT, "resolve", SUPER]]);
    assert.deepEqual(await h.read(`drivers/${D}`), { walletBalance: 5, commissionOwed: 2 }, "never recovered automatically");
    await rejects(resolveDebt({ debtId: SUP_DEBT, action: "resolve", resolution: "pay_in_full", ...v1, expectedVersion: 2 }), "failed-precondition", "debt_resolved");
  });

  test("GSL-OD06 two concurrent resolutions of one debt: exactly one applies", async () => {
    await settled();
    await reverse();
    const runs = await Promise.allSettled([
      resolveDebt({ debtId: DRV_DEBT, action: "resolve", resolution: "withhold", expectedVersion: 1, reason: "Withhold from this statement" }),
      resolveDebt({ debtId: DRV_DEBT, action: "resolve", resolution: "pay_in_full", expectedVersion: 1, reason: "CTSGo absorbs" }, SUPER2),
    ]);
    const won = runs.filter((r) => r.status === "fulfilled");
    assert.equal(won.length, 1);
    const lost = runs.find((r) => r.status === "rejected").reason;
    assert.ok(["debt_changed", "debt_resolved"].includes(lost.details?.reason), JSON.stringify(lost.details));
    const debt = await h.read(`${L.DEBTS}/${DRV_DEBT}`);
    assert.equal(debt.version, 2);
    assert.equal(debt.resolution, won[0].value.resolution);
    const st = await h.read(`${L.STATEMENTS}/${DRV_ST}`);
    assert.equal(st.withheldPesewas ?? 0, debt.resolution === "withhold" ? 3640 : 0, "withheld at most once");
    assert.equal((await audits()).length, 1);
    // A stale version is refused even while outstanding.
    await h.db().doc(`${L.STATEMENTS}/${SUP_ST}`).update({ payoutStatus: "paid", payoutMethod: "mtn_momo" });
    await rejects(resolveDebt({ debtId: SUP_DEBT, action: "resolve", resolution: "pay_in_full", expectedVersion: 2, reason: "Stale" }), "failed-precondition", "debt_changed");
    // Concurrent approve and reject of one proposal.
    await resolveDebt({ debtId: SUP_DEBT, action: "propose", resolution: "written_off", evidence: "Board minute 2026-41", expectedVersion: 1, reason: "Uncollectable" });
    const decided = await Promise.allSettled([
      resolveDebt({ debtId: SUP_DEBT, action: "approve", expectedVersion: 2, reason: "Approved" }, SUPER2),
      resolveDebt({ debtId: SUP_DEBT, action: "reject", expectedVersion: 2, reason: "Not yet" }, SUPER2),
    ]);
    assert.equal(decided.filter((r) => r.status === "fulfilled").length, 1);
    assert.equal((await h.read(`${L.DEBTS}/${SUP_DEBT}`)).version, 3);
  });

  test("GSL-OD07 withholding records the amount on the statement and never edits its net or lines", async () => {
    await settled("o2");
    const before = await h.read(`${L.STATEMENTS}/${DRV_ST}`);
    assert.equal(before.netPesewas, 7280);
    await reverse("o1"); await reverse("o2");
    assert.deepEqual(await resolveDebt({ debtId: DRV_DEBT, action: "resolve", resolution: "withhold", expectedVersion: 1, reason: "Withhold from this statement" }),
      { debtId: DRV_DEBT, status: "resolved", resolution: "withhold", version: 2 });
    const st = await h.read(`${L.STATEMENTS}/${DRV_ST}`);
    assert.equal(st.withheldPesewas, 3640);
    assert.equal(st.payablePesewas, 7280 - 3640);
    assert.deepEqual(st.withheldDebtIds, [DRV_DEBT]);
    assert.equal(st.netPesewas, before.netPesewas);
    assert.deepEqual(st.lines, before.lines);
    assert.equal(st.payoutStatus, "not_started");
    // Once the statement is credited, withholding is no longer possible: the debt needs the after-payout route.
    await h.db().doc(`${L.STATEMENTS}/${DRV_ST}`).update({ payoutStatus: "paid", payoutMethod: "driver_wallet" });
    const o2 = { debtId: "o2__driver__reversal", expectedVersion: 1, reason: "Withhold from this statement" };
    await rejects(resolveDebt({ ...o2, action: "resolve", resolution: "withhold" }), "failed-precondition", "debt_stage_changed");
    assert.equal((await h.read(`${L.STATEMENTS}/${DRV_ST}`)).withheldPesewas, 3640);
    const p = await resolveDebt({ ...o2, action: "propose", resolution: "written_off", evidence: "Ops ticket 4455", reason: "Rider unreachable" });
    assert.equal(p.status, "resolution_proposed");
    assert.equal((await h.read(`${L.DEBTS}/o2__driver__reversal`)).stage, "after_payout");
    assert.deepEqual(await h.read(`drivers/${D}`), { walletBalance: 5, commissionOwed: 2 });
  });

  test("GSL-OD08 an after-payout resolution is proposed by one super admin and approved or rejected by another", async () => {
    await bothStages();
    await rejects(resolveDebt({ debtId: DRV_DEBT, action: "approve", expectedVersion: 1, reason: "Approve" }, SUPER2), "failed-precondition", "no_proposal");
    await resolveDebt({ debtId: DRV_DEBT, action: "propose", resolution: "written_off", evidence: "Ops ticket 4455", expectedVersion: 1, reason: "Rider unreachable" });
    let d = await h.read(`${L.DEBTS}/${DRV_DEBT}`);
    assert.equal(d.status, "resolution_proposed");
    assert.deepEqual([d.proposal.resolution, d.proposal.by, d.proposal.reason, d.proposal.evidence], ["written_off", SUPER, "Rider unreachable", "Ops ticket 4455"]);
    assert.ok(d.proposal.at);
    await rejects(resolveDebt({ debtId: DRV_DEBT, action: "approve", expectedVersion: 2, reason: "Self approve" }), "permission-denied", "proposer_cannot_approve");
    await rejects(resolveDebt({ debtId: DRV_DEBT, action: "approve", expectedVersion: 2, reason: "Approve" }, PLAIN), "permission-denied");
    await rejects(resolveDebt({ debtId: DRV_DEBT, action: "propose", resolution: "recovered_externally", evidence: "Receipt 998877", expectedVersion: 2, reason: "Again" }, SUPER2),
      "failed-precondition", "debt_not_outstanding");
    assert.deepEqual(await resolveDebt({ debtId: DRV_DEBT, action: "reject", expectedVersion: 2, reason: "Try recovery first" }, SUPER2),
      { debtId: DRV_DEBT, status: "outstanding", version: 3 });
    d = await h.read(`${L.DEBTS}/${DRV_DEBT}`);
    assert.equal(d.status, "outstanding");
    assert.equal(d.proposal, undefined);
    assert.equal(d.rejectedProposals.length, 1);
    assert.equal((await h.read(`admin_alerts/gas_settlement_debt_${DRV_DEBT}`)).resolved, false, "a proposal or rejection resolves nothing");
    assert.deepEqual([d.rejectedProposals[0].resolution, d.rejectedProposals[0].by, d.rejectedProposals[0].rejectedBy], ["written_off", SUPER, SUPER2]);
    await resolveDebt({ debtId: DRV_DEBT, action: "propose", resolution: "recovered_externally", evidence: "Receipt MM-998877", expectedVersion: 3, reason: "Rider repaid in cash" }, SUPER2);
    assert.deepEqual(await resolveDebt({ debtId: DRV_DEBT, action: "approve", expectedVersion: 4, reason: "Receipt checked" }),
      { debtId: DRV_DEBT, status: "resolved", resolution: "recovered_externally", version: 5 });
    d = await h.read(`${L.DEBTS}/${DRV_DEBT}`);
    assert.deepEqual([d.status, d.resolution, d.resolvedBy, d.approvedBy, d.evidence], ["resolved", "recovered_externally", SUPER2, SUPER, "Receipt MM-998877"]);
    assert.ok(d.resolvedAt);
    const alert = await h.read(`admin_alerts/gas_settlement_debt_${DRV_DEBT}`);
    assert.deepEqual([alert.resolved, alert.resolvedBy], [true, SUPER], "resolved by the approver");
    assert.ok(alert.resolvedAt);
    const a = await audits();
    assert.deepEqual(a.map((x) => x.step).sort(), ["approve", "propose", "propose", "reject"]);
    const last = a.filter((x) => x.step === "propose" || x.step === "approve").filter((x) => x.resolution === "recovered_externally");
    assert.deepEqual(last.map((x) => x.adminUid).sort(), [SUPER, SUPER2].sort(), "two different super admins on record");
    await rejects(resolveDebt({ debtId: DRV_DEBT, action: "reject", expectedVersion: 5, reason: "Too late" }, SUPER2), "failed-precondition", "debt_resolved");
  });

  test("GSL-OD09 statuses: adjustments, wallet credits and paid supplier lines", () => {
    const rev = { kind: "reversal" }, ent = { kind: "entitlement" };
    const held = { claim: { entryId: "x", debtId: "x" } };
    assert.equal(L.entryStatus(rev, { ...held, debt: { status: "outstanding" } }), "outstanding_adjustment");
    assert.equal(L.entryStatus(rev, { ...held, debt: { status: "resolution_proposed" } }), "outstanding_adjustment", "still visible while proposed");
    assert.equal(L.entryStatus(rev, { ...held, debt: null }), "outstanding_adjustment", "fails closed");
    assert.equal(L.entryStatus(rev, { ...held, debt: { status: "resolved" } }), "resolved_adjustment");
    const claim = { entryId: "y", statementId: "st" };
    assert.equal(L.entryStatus(ent, { claim, statement: { party: "driver", payoutMethod: "driver_wallet", payoutStatus: "paid" } }), "credited_to_wallet");
    assert.equal(L.entryStatus(ent, { claim, statement: { party: "driver", payoutMethod: null, payoutStatus: "not_started" } }), "settlement_prepared");
    assert.equal(L.entryStatus(ent, { claim, statement: { party: "supplier", payoutMethod: "mtn_momo", payoutStatus: "paid" } }), "paid");
    assert.equal(L.debtStage({ party: "supplier", payoutStatus: "not_started" }), "before_payout");
    assert.equal(L.debtStage({ party: "supplier", payoutStatus: "failed" }), "before_payout");
    assert.equal(L.debtStage({ party: "driver", payoutStatus: "failed" }), "after_payout");
    for (const s of ["payout_in_progress", "paid", "not_required"]) assert.equal(L.debtStage({ party: "supplier", payoutStatus: s }), "after_payout", s);
    assert.equal(L.debtStage(null), "after_payout", "unknown: assume money may have moved");
  });

  test("GSL-OD10 an original whose reversal is dated later is held back, so the pair settles together", async () => {
    await seedTerms();
    await postCaptured("o1");
    await reverse(); // dated today: not in the DAY query
    await L.prepareStatements(DAY, { now: NEXT_DAY_NOON });
    assert.equal(await h.read(`${L.CLAIMS}/o1__supplier__entitlement`), null, "not claimed without its reversal");
    await L.prepareStatements(today(), { now: closed(today()) });
    const st = await h.read(`${L.STATEMENTS}/${today()}__supplier__${S}`);
    assert.deepEqual(st.lines.map((l) => l.entryId).sort(), ["o1__supplier__entitlement", SUP_DEBT]);
    assert.equal(st.netPesewas, 0);
    assert.equal((await h.db().collection(L.DEBTS).get()).size, 0);
  });
  test("GSL-OD11 a reversed settled entry of zero is a debt created already resolved: nothing owed, no high alert", async () => {
    await seedTerms();
    await postCaptured("o1", { snap: { deliveryFee: 0, total: 300 } });
    await L.prepareStatements(DAY, { now: NEXT_DAY_NOON });
    assert.equal((await h.read(`${L.CLAIMS}/o1__driver__entitlement`)).statementId, DRV_ST);
    await reverse();
    const rev = await h.read(`${L.LEDGER}/${DRV_DEBT}`);
    assert.ok(Object.is(rev.amountPesewas, 0), "0, not -0");
    const d = await h.read(`${L.DEBTS}/${DRV_DEBT}`);
    assert.deepEqual([d.status, d.resolution, d.resolvedBy, d.amountPesewas, d.version], ["resolved", "nothing_owed", "system", 0, 1]);
    assert.ok(d.resolvedAt);
    assert.equal((await h.read(`${L.CLAIMS}/${DRV_DEBT}`)).debtId, DRV_DEBT, "still held out of statements");
    assert.equal(await h.read(`admin_alerts/gas_settlement_debt_${DRV_DEBT}`), null, "no alert");
    assert.equal(await h.read(`admin_alerts/gas_settlement_debt_${SUP_DEBT}`) !== null, true, "the supplier's non-zero debt still alerts");
    assert.equal((await h.read(`${L.DEBTS}/${SUP_DEBT}`)).status, "outstanding");
    const a = (await audits()).filter((x) => x.debtId === DRV_DEBT);
    assert.deepEqual(a.map((x) => [x.step, x.resolution, x.adminUid, x.amountPesewas]), [["system", "nothing_owed", null, 0]]);
    await rejects(resolveDebt({ debtId: DRV_DEBT, action: "resolve", resolution: "pay_in_full", expectedVersion: 1, reason: "Nothing" }), "failed-precondition", "debt_resolved");
  });
  test("GSL-OD12 propose and approve are refused while the claiming statement's payout is unconfirmed; reject is allowed", async () => {
    await bothStages();
    const v = { reason: "Assume paid", evidence: "Bridge ticket 4455" };
    await h.db().doc(`${L.STATEMENTS}/${SUP_ST}`).update({ payoutStatus: "payout_in_progress", payoutMethod: "mobile_money", payout: { outcome: "unknown" } });
    await rejects(resolveDebt({ debtId: SUP_DEBT, action: "propose", resolution: "written_off", expectedVersion: 1, ...v }), "failed-precondition", "debt_payout_unconfirmed");
    // A proposal made before the payout started cannot be approved while it is unconfirmed.
    await h.db().doc(`${L.STATEMENTS}/${DRV_ST}`).update({ payoutStatus: "paid" });
    await resolveDebt({ debtId: DRV_DEBT, action: "propose", resolution: "written_off", expectedVersion: 1, ...v });
    await h.db().doc(`${L.STATEMENTS}/${DRV_ST}`).update({ payoutStatus: "payout_in_progress" });
    await rejects(resolveDebt({ debtId: DRV_DEBT, action: "approve", expectedVersion: 2, reason: "Approved" }, SUPER2), "failed-precondition", "debt_payout_unconfirmed");
    assert.deepEqual((await resolveDebt({ debtId: DRV_DEBT, action: "reject", expectedVersion: 2, reason: "Wait for Bridge" }, SUPER2)).status, "outstanding");
    for (const id of [SUP_DEBT, DRV_DEBT]) assert.equal((await h.read(`${L.DEBTS}/${id}`)).status, "outstanding", id);
    assert.equal((await h.read(`admin_alerts/gas_settlement_debt_${SUP_DEBT}`)).resolved, false);
    // Once Bridge confirms the failure, the supplier debt is before payout again: withhold applies.
    await h.db().doc(`${L.STATEMENTS}/${SUP_ST}`).update({ payoutStatus: "failed" });
    await rejects(resolveDebt({ debtId: SUP_DEBT, action: "propose", resolution: "written_off", expectedVersion: 1, ...v }), "failed-precondition", "resolution_not_allowed");
    assert.equal((await resolveDebt({ debtId: SUP_DEBT, action: "resolve", resolution: "withhold", expectedVersion: 1, reason: "Withhold" })).status, "resolved");
  });
});
