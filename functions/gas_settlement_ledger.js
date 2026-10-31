"use strict";

/**
 * Gas supplier settlement: commission terms, the per-order financial
 * allocation, entitlements, reversals and daily statements for
 * gas_supplier_orders. Accounting only: nothing here moves money, changes a
 * wallet or drivers.walletBalance, or pays anyone.
 *
 * Commercial model (agreed 2026-10-28), in whole pesewas:
 *   customer total     = product subtotal + supplier handling fee + delivery fee
 *   commission base    = product subtotal (handling and delivery fees are not
 *                        commissionable under the initial terms)
 *   commission         = floor(commission base × rateBps / 10000)
 *   supplier gross     = product subtotal + handling fee
 *   supplier net       = supplier gross − commission + supplier adjustments
 *   driver net         = delivery fee + driver adjustments (the delivery
 *                        entitlement, by deliveryMode: "ctsgo_driver", the
 *                        CTSGo driver's; "linked_rider", the linked rider's
 *                        own (driverId; CTSGo pays the rider directly, D1),
 *                        never the supplier's; "supplier_rider", the
 *                        supplier's own, owner decision 2026-10-29). Any
 *                        other mode is refused.
 * The supplier sets the product price; commission is a settlement deduction
 * from the supplier's proceeds, never added to what the customer pays, and
 * never taken from the driver's delivery fee. Rounding is down to the
 * pesewa (floor), so rounding never takes more than the agreed rate from the
 * supplier; the parts always add up to the customer total. There is no
 * approved adjustment mechanism yet, so both adjustments are 0; a correction
 * is a full reversal. A reversal is accounting only: it never refunds the
 * customer (there is no post-delivery refund; refunds happen only through
 * cancellation before delivery, escrow.js refundEscrow).
 *
 * Commission terms (gas_commission_terms): versions v1, v2, … proposed by a
 * super admin and approved by a different super admin
 * (adminProposeGasCommissionTerms / adminDecideGasCommissionTerms);
 * approval copies the version to `current`. Clients cannot write any of it.
 * No rate is assumed: without usable current terms, supplier orders are
 * neither quoted, created nor paid.
 *
 * Allocation (gas_supplier_orders/{id}/finance/allocation): computed by
 * createGasSupplierOrder from the order's price snapshot and the current
 * terms, in the same transaction as the order, and never recomputed with
 * other terms: a later terms change applies to later orders only. It lives
 * outside the order document because the passenger may read the order and
 * commission is not shown to customers; admins read it, and the supplier
 * portal shows each supplier its own.
 *
 * Ledger (gas_settlement_ledger) is append-only and server-written. Entry
 * ids are deterministic, `${orderId}__${party}__${kind}`, and are created
 * in one transaction per order from the locked allocation, so a retry or a
 * duplicate completion event cannot post twice. A refund or correction
 * appends `reversal` entries that negate the originals; nothing is ever
 * edited or deleted. Each entry's basis records the deliveryMode (and the
 * linkedSupplierId on a linked rider's entry), for audit only.
 *
 * Reversals of settled entries (F3): a reversal is never dropped and never
 * deducted automatically from later earnings. Before its original is
 * claimed, the two are claimed together by one statement and net to zero.
 * Once the original is claimed, the reversal becomes an outstanding debt
 * (gas_settlement_debts/{reversalEntryId}, created once with the reversal),
 * held out of every statement, with a high alert, until a super admin
 * resolves it explicitly: before payout, withhold it from the claiming
 * statement or pay in full; after payout, written off or recovered
 * externally, proposed by one super admin and approved by another. Every
 * step is version-checked and audited (audit_log gas_settlement_debt_resolved).
 * No statement nets below zero. Debts never feed drivers.commissionOwed.
 *
 * Status of an entitlement (derived, never stored on the entry):
 *   pending              accrued; payment not captured or hold period open
 *   eligible             payment captured, hold period over, not reversed
 *   settlement_prepared  claimed by a daily statement
 *   payout_in_progress   that statement's payout has started
 *   paid                 that statement's payout is confirmed
 *   credited_to_wallet   a driver statement credited to the CTSGo wallet
 *                        (stored as payoutStatus "paid", payoutMethod
 *                        "driver_wallet"): never a payout
 *   reversed             a reversal exists and it was never settled
 *   outstanding_adjustment / resolved_adjustment
 *                        a reversal of a settled entry, held as a debt
 * Only gas_supplier_payouts.js sets a statement's payoutStatus (behind
 * settings/gas_supplier_payouts): a supplier payout is "paid" only once a
 * super admin records Bridge's confirmation; a driver statement is "paid"
 * when it is credited to the driver's wallet.
 *
 * Why this is separate from the shared `ledger` collection: that collection
 * records wallet movements (its daily reconciliation sums every COMPLETED
 * amount as volume) and passengers can read rows naming them, which would
 * expose commission. Entitlements are accruals, not wallet movements.
 *
 * Payment: posting needs the escrow the order names (payment.escrowId,
 * bound by payGasSupplierOrder; referenceType "gas_supplier_order", amount
 * == the customer total) and eligibility needs escrow.status "CAPTURED"
 * (completeGasSupplierOrder). Both are behind settings/gas_supplier_fulfilment.
 * The existing release (driverNet to the driver's wallet) is never used for
 * these orders. Posting runs right after delivery (gas_supplier_fulfilment.js)
 * and statements are prepared daily (gas_supplier_payouts.js); super admins
 * can also post, reverse and prepare by hand.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { adminAlert } = require("./alert_payload");

const db = () => admin.firestore();
const FieldValue = admin.firestore.FieldValue;
const Timestamp = admin.firestore.Timestamp;

const LEDGER = "gas_settlement_ledger";
const CLAIMS = "gas_settlement_claims";
const STATEMENTS = "gas_settlement_statements";
/** Outstanding debts from reversals of claimed entries: gas_settlement_debts/{reversalEntryId}. */
const DEBTS = "gas_settlement_debts";
const TERMS = "gas_commission_terms";
const TERMS_DOC = `${TERMS}/current`;
const ORDERS = "gas_supplier_orders";
/** The order's allocation: gas_supplier_orders/{orderId}/finance/allocation. */
const FINANCE = "finance";
const ALLOCATION_ID = "allocation";
/** The only commission base the initial terms allow. */
const COMMISSION_BASE = "product_subtotal";
/** Bump when the allocation calculation changes; stored on every allocation. */
const ALLOCATION_VERSION = 1;
const TERMS_VERSION_ID = /^v[1-9][0-9]{0,5}$/;
const ESCROW_REFERENCE_TYPE = "gas_supplier_order";
/** Reserved for the future supplier capture path (escrow security review). */
const ESCROW_CAPTURED = "CAPTURED";
/** Lines per statement transaction (Firestore allows 500 writes; one claim per line). */
const MAX_LINES_PER_STATEMENT = 400;
const PARTIES = Object.freeze(["supplier", "driver", "platform"]);
const PAYOUT_PARTIES = Object.freeze(["supplier", "driver"]);
const PLATFORM_ID = "ctsgo";
/** The delivery modes that may be posted; anything else is refused. */
const DELIVERY_MODES = Object.freeze(["ctsgo_driver", "linked_rider", "supplier_rider"]);
/** The resolutions each debt stage allows, and the action that applies them (R2). */
const DEBT_RESOLUTIONS = Object.freeze({
  before_payout: Object.freeze({ action: "resolve", resolutions: Object.freeze(["withhold", "pay_in_full"]) }),
  after_payout: Object.freeze({ action: "propose", resolutions: Object.freeze(["written_off", "recovered_externally"]) }),
});
const DEBT_ACTIONS = Object.freeze(["resolve", "propose", "approve", "reject"]);

