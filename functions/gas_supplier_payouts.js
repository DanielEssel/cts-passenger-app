"use strict";

/**
 * Gas supplier settlement payouts: turning a prepared daily statement
 * (gas_settlement_ledger.js) into money.
 *
 *   supplier statement  Mobile Money to the supplier's payoutPreference
 *                       (MTN MoMo, Telecel Cash, AT Money) through The Bridge
 *                       Solutions, as driver withdrawals are paid
 *                       (withdrawal_approval.js)
 *   driver statement    credited to the driver's CTSGo wallet
 *                       (drivers.walletBalance), where every other driver
 *                       earning goes; drivers withdraw it as usual
 *
 * Supplier Mobile Money payouts are off unless settings/gas_supplier_payouts
 * .enabled === true, read at call time (a missing document means off; only
 * super admins may change it, firestore.rules). Recording an outcome is never
 * gated, so switching off cannot strand a payout already in progress.
 * Driver statements are not behind that switch: crediting the driver's
 * CTSGo wallet moves no money out of CTSGo, and stays a super admin's manual,
 * exactly-once action. Withdrawing it is the separate driver-withdrawal flow.
 *
 * A supplier payout is one attempt at a time on the statement itself:
 *   not_started|failed --approve (super admin)--> payout_in_progress/sending
 *     then exactly one of, applied in a transaction that re-checks the attempt:
 *       not_sent  nothing left the platform        -> back to the previous status
 *       sent      Bridge accepted ("000"/"202")     -> payout_in_progress/sent
 *       refused   Bridge refused ("001"/"003")      -> failed (may be approved again)
 *       unknown   anything else after the request   -> payout_in_progress/unknown + alert
 *   payout_in_progress/sent|unknown --resolve (super admin, Bridge evidence)--> paid | failed
 * "paid" is recorded only by a super admin who confirmed it with Bridge and
 * records the evidence: Bridge callbacks are not authenticated
 * (bridge.js verifyBridgeCallback) and Bridge has no known status API, so no
 * response or callback ever marks a payout paid by itself. A payout whose
 * request may have reached Bridge is never re-sent.
 *
 * Before any credit or payout, in the same transaction that claims it, the
 * server reconciles the statement (statementReconciliationProblem): it has
 * lines, they add up to netPesewas, and every line's claim
 * (gas_settlement_claims) names this statement. No debt on it may be
 * outstanding or awaiting approval (gas_settlement_debts, spec §3.6). The
 * amount credited or sent is payableOf(statement): netPesewas less what a
 * debt resolution withheld. A payable of zero is marked "not_required" and
 * moves nothing. A driver credit is stored as payoutStatus "paid" with
 * payoutMethod "driver_wallet", and readers show it as credited_to_wallet,
 * never as a payout; it writes no payments record.
 *
 * Statements are prepared every day for the previous business day
 * (prepareDailyGasSettlementStatements), or by hand with
 * adminPrepareGasSettlementStatements; each payout still needs a super
 * admin's approval.
 */

const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const axios = require("axios");
const { BRIDGE_CLIENT_KEY, BRIDGE_SECRET_KEY, BRIDGE_SERVICE_ID, resolveBridgeTarget, getBridgeHeaders } = require("./bridge")._bridgeShared;
const { classifyBridgeResponse, BRIDGE_TIMEOUT_MS, STALE_SENDING_MS } = require("./withdrawal_approval")._payoutShared;
const { prepareStatements, requireSuperAdmin, CLAIMS, DEBTS } = require("./gas_settlement_ledger");
const { adminAlert } = require("./alert_payload");

const db = () => admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const STATEMENTS = "gas_settlement_statements";
const PAYOUT_FLAG_DOC = "settings/gas_supplier_payouts";
/** payoutPreference.method (firestore.rules payoutPreferenceOk) → Bridge network code (bridge.js NETWORK_MAP). */
const BRIDGE_NETWORK = Object.freeze({ mtn_momo: "MTN", telecel_cash: "VOD", at_money: "AIR" });
const ID = /^[A-Za-z0-9_-]{1,200}$/;
/** Debt statuses that block a statement's credit or payout: not resolved, or a resolution not yet approved. */
const BLOCKING_DEBT_STATUSES = Object.freeze(["outstanding", "resolution_proposed"]);