// ── Pure rules (exported for tests) ──────────────────────────────────────────

/** GHS amount → whole pesewas, or null if it is not an exact pesewa amount. */
function toPesewas(v) {
  if (typeof v !== "number" || !Number.isFinite(v)) return null;
  const p = Math.round(v * 100);
  return Math.abs(p - v * 100) < 1e-6 ? p : null;
}

/** Why the commission terms cannot be used, or null. */
function termsProblem(t) {
  if (!t) return "commission_terms_missing";
  if (t.active !== true) return "commission_terms_inactive";
  if (!Number.isInteger(t.rateBps) || t.rateBps < 0 || t.rateBps > 10000) return "commission_rate_invalid";
  if (typeof t.termsReference !== "string" || !t.termsReference.trim()) return "commission_terms_unreferenced";
  if (typeof t.approvedBy !== "string" || !t.approvedBy) return "commission_terms_unapproved";
  if (!Number.isInteger(t.version) || t.version < 1) return "commission_terms_unversioned";
  if (!(typeof t.settlementHoldHours === "number" && t.settlementHoldHours >= 0)) return "settlement_hold_undefined";
  if (t.commissionBase !== COMMISSION_BASE || t.handlingFeeCommissionable !== false || t.deliveryFeeCommissionable !== false) {
    return "commission_base_unsupported";
  }
  if (t.termsId !== termsVersionId(t.version)) return "commission_terms_unversioned";
  return null;
}

const termsVersionId = (version) => `v${version}`;

/** The amounts of an allocation, in pesewas: compared field by field on every check. */
const ALLOCATION_AMOUNTS = Object.freeze([
  "productSubtotalPesewas", "handlingFeePesewas", "deliveryFeePesewas", "customerTotalPesewas",
  "commissionBasePesewas", "commissionPesewas", "supplierGrossPesewas", "supplierAdjustmentsPesewas",
  "supplierNetPesewas", "driverAdjustmentsPesewas", "driverNetPesewas",
]);

/**
 * The amounts for one price snapshot at one rate, in pesewas, or
 * { problem }. Pure. The snapshot's line amounts must equal its unit
 * amounts × quantity, and its parts must add up to its total.
 */
function allocate(snapshot, rateBps) {
  const total = toPesewas(snapshot?.total);
  const product = toPesewas(snapshot?.productAmount);
  const handling = toPesewas(snapshot?.handlingFee ?? 0);
  const delivery = toPesewas(snapshot?.deliveryFee);
  const unitPrice = toPesewas(snapshot?.unitPrice);
  const unitHandling = toPesewas(snapshot?.unitHandlingFee ?? 0);
  const quantity = snapshot?.quantity;
  if ([total, product, handling, delivery, unitPrice, unitHandling].some((v) => v == null || v < 0) || !(product > 0)) {
    return { problem: "snapshot_amounts_invalid" };
  }
  if (snapshot.currency !== undefined && snapshot.currency !== "GHS") return { problem: "snapshot_amounts_invalid" };
  if (!Number.isInteger(quantity) || quantity < 1 || unitPrice * quantity !== product || unitHandling * quantity !== handling) {
    return { problem: "snapshot_lines_inconsistent" };
  }
  if (product + handling + delivery !== total) return { problem: "snapshot_does_not_add_up" };
  if (!Number.isInteger(rateBps) || rateBps < 0 || rateBps > 10000) return { problem: "commission_rate_invalid" };
  // Floor: rounding never takes more than the agreed rate from the supplier.
  const commission = Math.floor((product * rateBps) / 10000);
  const a = {
    productSubtotalPesewas: product, handlingFeePesewas: handling, deliveryFeePesewas: delivery, customerTotalPesewas: total,
    commissionBasePesewas: product, commissionPesewas: commission,
    supplierGrossPesewas: product + handling, supplierAdjustmentsPesewas: 0, supplierNetPesewas: product + handling - commission,
    driverAdjustmentsPesewas: 0, driverNetPesewas: delivery,
  };
  if (a.supplierNetPesewas + a.driverNetPesewas + a.commissionPesewas !== total) return { problem: "allocation_does_not_add_up" };
  return a;
}

/**
 * The allocation for a new order: the snapshot's amounts at the current
 * terms' rate, with the terms that applied. Pure. { problem } when the
 * terms are not usable or the snapshot does not add up.
 */
function computeAllocation(snapshot, terms) {
  const tp = termsProblem(terms);
  if (tp) return { problem: tp };
  const amounts = allocate(snapshot, terms.rateBps);
  if (amounts.problem) return amounts;
  return {
    allocationVersion: ALLOCATION_VERSION, currency: "GHS", ...amounts,
    commissionBase: COMMISSION_BASE, commissionRateBps: terms.rateBps, commissionRounding: "floor",
    commissionTermsId: terms.termsId, commissionTermsVersion: terms.version, commissionTermsReference: terms.termsReference,
  };
}

/**
 * Why a stored allocation does not match its order's snapshot, or null.
 * Recomputed at the allocation's own rate; every amount must agree. Pure.
 */
function allocationProblem(snapshot, a) {
  if (!a) return "allocation_missing";
  if (a.allocationVersion !== ALLOCATION_VERSION || a.currency !== "GHS" || a.commissionBase !== COMMISSION_BASE || a.commissionRounding !== "floor") {
    return "allocation_unsupported";
  }
  if (typeof a.commissionTermsId !== "string" || a.commissionTermsId !== termsVersionId(a.commissionTermsVersion)) return "allocation_terms_missing";
  const expected = allocate(snapshot, a.commissionRateBps);
  if (expected.problem) return expected.problem;
  return ALLOCATION_AMOUNTS.every((k) => a[k] === expected[k]) ? null : "allocation_does_not_reconcile";
}

/**
 * Why an allocation's terms version was not approved at the rate it
 * applies, or null. Pure. A superseded version was approved and stays
 * valid for the orders created under it.
 */
function allocationTermsProblem(a, version) {
  if (!version) return "allocation_terms_not_approved";
  if (version.status !== "approved" && version.status !== "superseded") return "allocation_terms_not_approved";
  if (typeof version.approvedBy !== "string" || !version.approvedBy) return "allocation_terms_not_approved";
  if (version.version !== a.commissionTermsVersion || version.rateBps !== a.commissionRateBps || version.termsReference !== a.commissionTermsReference) {
    return "allocation_terms_mismatch";
  }
  return null;
}

const allocationRef = (orderId) => db().collection(ORDERS).doc(orderId).collection(FINANCE).doc(ALLOCATION_ID);

/**
 * Why this order may not be posted, or null. Pure. The delivery mode is an
 * explicit allowlist; a linked rider's fee is checked against the
 * allocation in postOrderEntitlements, which reads it.
 */
function postingProblem(orderId, order, escrow) {
  if (!order) return "order_not_found";
  if (order.status !== "delivered") return "order_not_delivered";
  if (!order.deliveredAt) return "order_delivery_time_missing";
  if (!DELIVERY_MODES.includes(order.deliveryMode)) return "order_delivery_mode_unknown";
  if (order.deliveryMode === "supplier_rider") {
    if (order.driverId) return "order_driver_unexpected";
  } else if (typeof order.driverId !== "string" || !order.driverId) return "order_driver_missing";
  if (order.deliveryMode === "linked_rider" && (typeof order.linkedSupplierId !== "string" || order.linkedSupplierId !== order.supplierId)) {
    return "order_linked_supplier_mismatch";
  }
  if (typeof order.supplierId !== "string" || order.supplierId !== order.priceSnapshot?.supplierId) return "order_supplier_mismatch";
  if (typeof order.passengerId !== "string" || !order.passengerId) return "order_passenger_missing";
  // The escrow is untrusted: in production attachEscrowToOrder stores any
  // client-supplied referenceType/referenceId. Only an escrow the order
  // itself names (payment.escrowId, server-written) is considered, and it
  // must belong to the order's passenger and hold exactly the snapshot total.
  if (typeof order.payment?.escrowId !== "string") return "payment_missing";
  if (!escrow) return "escrow_missing";
  if (escrow.userId !== order.passengerId) return "escrow_owner_mismatch";
  if (escrow.referenceType !== ESCROW_REFERENCE_TYPE || escrow.referenceId !== orderId) return "escrow_reference_mismatch";
  if (toPesewas(escrow.amount) == null || toPesewas(escrow.amount) !== toPesewas(order.priceSnapshot?.total)) return "escrow_amount_mismatch";
  if (escrow.status !== "HELD" && escrow.status !== ESCROW_CAPTURED) return "escrow_not_active";
  return null;
}