const refuse = (reason, message, code = "failed-precondition") => new HttpsError(code, message, { reason });

// ── Pure rules (exported for tests) ──────────────────────────────────────────

/** The supplier's Mobile Money details for Bridge, or null (as the rules' payoutPreferenceOk). */
function payoutDestination(supplier) {
  const p = supplier?.payoutPreference;
  if (!p || !BRIDGE_NETWORK[p.method]) return null;
  if (typeof p.accountNumber !== "string" || !/^0[0-9]{9}$/.test(p.accountNumber)) return null;
  if (typeof p.accountName !== "string" || p.accountName.trim().length < 2 || p.accountName.length > 100) return null;
  return {
    network: BRIDGE_NETWORK[p.method], method: p.method, accountName: p.accountName.trim(),
    phone: `233${p.accountNumber.slice(1)}`, maskedNumber: `${p.accountNumber.slice(0, 3)}****${p.accountNumber.slice(-3)}`,
  };
}

/**
 * Why this statement cannot be paid out now, or null. Pure. A driver
 * statement is credited only from not_started; a supplier one may be
 * approved again after a refusal or a confirmed failure. Whether its lines,
 * claims and debts allow it is statementReconciliationProblem, read in the
 * same transaction.
 */
function payoutProblem(statement, party) {
  if (!statement) return "statement_not_found";
  if (statement.party !== party) return "wrong_party";
  if (statement.status !== "prepared" || !(Number.isInteger(statement.netPesewas) && statement.netPesewas > 0)) return "nothing_to_pay";
  const allowed = party === "supplier" ? ["not_started", "failed"] : ["not_started"];
  if (!allowed.includes(statement.payoutStatus)) return `payout_${statement.payoutStatus}`;
  return null;
}

/** The amount to credit or send, in pesewas: net less anything withheld for a debt. Pure. */
function payableOf(statement) {
  return statement.payablePesewas ?? statement.netPesewas;
}

/**
 * Why this statement does not reconcile with its claims, or null. Pure.
 * claimsById holds gas_settlement_claims/{entryId} for each line (missing
 * when there is none). The payable amount must be net less what was
 * withheld, and never below zero.
 */
function statementReconciliationProblem(statement, claimsById) {
  const lines = Array.isArray(statement?.lines) ? statement.lines : [];
  if (!lines.length || new Set(lines.map((l) => l?.entryId)).size !== lines.length) return "statement_lines_mismatch";
  if (lines.some((l) => typeof l?.entryId !== "string" || !Number.isInteger(l.amountPesewas))) return "statement_lines_mismatch";
  if (lines.reduce((sum, l) => sum + l.amountPesewas, 0) !== statement.netPesewas) return "statement_lines_mismatch";
  if (lines.some((l) => claimsById?.[l.entryId]?.statementId !== statement.statementId)) return "statement_claims_mismatch";
  const withheld = statement.withheldPesewas ?? 0;
  const payable = payableOf(statement);
  if (!Number.isInteger(withheld) || withheld < 0 || !Number.isInteger(payable) || payable < 0 || payable !== statement.netPesewas - withheld) {
    return "statement_payable_mismatch";
  }
  return null;
}

/**
 * Reads, inside [tx], what statementReconciliationProblem and the debt guard
 * need, and throws the first reason the statement cannot move money. All
 * reads; the caller writes afterwards.
 */
async function requireReconciled(tx, statementId, s) {
  const lines = Array.isArray(s.lines) ? s.lines : [];
  const claimSnaps = await Promise.all(lines.filter((l) => typeof l?.entryId === "string" && ID.test(l.entryId))
    .map((l) => tx.get(db().collection(CLAIMS).doc(l.entryId))));
  const claimsById = Object.fromEntries(claimSnaps.filter((c) => c.exists).map((c) => [c.id, c.data()]));
  const problem = statementReconciliationProblem({ ...s, statementId }, claimsById);
  if (problem) throw refuse(problem, "This statement does not reconcile with its ledger lines.");
  const debts = await tx.get(db().collection(DEBTS).where("statementId", "==", statementId).where("status", "in", BLOCKING_DEBT_STATUSES).limit(1));
  if (!debts.empty) throw refuse("statement_has_outstanding_debt", "A debt on this statement must be resolved first.");
}