/** Accra business date (UTC+0, no daylight saving) of a time. */
function businessDate(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

const entryId = (orderId, party, kind) => `${orderId}__${party}__${kind}`;

/**
 * Who is entitled to an order's delivery fee: the CTSGo driver, or the
 * supplier when its own rider delivered. `slot` names the reversal id. Pure.
 */
function deliverySlot(order) {
  return order?.deliveryMode === "supplier_rider"
    ? { idParty: "supplier", kind: "delivery_fee", party: "supplier", partyId: order.supplierId, slot: "supplier_delivery" }
    : { idParty: "driver", kind: "entitlement", party: "driver", partyId: order?.driverId, slot: "driver" };
}
/** Every original an order may have, with its reversal slot. */
const ORIGINAL_KINDS = Object.freeze([
  ["supplier", "entitlement", "supplier"], ["driver", "entitlement", "driver"],
  ["supplier", "delivery_fee", "supplier_delivery"], ["platform", "commission", "platform"],
]);
/** The reversal id of an original entry, or null. */
function reversalIdOf(entry) {
  const k = ORIGINAL_KINDS.find(([p, kind]) => entryId(entry.orderId, p, kind) === entry.entryId);
  return k ? entryId(entry.orderId, k[2], "reversal") : null;
}

/**
 * Status of an entitlement or reversal entry. Pure.
 * ctx: { reversed, claim, statement, debt, escrow, deliveredAtMs, holdHours, now }
 * (statement: its payoutStatus, party and payoutMethod; debt: the claim's
 * debt, when the claim holds a reversal of a settled entry).
 */
function entryStatus(entry, ctx) {
  if (ctx.claim) {
    if (ctx.claim.debtId) return ctx.debt?.status === "resolved" ? "resolved_adjustment" : "outstanding_adjustment";
    if (ctx.statement?.payoutStatus === "paid") {
      // A driver statement is credited to the CTSGo wallet, never paid out.
      return ctx.statement.party === "driver" && ctx.statement.payoutMethod === "driver_wallet" ? "credited_to_wallet" : "paid";
    }
    if (ctx.statement?.payoutStatus === "payout_in_progress") return "payout_in_progress";
    return "settlement_prepared";
  }
  if (entry.kind === "reversal") return "eligible"; // claimed with its unsettled original, netting to zero
  if (ctx.reversed) return "reversed";
  if (ctx.escrow?.status !== ESCROW_CAPTURED) return "pending";
  if (!(typeof ctx.deliveredAtMs === "number" && typeof ctx.holdHours === "number")) return "pending";
  if (ctx.now < ctx.deliveredAtMs + ctx.holdHours * 3600e3) return "pending";
  return "eligible";
}

/**
 * Why an order's ledger entries do not reconcile, or null. Pure. The
 * originals must be exactly the allocation's supplier net, driver net and
 * commission, which add up to the customer total; the allocation must
 * still match the order's snapshot; the payment must equal the total.
 */
function reconciliationProblem(list, order, escrow, alloc) {
  const originals = list.filter((x) => x.kind !== "reversal");
  if (originals.length !== 3) return "entries_incomplete";
  const ap = allocationProblem(order?.priceSnapshot, alloc);
  if (ap) return ap;
  const amount = (party, kind) => originals.find((x) => x.party === party && x.kind === kind)?.amountPesewas;
  const delivery = amount("driver", "entitlement") ?? amount("supplier", "delivery_fee");
  if (amount("supplier", "entitlement") !== alloc.supplierNetPesewas || delivery !== alloc.driverNetPesewas || amount("platform", "commission") !== alloc.commissionPesewas) {
    return "entries_differ_from_allocation";
  }
  const total = alloc.customerTotalPesewas;
  if (originals.reduce((s, x) => s + x.amountPesewas, 0) !== total || list.some((x) => x.basis?.snapshotTotalPesewas !== total)) {
    return "entries_differ_from_total";
  }
  if (toPesewas(escrow?.amount) !== total) return "payment_differs_from_total";
  return null;
}

/**
 * The stage of a debt from the statement that claimed its original. Pure.
 * Before payout while nothing can have been paid (a supplier payout that
 * Bridge refused or that failed counts as unpaid); otherwise money may
 * already have moved.
 */
function debtStage(statement) {
  const s = statement?.payoutStatus;
  return s === "not_started" || (s === "failed" && statement.party === "supplier") ? "before_payout" : "after_payout";
}

/** Statement status from its net amount. Pure. */
function statementStatus(netPesewas) {
  return netPesewas > 0 ? "prepared" : "prepared_no_payout";
}

// ── Authorization ────────────────────────────────────────────────────────────

/** Active admin with role super_admin (admins/{uid}, as the rules' isSuperAdmin). */
async function requireSuperAdmin(request) {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  const snap = await db().collection("admins").doc(uid).get();
  const a = snap.exists ? snap.data() : null;
  if (!a || a.active !== true || a.role !== "super_admin") throw new HttpsError("permission-denied", "Super admins only.");
  return { uid, email: a.email ?? null };
}

function readRequest(data, allowed) {
  if (!data || typeof data !== "object" || Array.isArray(data)) throw new HttpsError("invalid-argument", "Invalid request.");
  const extra = Object.keys(data).filter((k) => !allowed.includes(k));
  if (extra.length) throw new HttpsError("invalid-argument", "Unexpected fields in request.", { reason: "unexpected_fields", fields: extra });
  return data;
}
const isId = (v) => typeof v === "string" && v.length > 0 && v.length <= 200 && !v.includes("/");

// ── Posting ──────────────────────────────────────────────────────────────────

/**
 * Posts the supplier, driver and platform entries for a delivered supplier
 * order, once, from its locked allocation. Returns { posted: true } or
 * { alreadyPosted: true }; throws a failed-precondition HttpsError with
 * details.reason when it may not post.
 */
async function postOrderEntitlements(orderId, { postedBy = "system" } = {}) {
  const orderRef = db().collection(ORDERS).doc(orderId);
  const allocRef = allocationRef(orderId);
  const ledgerRef = (party, kind) => db().collection(LEDGER).doc(entryId(orderId, party, kind));
  return db().runTransaction(async (tx) => {
    const [orderSnap, allocSnap, ...all] = await Promise.all([tx.get(orderRef), tx.get(allocRef), ...ORIGINAL_KINDS.map(([p, k]) => tx.get(ledgerRef(p, k)))]);
    const order = orderSnap.exists ? orderSnap.data() : null;
    const delivery = deliverySlot(order);
    const refs = {
      supplier: ledgerRef("supplier", "entitlement"),
      delivery: ledgerRef(delivery.idParty, delivery.kind),
      platform: ledgerRef("platform", "commission"),
    };
    const wanted = new Set(Object.values(refs).map((r) => r.id));
    const existing = all.filter((x) => x.exists);
    if (existing.length === 3 && existing.every((x) => wanted.has(x.id))) return { alreadyPosted: true };
    if (existing.length) throw new HttpsError("internal", "Partial posting found.", { reason: "partial_posting" });

    const alloc = allocSnap.exists ? allocSnap.data() : null;
    const escrowSnap = order?.payment?.escrowId && isId(order.payment.escrowId)
      ? await tx.get(db().collection("escrows").doc(order.payment.escrowId)) : null;
    const escrow = escrowSnap?.exists ? escrowSnap.data() : null;
    const versionSnap = alloc && TERMS_VERSION_ID.test(String(alloc.commissionTermsId))
      ? await tx.get(db().collection(TERMS).doc(alloc.commissionTermsId)) : null;

    const refuse = (reason, message) => new HttpsError("failed-precondition", message, { reason });
    const blocked = postingProblem(orderId, order, escrow);
    if (blocked) throw refuse(blocked, "Cannot post this order.");
    if (alloc && (alloc.orderId !== orderId || alloc.supplierId !== order.supplierId)) throw refuse("allocation_mismatch", "Cannot post this order.");
    const ap = allocationProblem(order.priceSnapshot, alloc);
    if (ap) throw refuse(ap, "This order's allocation does not reconcile.");
    const tp = allocationTermsProblem(alloc, versionSnap?.exists ? versionSnap.data() : null);
    if (tp) throw refuse(tp, "Commission terms are not approved.");
    // The linked rider accepted this exact fee (spec §2.1); it must still be the allocation's.
    if (order.deliveryMode === "linked_rider" && order.acceptedFeePesewas !== alloc.driverNetPesewas) {
      throw refuse("rider_fee_mismatch", "The rider's fee does not match this order's allocation.");
    }

    const s = order.priceSnapshot;
    const basis = {
      allocationVersion: alloc.allocationVersion,
      snapshotTotalPesewas: alloc.customerTotalPesewas, productPesewas: alloc.productSubtotalPesewas,
      handlingPesewas: alloc.handlingFeePesewas, deliveryPesewas: alloc.deliveryFeePesewas,
      commissionBasePesewas: alloc.commissionBasePesewas, commissionPesewas: alloc.commissionPesewas,
      supplierGrossPesewas: alloc.supplierGrossPesewas, supplierAdjustmentsPesewas: alloc.supplierAdjustmentsPesewas,
      driverAdjustmentsPesewas: alloc.driverAdjustmentsPesewas,
      priceVersion: s.priceVersion, quoteId: s.quoteId ?? null, escrowId: order.payment.escrowId,
      deliveryMode: order.deliveryMode, // audit only: amounts never depend on it
      commission: {
        termsId: alloc.commissionTermsId, termsVersion: alloc.commissionTermsVersion, rateBps: alloc.commissionRateBps,
        termsReference: alloc.commissionTermsReference, rounding: alloc.commissionRounding, base: alloc.commissionBase,
      },
    };
    const common = {
      orderId, currency: "GHS", businessDate: businessDate(order.deliveredAt.toMillis()),
      deliveredAt: order.deliveredAt, basis, postedBy, postedAt: FieldValue.serverTimestamp(),
    };
    tx.create(refs.supplier, { ...common, entryId: refs.supplier.id, kind: "entitlement", party: "supplier", partyId: order.supplierId, amountPesewas: alloc.supplierNetPesewas });
    const deliveryBasis = order.deliveryMode === "linked_rider" ? { ...basis, linkedSupplierId: order.linkedSupplierId } : basis;
    tx.create(refs.delivery, { ...common, basis: deliveryBasis, entryId: refs.delivery.id, kind: delivery.kind, party: delivery.party, partyId: delivery.partyId, amountPesewas: alloc.driverNetPesewas });
    tx.create(refs.platform, { ...common, entryId: refs.platform.id, kind: "commission", party: "platform", partyId: PLATFORM_ID, amountPesewas: alloc.commissionPesewas });
    tx.update(allocRef, {
      "settlement.status": "accrued", "settlement.reconciliation": "balanced", "settlement.reconciliationReason": null,
      "settlement.postedAt": FieldValue.serverTimestamp(), "settlement.postedBy": postedBy,
    });
    const split = Object.fromEntries(ALLOCATION_AMOUNTS.map((k) => [k, alloc[k]]));
    return { posted: true, allocation: split };
  });
}

/**
 * Appends reversal entries negating every posted entry of an order. The
 * originals are untouched. Allowed when the order's escrow was refunded, or
 * by a super admin with a reason. Idempotent. Moves no money: it does not
 * refund the customer.
 *
 * An original that no statement has claimed is claimed later together with
 * its reversal (they net to zero). An original already claimed (F3, spec
 * §3.6) gets, in the same transaction, a held claim for its reversal (a
 * debtId and no statementId, so no statement ever nets it), an outstanding
 * debt (gas_settlement_debts/{reversalId}) and a high alert. The debt waits
 * for an explicit resolution (resolveSettlementDebt); nothing deducts it
 * from later earnings, a wallet or drivers.commissionOwed. A debt of zero is
 * created already resolved (nothing_owed, by "system", audited, no alert),
 * so it never blocks its statement's payout.
 */
async function reverseOrderEntitlements(orderId, { reason, actor = null }) {
  if (typeof reason !== "string" || reason.trim().length < 3) {
    throw new HttpsError("invalid-argument", "A reason is required.", { reason: "reason_required" });
  }
  const origRefs = ORIGINAL_KINDS.map(([p, k]) => db().collection(LEDGER).doc(entryId(orderId, p, k)));
  const revRefs = ORIGINAL_KINDS.map(([, , slot]) => db().collection(LEDGER).doc(entryId(orderId, slot, "reversal")));
  const claimRefs = origRefs.map((r) => db().collection(CLAIMS).doc(r.id));
  const allocRef = allocationRef(orderId);
  return db().runTransaction(async (tx) => {
    const [origs, revs, claims, alloc] = await Promise.all([
      Promise.all(origRefs.map((r) => tx.get(r))), Promise.all(revRefs.map((r) => tx.get(r))),
      Promise.all(claimRefs.map((r) => tx.get(r))), tx.get(allocRef),
    ]);
    if (!origs.some((s) => s.exists)) throw new HttpsError("failed-precondition", "Nothing posted for this order.", { reason: "nothing_posted" });
    if (revs.every((s, i) => s.exists || !origs[i].exists)) return { alreadyReversed: true };
    if (!actor) {
      // Without an admin, only a refunded payment justifies a reversal.
      const escrowId = origs.find((s) => s.exists).data().basis.escrowId;
      const e = await tx.get(db().collection("escrows").doc(escrowId));
      if (!e.exists || e.data().status !== "REFUNDED") {
        throw new HttpsError("failed-precondition", "The payment was not refunded.", { reason: "payment_not_refunded" });
      }
    }
    // The statements that claimed originals (all reads before any write).
    const statementIds = [...new Set(claims.filter((c) => c.exists && c.data().statementId).map((c) => c.data().statementId))];
    const statements = new Map(await Promise.all(statementIds.map(async (id) => {
      const st = await tx.get(db().collection(STATEMENTS).doc(id));
      return [id, st.exists ? st.data() : null];
    })));
    const now = Date.now();
    const debts = [];
    origs.forEach((o, i) => {
      if (!o.exists || revs[i].exists) return;
      const e = o.data();
      const revId = revRefs[i].id;
      tx.create(revRefs[i], {
        entryId: revId, orderId, kind: "reversal", reversesEntryId: o.id, party: e.party, partyId: e.partyId,
        amountPesewas: 0 - e.amountPesewas /* 0, never -0 */, currency: e.currency, businessDate: businessDate(now), basis: e.basis,
        reason: reason.trim(), postedBy: actor?.uid ?? "system", postedAt: FieldValue.serverTimestamp(),
      });
      if (!claims[i].exists) return; // not settled yet: claimed with its original later
      const statementId = claims[i].data().statementId ?? null;
      const stage = debtStage(statementId ? statements.get(statementId) : null);
      const amountPesewas = Math.abs(e.amountPesewas);
      tx.create(db().collection(CLAIMS).doc(revId), { entryId: revId, debtId: revId, claimedAt: FieldValue.serverTimestamp() });
      const debt = {
        debtId: revId, party: e.party, partyId: e.partyId, orderId, reversalEntryId: revId, originalEntryId: o.id, statementId,
        amountPesewas, currency: e.currency, stage, status: "outstanding", reversalReason: reason.trim(),
        reversedBy: actor?.uid ?? "system", version: 1, createdAt: FieldValue.serverTimestamp(),
      };
      if (amountPesewas === 0) {
        // Nothing is owed: recorded and audited, resolved at once, so it never blocks the statement.
        tx.create(db().collection(DEBTS).doc(revId), {
          ...debt, status: "resolved", resolution: "nothing_owed", reason: "Reversal of a zero amount", evidence: null,
          resolvedBy: "system", resolvedByEmail: null, resolvedAt: FieldValue.serverTimestamp(),
        });
        tx.set(db().collection("audit_log").doc(), {
          action: "gas_settlement_debt_resolved", step: "system", debtId: revId, orderId, party: e.party, partyId: e.partyId,
          statementId, stage, amountPesewas: 0, resolution: "nothing_owed", reason: "Reversal of a zero amount",
          adminUid: null, adminEmail: null, version: 1, createdAt: FieldValue.serverTimestamp(),
        });
        debts.push(revId);
        return;
      }
      tx.create(db().collection(DEBTS).doc(revId), debt);
      tx.create(db().collection("admin_alerts").doc(`gas_settlement_debt_${revId}`), adminAlert("gas_settlement_debt",
        `Gas supplier order ${orderId}: a settled ${e.party} entry was reversed; an outstanding debt needs a resolution`,
        { severity: "high", resolved: false, debtId: revId, orderId, party: e.party, partyId: e.partyId, statementId, stage, amountPesewas }));
      debts.push(revId);
    });
    if (alloc.exists) {
      tx.update(allocRef, { "settlement.status": "reversed", "settlement.reversedAt": FieldValue.serverTimestamp(), "settlement.reversalReason": reason.trim() });
    }
    return debts.length ? { reversed: true, debts } : { reversed: true };
  });
}

// ── Daily statements ─────────────────────────────────────────────────────────

/**
 * Prepares one statement per supplier and driver for a closed business day,
 * from entries up to and including that day that are eligible and not yet
 * claimed (earlier leftovers carry forward). Each entry is claimed exactly
 * once (gas_settlement_claims/{entryId}, created with the statement), so a
 * rerun or a concurrent run cannot include an entry twice. Orders whose
 * entries do not reconcile with their snapshot and captured payment are
 * left out and reported. Prepares only: no payout is made.
 *
 * A reversal is claimed only together with its original, so they net to
 * zero (F3): an original whose reversal exists but is not in this batch
 * waits for the next run, and a reversal whose original another statement
 * already claimed is left out and alerted (reverseOrderEntitlements makes
 * it a debt; one without a debt should not exist). A statement never nets
 * below zero: such a party is left out and alerted
 * (gas_settlement_negative_statement).
 */
async function prepareStatements(date, { now = Date.now(), preparedBy = "system" } = {}) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || businessDate(Date.parse(`${date}T00:00:00Z`)) !== date) {
    throw new HttpsError("invalid-argument", "Invalid business date.", { reason: "invalid_date" });
  }
  if (date >= businessDate(now)) throw new HttpsError("failed-precondition", "That day is not closed yet.", { reason: "day_not_closed" });

  const termsSnap = await db().doc(TERMS_DOC).get();
  const holdHours = termsSnap.exists ? termsSnap.data().settlementHoldHours : undefined;

  const entries = (await db().collection(LEDGER).where("businessDate", "<=", date).get()).docs.map((d) => d.data());
  const byOrder = new Map();
  for (const e of entries) byOrder.set(e.orderId, [...(byOrder.get(e.orderId) ?? []), e]);

  const exceptions = [];
  const candidates = [];
  for (const [orderId, list] of byOrder) {
    const originals = list.filter((e) => e.kind !== "reversal");
    const reversals = list.filter((e) => e.kind === "reversal");
    const escrowId = list[0].basis?.escrowId;
    const [order, escrow, allocation] = await Promise.all([
      db().collection(ORDERS).doc(orderId).get(), escrowId ? db().collection("escrows").doc(escrowId).get() : null,
      allocationRef(orderId).get(),
    ]);
    const o = order.exists ? order.data() : null;
    const e = escrow?.exists ? escrow.data() : null;
    const a = allocation.exists ? allocation.data() : null;
    const why = reconciliationProblem(list, o, e, a);
    if (why) {
      exceptions.push({ orderId, reason: "does_not_reconcile", detail: why });
      if (a) await allocation.ref.update({ "settlement.reconciliation": "does_not_reconcile", "settlement.reconciliationReason": why });
      continue;
    }
    const reversedIds = new Set(reversals.map((r) => r.reversesEntryId));
    for (const x of list) {
      if (!PAYOUT_PARTIES.includes(x.party)) continue;
      const status = entryStatus(x, {
        reversed: reversedIds.has(x.entryId), claim: null, escrow: e,
        deliveredAtMs: o.deliveredAt?.toMillis?.(), holdHours, now,
      });
      // A reversed, never-settled entitlement is claimed with its reversal (they net to zero).
      if (status === "eligible" || status === "reversed") candidates.push(x);
    }
  }

  const groups = new Map();
  for (const x of candidates) {
    const key = `${x.party}__${x.partyId}`;
    groups.set(key, [...(groups.get(key) ?? []), x]);
  }

  const prepared = [];
  const flagged = [];
  for (const [key, lines] of groups) {
    const [party, partyId] = key.split("__");
    const ref = db().collection(STATEMENTS).doc(`${date}__${party}__${partyId}`);
    const result = await db().runTransaction(async (tx) => {
      if ((await tx.get(ref)).exists) return { skipped: "statement_exists" };
      const batch = lines.slice(0, MAX_LINES_PER_STATEMENT);
      const ids = new Set(batch.map((x) => x.entryId));
      const claimRefs = batch.map((x) => db().collection(CLAIMS).doc(x.entryId));
      // Read inside the transaction, so a reversal or claim made since the query is seen.
      const pairRefs = batch.map((x) => (x.kind === "reversal"
        ? db().collection(CLAIMS).doc(x.reversesEntryId) // the original's claim
        : db().collection(LEDGER).doc(reversalIdOf(x) ?? `${x.entryId}__none`))); // the original's reversal
      const [claims, pairs] = await Promise.all([Promise.all(claimRefs.map((r) => tx.get(r))), Promise.all(pairRefs.map((r) => tx.get(r)))]);
      const settledReversalIds = [];
      const free = batch.filter((x, i) => {
        if (claims[i].exists) return false;
        if (x.kind === "reversal") {
          if (pairs[i].exists) settledReversalIds.push(x.entryId); // its original is settled: never netted against later earnings
          return !pairs[i].exists && ids.has(x.reversesEntryId);
        }
        return !pairs[i].exists || ids.has(pairs[i].id); // a reversed original only with its reversal
      });
      // A pair is claimed together or not at all.
      const freeIds = new Set(free.map((x) => x.entryId));
      const paired = free.filter((x) => (x.kind === "reversal" ? freeIds.has(x.reversesEntryId) : !ids.has(reversalIdOf(x)) || freeIds.has(reversalIdOf(x))));
      if (!paired.length) return { skipped: "nothing_unclaimed", settledReversalIds };
      const net = paired.reduce((s, x) => s + x.amountPesewas, 0);
      if (net < 0) return { skipped: "negative_net", netPesewas: net, settledReversalIds };
      const statement = {
        statementId: ref.id, businessDate: date, party, partyId, currency: "GHS",
        lines: paired.map((x) => ({ entryId: x.entryId, orderId: x.orderId, kind: x.kind, amountPesewas: x.amountPesewas })),
        creditsPesewas: paired.filter((x) => x.amountPesewas > 0).reduce((s, x) => s + x.amountPesewas, 0),
        debitsPesewas: paired.filter((x) => x.amountPesewas < 0).reduce((s, x) => s + x.amountPesewas, 0),
        netPesewas: net,
        status: statementStatus(net),
        payoutStatus: "not_started",
        payoutMethod: null, // set when paid out (gas_supplier_payouts.js)
        preparedBy, preparedAt: FieldValue.serverTimestamp(),
      };
      tx.create(ref, statement);
      for (const x of paired) tx.create(db().collection(CLAIMS).doc(x.entryId), { entryId: x.entryId, statementId: ref.id, claimedAt: FieldValue.serverTimestamp() });
      return { statementId: ref.id, lines: paired.length, netPesewas: net, settledReversalIds };
    });
    const { settledReversalIds = [], ...outcome } = result;
    if (outcome.skipped === "negative_net" || settledReversalIds.length) flagged.push({ party, partyId, outcome, settledReversalIds });
    prepared.push({ key, ...outcome });
  }
  for (const f of flagged) {
    try {
      await db().collection("admin_alerts").doc(`gas_settlement_negative_statement_${date}__${f.party}__${f.partyId}`).create(adminAlert(
        "gas_settlement_negative_statement",
        f.outcome.skipped === "negative_net"
          ? `Gas ${f.party} ${f.partyId}: the ${date} statement would net below zero and was not prepared`
          : `Gas ${f.party} ${f.partyId}: reversal(s) of settled entries without a debt were left out of the ${date} statement`,
        { severity: "high", resolved: false,
          details: { businessDate: date, party: f.party, partyId: f.partyId, reason: f.outcome.skipped === "negative_net" ? "negative_net" : "reversal_of_settled_entry",
            netPesewas: f.outcome.netPesewas ?? null, settledReversalIds: f.settledReversalIds.slice(0, 50) } }));
    } catch (e) {
      if (e?.code !== 6) throw e; // 6: already alerted for this day and party
    }
  }
  if (exceptions.length) {
    await db().collection("admin_alerts").add(adminAlert("gas_settlement_exceptions",
      `${exceptions.length} Gas supplier order(s) left out of ${date} statements: entries do not reconcile`,
      { severity: "high", resolved: false, details: { businessDate: date, exceptions: exceptions.slice(0, 50) } }));
  }
  return { businessDate: date, statements: prepared, exceptions };
}

// ── Settlement debts (F3) ────────────────────────────────────────────────────

/**
 * Applies one step of a debt's resolution, in one transaction that
 * requires the debt's current `version` (R2, spec §3.6):
 *   resolve   before_payout only: withhold (from the claiming statement's
 *             payable amount; its net and lines are never edited) or
 *             pay_in_full (CTSGo absorbs it). One super admin.
 *   propose   after_payout only: written_off or recovered_externally, with
 *             evidence. Nothing is resolved until a different super admin
 *             decides it:
 *   approve   the debt is resolved as proposed;
 *   reject    the debt is outstanding again, and the proposal is kept in
 *             rejectedProposals.
 * The stage is re-derived from the claiming statement inside the
 * transaction, so a payout that started since the debt was created moves it
 * to the after-payout route. While that statement's payout is in progress
 * (sent or unknown, not yet confirmed), propose and approve are refused
 * (debt_payout_unconfirmed): a confirmed failure makes the debt before-payout
 * again, to be withheld or paid in full before a retry. Reject stays allowed.
 * Every step writes one audit_log entry,
 * gas_settlement_debt_resolved; a final resolution (resolve or approve) also
 * marks the debt's alert resolved. Nothing here deducts from later
 * entitlements, a wallet or drivers.commissionOwed (R3).
 */