/** Marks a statement whose payable amount is zero as needing no payout; nothing is credited or sent. */
function markNotRequired(tx, ref, s, actor, party) {
  const now = FieldValue.serverTimestamp();
  tx.update(ref, { payoutStatus: "not_required", notRequiredBy: actor.uid, notRequiredAt: now });
  audit(tx, "gas_settlement_payout_not_required", ref.id, actor,
    { party, partyId: s.partyId, netPesewas: s.netPesewas, withheldPesewas: s.withheldPesewas ?? 0, amountPesewas: 0 });
}

// ── Transport (replaced in tests; never reached while payouts are off) ───────

class NotSentError extends Error {}

async function bridgeTransport({ transactionId, amount, phone, network, name }) {
  let target, headers, serviceId;
  try {
    target = resolveBridgeTarget("bridgePayoutCallback"); // fails closed
    headers = getBridgeHeaders(BRIDGE_CLIENT_KEY.value(), BRIDGE_SECRET_KEY.value());
    serviceId = Number(BRIDGE_SERVICE_ID.value());
  } catch (e) {
    throw new NotSentError(e.message);
  }
  const requestTime = new Date().toISOString().replace("T", " ").split(".")[0];
  return axios.post(`${target.apiBase}/make_payment`, {
    service_id: serviceId, reference: name, customer_number: phone,
    transaction_id: transactionId, trans_type: "MTC",
    amount, nw: network, nickname: name,
    payment_option: "MOM", currency_code: "GHS", currency_val: amount,
    callback_url: target.callbackUrl, request_time: requestTime,
  }, { headers, timeout: BRIDGE_TIMEOUT_MS });
}

let transport = bridgeTransport;
function _setTransportForTests(fn) { transport = fn ?? bridgeTransport; }

// ── Supplier: Mobile Money ───────────────────────────────────────────────────

async function requirePayoutsEnabled() {
  const snap = await db().doc(PAYOUT_FLAG_DOC).get();
  if (!(snap.exists && snap.data().enabled === true)) {
    throw refuse("gas_supplier_payouts_disabled", "Supplier payouts are switched off.", "unavailable");
  }
}

function audit(tx, action, statementId, actor, extra = {}) {
  tx.set(db().collection("audit_log").doc(), {
    action, statementId, adminUid: actor?.uid ?? null, adminEmail: actor?.email ?? null, ...extra,
    createdAt: FieldValue.serverTimestamp(),
  });
}

/** Ends one attempt; true when applied, false when the attempt no longer owns the statement. */
async function finishAttempt(ref, attemptId, kind, actor, detail = {}) {
  const applied = await db().runTransaction(async (tx) => {
    const s = (await tx.get(ref)).data() ?? {};
    if (s.payoutStatus !== "payout_in_progress" || s.payout?.attemptId !== attemptId || s.payout?.outcome !== "sending") return false;
    const paymentRef = db().collection("payments").doc(s.payout.transactionId);
    const now = FieldValue.serverTimestamp();
    if (kind === "not_sent") {
      tx.update(ref, { payoutStatus: s.payout.previousStatus ?? "not_started", "payout.outcome": "not_sent", "payout.error": detail.error ?? null, "payout.updatedAt": now });
      tx.set(paymentRef, { status: "not_sent", updatedAt: now }, { merge: true });
    } else if (kind === "sent") {
      tx.update(ref, { "payout.outcome": "sent", "payout.bridgeCode": detail.code, "payout.updatedAt": now });
      tx.set(paymentRef, { status: "pending", bridgeCode: detail.code, updatedAt: now }, { merge: true });
    } else if (kind === "refused") {
      tx.update(ref, { payoutStatus: "failed", "payout.outcome": "refused", "payout.bridgeCode": detail.code, "payout.updatedAt": now });
      tx.set(paymentRef, { status: "failed", bridgeCode: detail.code, updatedAt: now }, { merge: true });
    } else {
      tx.update(ref, { "payout.outcome": "unknown", "payout.bridgeCode": detail.code ?? null, "payout.error": detail.error ?? null, "payout.updatedAt": now });
      tx.set(paymentRef, { status: "unconfirmed", bridgeCode: detail.code ?? null, failureReason: detail.error ?? null, updatedAt: now }, { merge: true });
      tx.set(db().collection("admin_alerts").doc(), adminAlert("gas_supplier_payout_unconfirmed",
        `Gas supplier payout for statement ${ref.id} is unconfirmed: check Bridge and record the result`,
        { severity: "high", resolved: false, statementId: ref.id,
          transactionId: s.payout.transactionId, amountPesewas: s.payout.amountPesewas ?? s.netPesewas }));
    }
    audit(tx, `gas_supplier_payout_${kind}`, ref.id, actor, { attemptId, transactionId: s.payout.transactionId, ...detail });
    return true;
  });
  if (!applied) {
    await db().collection("admin_alerts").add(adminAlert("gas_supplier_payout_attempt_superseded",
      `Gas supplier payout for statement ${ref.id}: a late ${kind} result for a superseded attempt was not applied`,
      { statementId: ref.id, attemptId, outcome: kind }));
  }
  return applied;
}