async function resolveSettlementDebt(actor, data) {
  const { debtId, action, resolution, reason, evidence, expectedVersion } =
    readRequest(data, ["debtId", "action", "resolution", "reason", "evidence", "expectedVersion"]);
  const refuse = (reason, message, code = "failed-precondition") => new HttpsError(code, message, { reason });
  if (!isId(debtId) || !DEBT_ACTIONS.includes(action) || !Number.isInteger(expectedVersion) || expectedVersion < 1) {
    throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  }
  if (!(typeof reason === "string" && reason.trim().length >= 3 && reason.length <= 500)) {
    throw refuse("reason_required", "A reason is required.", "invalid-argument");
  }
  if (resolution != null && typeof resolution !== "string") throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  if (evidence != null && !(typeof evidence === "string" && evidence.length <= 500)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const ref = db().collection(DEBTS).doc(debtId);
  return db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw refuse("debt_not_found", "Debt not found.", "not-found");
    const d = snap.data();
    if (d.status === "resolved") throw refuse("debt_resolved", "This debt is already resolved.");
    if (d.version !== expectedVersion) throw refuse("debt_changed", "This debt has changed; reload it.");
    const stRef = d.statementId ? db().collection(STATEMENTS).doc(d.statementId) : null;
    const stSnap = stRef ? await tx.get(stRef) : null;
    const statement = stSnap?.exists ? stSnap.data() : null;
    const alertRef = db().collection("admin_alerts").doc(`gas_settlement_debt_${debtId}`);
    const alertSnap = await tx.get(alertRef);
    // A payout Bridge has not confirmed may still fail and be retried: no after-payout decision until it is settled.
    if ((action === "propose" || action === "approve") && statement?.payoutStatus === "payout_in_progress") {
      throw refuse("debt_payout_unconfirmed", "The statement's payout is not confirmed yet; record its result first.");
    }
    const stage = debtStage(statement);
    const version = d.version + 1;
    const by = { uid: actor.uid, email: actor.email ?? null };
    const auditRow = (step, applied) => tx.set(db().collection("audit_log").doc(), {
      action: "gas_settlement_debt_resolved", step, debtId, orderId: d.orderId, party: d.party, partyId: d.partyId,
      statementId: d.statementId, stage, amountPesewas: d.amountPesewas, resolution: applied ?? null, reason: reason.trim(),
      adminUid: by.uid, adminEmail: by.email, version, createdAt: FieldValue.serverTimestamp(),
    });
    // The debt's alert closes with it (only a final resolution, never a proposal or rejection).
    const resolveAlert = () => {
      if (alertSnap.exists) tx.update(alertRef, { resolved: true, resolvedAt: FieldValue.serverTimestamp(), resolvedBy: by.uid });
    };

    if (action === "approve" || action === "reject") {
      if (d.status !== "resolution_proposed" || !d.proposal) throw refuse("no_proposal", "There is no proposed resolution to decide.");
      if (d.proposal.by === by.uid) throw refuse("proposer_cannot_approve", "A different super admin must decide this proposal.", "permission-denied");
      if (resolution != null && resolution !== d.proposal.resolution) throw refuse("resolution_not_allowed", "That is not the proposed resolution.");
      if (action === "reject") {
        tx.update(ref, {
          status: "outstanding", proposal: FieldValue.delete(), version,
          rejectedProposals: FieldValue.arrayUnion({ ...d.proposal, rejectedBy: by.uid, rejectedByEmail: by.email, rejectReason: reason.trim(), rejectedAt: Timestamp.now() }),
        });
        auditRow("reject", d.proposal.resolution);
        return { debtId, status: "outstanding", version };
      }
      if (!DEBT_RESOLUTIONS[stage].resolutions.includes(d.proposal.resolution) || DEBT_RESOLUTIONS[stage].action !== "propose") {
        throw refuse("resolution_not_allowed", "That resolution is not allowed at this stage.");
      }
      tx.update(ref, {
        status: "resolved", resolution: d.proposal.resolution, reason: d.proposal.reason, evidence: d.proposal.evidence,
        resolvedBy: d.proposal.by, approvedBy: by.uid, approvedByEmail: by.email, approvalReason: reason.trim(),
        resolvedAt: FieldValue.serverTimestamp(), stage, version,
      });
      resolveAlert();
      auditRow("approve", d.proposal.resolution);
      return { debtId, status: "resolved", resolution: d.proposal.resolution, version };
    }

    if (d.status !== "outstanding") throw refuse("debt_not_outstanding", "This debt already has a proposed resolution.");
    const allowed = DEBT_RESOLUTIONS[stage];
    if (allowed.action !== action || !allowed.resolutions.includes(resolution)) {
      // A withhold or pay-in-full asked for after the payout started: the debt moved stage.
      if (action === "resolve" && d.stage === "before_payout" && DEBT_RESOLUTIONS.before_payout.resolutions.includes(resolution)) {
        throw refuse("debt_stage_changed", "The statement's payout has started; this debt needs the after-payout route.");
      }
      throw refuse("resolution_not_allowed", "That resolution is not allowed at this stage.");
    }
    const ev = typeof evidence === "string" ? evidence.trim() : "";
    if (action === "propose") {
      if (ev.length < 6) throw refuse("evidence_required", "Evidence is required.", "invalid-argument");
      tx.update(ref, {
        status: "resolution_proposed", stage, version,
        proposal: { resolution, by: by.uid, byEmail: by.email, reason: reason.trim(), evidence: ev, at: Timestamp.now() },
      });
      auditRow("propose", resolution);
      return { debtId, status: "resolution_proposed", resolution, version };
    }
    if (resolution === "withhold") {
      const withheld = (statement.withheldPesewas ?? 0) + d.amountPesewas;
      if (withheld > statement.netPesewas) throw refuse("withhold_exceeds_net", "The statement cannot cover this amount.");
      tx.update(stRef, {
        withheldPesewas: withheld, payablePesewas: statement.netPesewas - withheld, withheldDebtIds: FieldValue.arrayUnion(debtId),
      });
    }
    tx.update(ref, {
      status: "resolved", resolution, reason: reason.trim(), evidence: ev || null, resolvedBy: by.uid, resolvedByEmail: by.email,
      resolvedAt: FieldValue.serverTimestamp(), stage, version,
    });
    resolveAlert();
    auditRow("resolve", resolution);
    return { debtId, status: "resolved", resolution, version };
  });
}

// ── Commission terms ─────────────────────────────────────────────────────────

/**
 * Records a proposed terms version (gas_commission_terms/v{n}, n = the
 * highest existing version + 1). The rate, reference and hold period come
 * from the proposing super admin; nothing is assumed. A proposal changes
 * nothing until a different super admin approves it.
 */
async function proposeTerms(actor, data) {
  const { rateBps, termsReference, settlementHoldHours } = readRequest(data, ["rateBps", "termsReference", "settlementHoldHours"]);
  if (!Number.isInteger(rateBps) || rateBps < 0 || rateBps > 10000) {
    throw new HttpsError("invalid-argument", "The rate must be whole basis points from 0 to 10000.", { reason: "commission_rate_invalid" });
  }
  if (typeof termsReference !== "string" || termsReference.trim().length < 3 || termsReference.length > 200) {
    throw new HttpsError("invalid-argument", "A terms reference is required.", { reason: "commission_terms_unreferenced" });
  }
  if (!(typeof settlementHoldHours === "number" && Number.isFinite(settlementHoldHours) && settlementHoldHours >= 0 && settlementHoldHours <= 720)) {
    throw new HttpsError("invalid-argument", "The settlement hold must be 0 to 720 hours.", { reason: "settlement_hold_undefined" });
  }
  return db().runTransaction(async (tx) => {
    const all = await tx.get(db().collection(TERMS));
    const highest = all.docs.reduce((m, d) => (Number.isInteger(d.data().version) ? Math.max(m, d.data().version) : m), 0);
    const version = highest + 1;
    const ref = db().collection(TERMS).doc(termsVersionId(version));
    tx.create(ref, {
      termsId: ref.id, version, rateBps, termsReference: termsReference.trim(), settlementHoldHours, currency: "GHS",
      commissionBase: COMMISSION_BASE, handlingFeeCommissionable: false, deliveryFeeCommissionable: false,
      status: "proposed", proposedBy: actor.uid, proposedByEmail: actor.email, proposedAt: FieldValue.serverTimestamp(),
    });
    return { termsId: ref.id, version, status: "proposed" };
  });
}