/**
 * Approves and sends one supplier statement's payout. At most one request
 * is ever sent per attempt: the claim (to payout_in_progress/sending) is a
 * transaction, so a repeated or concurrent approval stops there. The same
 * transaction reconciles the statement and refuses while a debt on it is
 * open; it sends payableOf(statement), or marks a payable of zero
 * not_required and sends nothing.
 */
async function approveSupplierPayout(actor, data) {
  const statementId = data?.statementId;
  if (typeof statementId !== "string" || !ID.test(statementId)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  await requirePayoutsEnabled();
  const ref = db().collection(STATEMENTS).doc(statementId);
  const attemptId = crypto.randomUUID();

  const claim = await db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const s = snap.exists ? snap.data() : null;
    const problem = payoutProblem(s, "supplier");
    if (problem) throw refuse(problem, "This statement cannot be paid out.");
    await requireReconciled(tx, statementId, s);
    const payable = payableOf(s);
    if (payable === 0) {
      markNotRequired(tx, ref, s, actor, "supplier");
      return null;
    }
    const supplierSnap = await tx.get(db().collection("gas_suppliers").doc(s.partyId));
    const supplier = supplierSnap.exists ? supplierSnap.data() : null;
    if (supplier?.status !== "approved") throw refuse("supplier_not_approved", "The supplier is not approved.");
    const dest = payoutDestination(supplier);
    if (!dest) throw refuse("payout_details_missing", "The supplier has no valid Mobile Money payout details.");

    const attempt = (s.payout?.attempt ?? 0) + 1;
    const transactionId = `CTS-GSP-${Date.now()}-${crypto.randomBytes(3).toString("hex").toUpperCase()}`;
    const amount = payable / 100;
    const name = (supplier.tradingName || supplier.legalName || "CTSGo supplier").slice(0, 60);
    const now = FieldValue.serverTimestamp();
    tx.update(ref, {
      payoutStatus: "payout_in_progress",
      payoutMethod: "mobile_money",
      payout: {
        attempt, attemptId, transactionId, outcome: "sending", previousStatus: s.payoutStatus,
        provider: "bridge", network: dest.network, method: dest.method, accountName: dest.accountName, maskedNumber: dest.maskedNumber,
        amountPesewas: payable, netPesewas: s.netPesewas, withheldPesewas: s.withheldPesewas ?? 0,
        approvedBy: actor.uid, approvedAt: now, sendingStartedAt: now, updatedAt: now,
      },
    });
    tx.create(db().collection("payments").doc(transactionId), {
      transactionId, type: "gas_supplier_payout", role: "gas_supplier", supplierId: s.partyId, statementId,
      userId: null, userName: name, phone: dest.phone, network: dest.network, amount, currency: "GHS",
      status: "sending", attemptId, createdAt: now, updatedAt: now,
    });
    audit(tx, "gas_supplier_payout_approved", statementId, actor, { attemptId, transactionId, amountPesewas: payable });
    return { transactionId, amount, phone: dest.phone, network: dest.network, name };
  });
  if (!claim) return { statementId, payoutStatus: "not_required" };

  let response;
  try {
    response = await transport(claim);
  } catch (e) {
    if (e instanceof NotSentError) {
      await finishAttempt(ref, attemptId, "not_sent", actor, { error: e.message });
      throw refuse("payout_not_sent", "The payout was not sent. It can be approved again.", "unavailable");
    }
    await finishAttempt(ref, attemptId, "unknown", actor, { error: e.message, httpStatus: e.response?.status ?? null });
    throw refuse("payout_outcome_unknown", "The payment service did not confirm this payout. Check it with Bridge; it must not be resent.", "unavailable");
  }
  const outcome = classifyBridgeResponse(response);
  const applied = await finishAttempt(ref, attemptId, outcome.kind, actor, { code: outcome.code });
  if (!applied) throw refuse("payout_attempt_superseded", "This payout attempt was already resolved.", "aborted");
  if (outcome.kind === "refused") throw refuse("payout_refused", `Bridge refused the payout (${outcome.code}). It can be approved again.`);
  if (outcome.kind === "unknown") throw refuse("payout_outcome_unknown", "The payment service did not confirm this payout. Check it with Bridge; it must not be resent.", "unavailable");
  return { statementId, payoutStatus: "payout_in_progress", outcome: "sent", transactionId: claim.transactionId };
}