/**
 * Approves or rejects a proposed version. Approval needs a super admin
 * other than the proposer, and a version newer than the current one; it
 * makes the version `current` (active) and marks the previous one
 * superseded. Orders already created keep the terms they were created under.
 */
async function decideTerms(actor, data) {
  const { termsId, decision, reason } = readRequest(data, ["termsId", "decision", "reason"]);
  if (typeof termsId !== "string" || !TERMS_VERSION_ID.test(termsId) || !["approve", "reject"].includes(decision)) {
    throw new HttpsError("invalid-argument", "Invalid request.", { reason: "invalid_request" });
  }
  if (decision === "reject" && !(typeof reason === "string" && reason.trim().length >= 3 && reason.length <= 500)) {
    throw new HttpsError("invalid-argument", "A reason is required.", { reason: "reason_required" });
  }
  const ref = db().collection(TERMS).doc(termsId);
  const currentRef = db().doc(TERMS_DOC);
  return db().runTransaction(async (tx) => {
    const [v, cur] = await Promise.all([tx.get(ref), tx.get(currentRef)]);
    if (!v.exists) throw new HttpsError("not-found", "Terms version not found.", { reason: "terms_not_found" });
    const t = v.data();
    const done = decision === "approve" ? "approved" : "rejected";
    if (t.status === done && t[`${done}By`] === actor.uid) return { termsId, status: done, alreadyDecided: true };
    if (t.status !== "proposed") throw new HttpsError("failed-precondition", "This version is not awaiting a decision.", { reason: "terms_not_proposed" });

    if (decision === "reject") {
      tx.update(ref, { status: "rejected", rejectedBy: actor.uid, rejectedByEmail: actor.email, rejectedAt: FieldValue.serverTimestamp(), rejectReason: reason.trim() });
      return { termsId, status: "rejected" };
    }
    if (t.proposedBy === actor.uid) {
      throw new HttpsError("permission-denied", "Terms must be approved by a different super admin.", { reason: "approver_is_proposer" });
    }
    const previous = cur.exists ? cur.data() : null;
    if (previous && Number.isInteger(previous.version) && previous.version >= t.version) {
      throw new HttpsError("failed-precondition", "Newer terms are already current.", { reason: "newer_terms_current" });
    }
    const prevRef = previous && TERMS_VERSION_ID.test(String(previous.termsId)) ? db().collection(TERMS).doc(previous.termsId) : null;
    const prev = prevRef ? await tx.get(prevRef) : null;
    const current = {
      termsId, version: t.version, rateBps: t.rateBps, termsReference: t.termsReference, settlementHoldHours: t.settlementHoldHours,
      currency: "GHS", commissionBase: t.commissionBase, handlingFeeCommissionable: t.handlingFeeCommissionable,
      deliveryFeeCommissionable: t.deliveryFeeCommissionable, proposedBy: t.proposedBy, approvedBy: actor.uid, active: true,
    };
    const problem = termsProblem(current);
    if (problem) throw new HttpsError("failed-precondition", "These terms cannot be used.", { reason: problem });
    tx.update(ref, { status: "approved", approvedBy: actor.uid, approvedByEmail: actor.email, approvedAt: FieldValue.serverTimestamp() });
    if (prev?.exists && prev.data().status === "approved") {
      tx.update(prevRef, { status: "superseded", supersededBy: termsId, supersededAt: FieldValue.serverTimestamp() });
    }
    tx.set(currentRef, { ...current, approvedByEmail: actor.email, approvedAt: FieldValue.serverTimestamp() });
    return { termsId, status: "approved" };
  });
}

// ── Super-admin callables (no trigger or schedule calls this module) ─────────

const OPTS = { region: "europe-west2", minInstances: 0 };

exports.adminPostGasSupplierEntitlements = onCall(OPTS, async (request) => {
  const actor = await requireSuperAdmin(request);
  const { orderId } = readRequest(request.data, ["orderId"]);
  if (!isId(orderId)) throw new HttpsError("invalid-argument", "Invalid order.", { reason: "invalid_order" });
  return postOrderEntitlements(orderId, { postedBy: actor.uid });
});

exports.adminReverseGasSupplierEntitlements = onCall(OPTS, async (request) => {
  const actor = await requireSuperAdmin(request);
  const { orderId, reason } = readRequest(request.data, ["orderId", "reason"]);
  if (!isId(orderId)) throw new HttpsError("invalid-argument", "Invalid order.", { reason: "invalid_order" });
  return reverseOrderEntitlements(orderId, { reason, actor });
});

exports.adminResolveGasSettlementDebt = onCall(OPTS, async (request) => {
  const actor = await requireSuperAdmin(request);
  return resolveSettlementDebt(actor, request.data);
});

exports.adminProposeGasCommissionTerms = onCall(OPTS, async (request) => {
  const actor = await requireSuperAdmin(request);
  return proposeTerms(actor, request.data);
});

exports.adminDecideGasCommissionTerms = onCall(OPTS, async (request) => {
  const actor = await requireSuperAdmin(request);
  return decideTerms(actor, request.data);
});

exports.adminPrepareGasSettlementStatements = onCall(OPTS, async (request) => {
  const actor = await requireSuperAdmin(request);
  const { businessDate: date } = readRequest(request.data, ["businessDate"]);
  return prepareStatements(date, { preparedBy: actor.uid });
});

Object.assign(exports, {
  LEDGER, CLAIMS, STATEMENTS, DEBTS, DELIVERY_MODES, DEBT_RESOLUTIONS, TERMS_DOC, ESCROW_REFERENCE_TYPE, ESCROW_CAPTURED, PARTIES, PLATFORM_ID,
  TERMS, FINANCE, ALLOCATION_ID, COMMISSION_BASE, ALLOCATION_VERSION, ALLOCATION_AMOUNTS,
  toPesewas, termsProblem, termsVersionId, allocate, computeAllocation, allocationProblem, allocationTermsProblem,
  reconciliationProblem, allocationRef, proposeTerms, decideTerms, postingProblem, businessDate, entryId, entryStatus, statementStatus,
  postOrderEntitlements, reverseOrderEntitlements, prepareStatements, requireSuperAdmin, deliverySlot,
  debtStage, resolveSettlementDebt,
});