/**
 * Records a supplier payout's result, confirmed by a super admin with Bridge
 * (a reference or ticket as evidence). Only "paid" here ever marks a
 * statement paid. Not gated by the payouts switch.
 */
async function resolveSupplierPayout(actor, data) {
  const { statementId, outcome } = data ?? {};
  const evidence = String(data?.evidence ?? "").trim().slice(0, 500);
  if (typeof statementId !== "string" || !ID.test(statementId)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  if (!["paid", "failed"].includes(outcome)) throw refuse("invalid_outcome", 'The outcome must be "paid" or "failed".', "invalid-argument");
  if (evidence.length < 6) throw refuse("evidence_required", "Record the evidence from Bridge (reference or ticket).", "invalid-argument");
  const ref = db().collection(STATEMENTS).doc(statementId);
  return db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const s = snap.exists ? snap.data() : null;
    if (!s || s.party !== "supplier") throw refuse("statement_not_found", "Statement not found.", "not-found");
    if (s.payoutStatus !== "payout_in_progress") throw refuse(`payout_${s.payoutStatus}`, "This payout is not waiting for a result.");
    const started = s.payout?.sendingStartedAt?.toMillis?.() ?? null;
    const staleSending = s.payout?.outcome === "sending" && started !== null && Date.now() - started > STALE_SENDING_MS;
    if (!["sent", "unknown"].includes(s.payout?.outcome) && !staleSending) {
      throw refuse("payout_sending", "A payout attempt is still in progress. Try again shortly.");
    }
    const now = FieldValue.serverTimestamp();
    const transactionId = s.payout.transactionId;
    tx.update(ref, {
      payoutStatus: outcome, "payout.outcome": outcome === "paid" ? "confirmed_paid" : "confirmed_failed",
      "payout.resolvedBy": actor.uid, "payout.resolvedAt": now, "payout.resolutionEvidence": evidence, "payout.updatedAt": now,
      ...(outcome === "paid" ? { paidAt: now } : {}),
    });
    tx.set(db().collection("payments").doc(transactionId), { status: outcome === "paid" ? "success" : "failed", resolvedBy: actor.uid, updatedAt: now }, { merge: true });
    if (outcome === "paid") {
      // One row per statement, never two (deterministic id).
      tx.create(db().collection("ledger").doc(`gas_supplier_payout_${statementId}`), {
        type: "PAYOUT", status: "COMPLETED", fromType: "gas_settlement", toType: "gas_supplier", toUserId: null,
        supplierId: s.partyId, amount: (s.payout.amountPesewas ?? s.netPesewas) / 100, currency: "GHS", platformFee: 0, driverNet: 0,
        referenceType: "gas_settlement_statement", referenceId: statementId, transactionId,
        idempotencyKey: `gas_supplier_payout_${statementId}`, resolvedBy: actor.uid, processedAt: now, createdAt: now,
      });
    }
    audit(tx, outcome === "paid" ? "gas_supplier_payout_confirmed" : "gas_supplier_payout_failed_confirmed", statementId, actor,
      { transactionId, evidence, previousOutcome: s.payout?.outcome ?? null });
    return { statementId, payoutStatus: outcome };
  });
}

// ── Driver: CTSGo wallet ─────────────────────────────────────────────────────

/**
 * Credits a driver statement's payable amount to the driver's wallet, once:
 * the statement moves to "paid" (payoutMethod "driver_wallet") and the
 * ledger row has a deterministic id in the same transaction, so a repeat is
 * refused and never credits twice. The transaction first reconciles the
 * statement and refuses while a debt on it is open. A payable of zero is
 * marked not_required, with no ledger row and no wallet change. No payments
 * record: nothing leaves CTSGo.
 */
async function settleDriverStatement(actor, data) {
  const statementId = data?.statementId;
  if (typeof statementId !== "string" || !ID.test(statementId)) throw refuse("invalid_request", "Invalid request.", "invalid-argument");
  const ref = db().collection(STATEMENTS).doc(statementId);
  return db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const s = snap.exists ? snap.data() : null;
    const problem = payoutProblem(s, "driver");
    if (problem) throw refuse(problem, "This statement cannot be settled.");
    await requireReconciled(tx, statementId, s);
    const driverRef = db().collection("drivers").doc(s.partyId);
    const driver = await tx.get(driverRef);
    if (!driver.exists) throw refuse("driver_not_found", "The driver was not found.", "not-found");
    const payable = payableOf(s);
    if (payable === 0) {
      markNotRequired(tx, ref, s, actor, "driver");
      return { statementId, payoutStatus: "not_required", creditedGhs: 0 };
    }
    const amount = payable / 100;
    const now = FieldValue.serverTimestamp();
    tx.update(driverRef, { walletBalance: FieldValue.increment(amount), totalEarnings: FieldValue.increment(amount), updatedAt: now });
    tx.set(driverRef.collection("earnings").doc("summary"), {
      totalEarnings: FieldValue.increment(amount), lifetimeEarnings: FieldValue.increment(amount), lastUpdatedAt: now,
    }, { merge: true });
    tx.create(db().collection("ledger").doc(`gas_driver_settlement_${statementId}`), {
      type: "EARNING", status: "COMPLETED", fromType: "gas_settlement", toType: "driver", toUserId: s.partyId,
      amount, currency: "GHS", platformFee: 0, driverNet: amount,
      referenceType: "gas_settlement_statement", referenceId: statementId,
      idempotencyKey: `gas_driver_settlement_${statementId}`, processedAt: now, createdAt: now,
    });
    tx.update(ref, {
      payoutStatus: "paid", payoutMethod: "driver_wallet", paidAt: now,
      payout: { method: "driver_wallet", amountPesewas: payable, netPesewas: s.netPesewas, withheldPesewas: s.withheldPesewas ?? 0, approvedBy: actor.uid, approvedAt: now },
    });
    audit(tx, "gas_driver_statement_settled", statementId, actor, { driverId: s.partyId, amountPesewas: payable });
    return { statementId, payoutStatus: "paid", creditedGhs: amount };
  });
}

// ── Daily statements ─────────────────────────────────────────────────────────

/** The previous business day (UTC, as Accra). */
function previousBusinessDate(now = Date.now()) {
  return new Date(now - 24 * 3600e3).toISOString().slice(0, 10);
}

// ── Exports ──────────────────────────────────────────────────────────────────

const OPTS = { region: "europe-west2" };

exports.adminApproveGasSupplierPayout = onCall(
  { ...OPTS, timeoutSeconds: 120, secrets: [BRIDGE_CLIENT_KEY, BRIDGE_SECRET_KEY, BRIDGE_SERVICE_ID] },
  async (request) => approveSupplierPayout(await requireSuperAdmin(request), request.data),
);
exports.adminResolveGasSupplierPayout = onCall(OPTS, async (request) => resolveSupplierPayout(await requireSuperAdmin(request), request.data));
exports.adminSettleGasDriverStatement = onCall(OPTS, async (request) => settleDriverStatement(await requireSuperAdmin(request), request.data));

exports.prepareDailyGasSettlementStatements = onSchedule(
  { ...OPTS, schedule: "every day 02:00", timeZone: "Africa/Accra" },
  async () => {
    const r = await prepareStatements(previousBusinessDate(), { preparedBy: "schedule" });
    console.log("gas settlement statements", r.businessDate, JSON.stringify(r.statements), `exceptions: ${r.exceptions.length}`);
  },
);

Object.assign(exports, {
  PAYOUT_FLAG_DOC, BRIDGE_NETWORK, BLOCKING_DEBT_STATUSES, NotSentError,
  payoutDestination, payoutProblem, payableOf, statementReconciliationProblem, previousBusinessDate,
  approveSupplierPayout, resolveSupplierPayout, settleDriverStatement, _setTransportForTests,
});
