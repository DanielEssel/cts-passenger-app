// ─────────────────────────────────────────────────────────────────────────────
// WITHDRAWAL APPROVAL — admin review only
//
// States of withdrawals/{id} (driver payouts):
//   pending     funds held (walletBalance debited, pendingWithdrawal and
//               drivers.activeWithdrawalId set by initiateBridgePayout in one
//               transaction); awaiting an admin
//   processing  approved; the payout request was sent to Bridge
//               (payoutOutcome "sent") or its outcome is unknown
//               (payoutOutcome "unknown"); never re-sendable
//   completed   paid, confirmed by an admin (resolveUnconfirmedPayout)
//   failed      Bridge explicitly refused it, or an admin confirmed it was
//               not paid; the hold was returned to the driver
//   rejected    refused by an admin before any payout; the hold was returned
//
// There is no automatic payout: every request waits for approveWithdrawal.
// Bridge callbacks are not authenticated (bridge.js verifyBridgeCallback),
// so they are recorded but never settle a payout; an admin confirms the
// outcome with Bridge and records it with resolveUnconfirmedPayout.
// ─────────────────────────────────────────────────────────────────────────────


"use strict";
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const axios = require("axios");

const getDb = () => admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const {
  BRIDGE_CLIENT_KEY, BRIDGE_SECRET_KEY, BRIDGE_SERVICE_ID,
  resolveBridgeTarget,
  getBridgeHeaders,
} = require("./bridge")._bridgeShared;
const crypto = require("crypto");
const { requireSuperAdminRole } = require("./admin_auth");


// ── Sending one payout attempt ───────────────────────────────────────────────
// approveWithdrawal claims a pending withdrawal as one *attempt*
// (status "processing", payoutOutcome "sending", a fresh attemptId). The
// attempt then ends in exactly one of these, each applied in a single
// transaction that first re-checks that this same attempt still owns the
// withdrawal (status, attemptId, payoutOutcome "sending"):
//
//   not_sent  failed before any request left the platform (config refusal,
//             payment record not written): back to "pending", may be
//             approved again; nothing was sent, so this is not a retry of
//             a payout that could have been made
//   sent      Bridge accepted the request ("000"/"202"): "processing"/"sent",
//             still held until an admin confirms the result
//   refused   Bridge answered, in a 2xx response, with a code that means the
//             payout failed ("001" failed, "003" cancelled): refund, lock
//             released, "failed"; one ledger entry (payout_refund_<id>, the
//             same id an admin "failed" resolution uses, so they exclude each
//             other)
//   unknown   anything else after the request left: no response, timeout,
//             HTTP error, a missing, malformed or unrecognised code: still
//             held, "processing"/"unknown", admin alert; never re-sent
//
// If the attempt no longer owns the withdrawal (an admin resolved it after it
// went stale), nothing is applied and an alert is raised. Which codes Bridge
// guarantees mean "no money moved" is an open question for Bridge
// (PAYMENTS-STAGING.md, question 8); until answered, only the two codes above
// count as a refusal.
const ACCEPTED_CODES = new Set(["000", "202"]);
const REFUSED_CODES = new Set(["001", "003"]);
// Upper bound for the Bridge request. approveWithdrawal's own timeout (120 s)
// is well above it, so a timeout is always recorded as "unknown".
const BRIDGE_TIMEOUT_MS = Number(process.env.BRIDGE_HTTP_TIMEOUT_MS) > 0
  ? Number(process.env.BRIDGE_HTTP_TIMEOUT_MS) : 20000;
// An attempt still "sending" after this long belongs to an invocation that
// was killed (the function times out at 120 s); an admin may then resolve it.
const STALE_SENDING_MS = 10 * 60 * 1000;

class PayoutOutcomeUnknownError extends HttpsError {
  constructor(transactionId) {
    super("unavailable",
      "The payment service did not confirm this payout. It will be reconciled; it must not be resent.");
    this.transactionId = transactionId;
  }
}

function classifyBridgeResponse(response) {
  const code = response?.data?.response_code;
  if (typeof code !== "string" || !/^\d{3}$/.test(code)) return { kind: "unknown", code: null };
  if (ACCEPTED_CODES.has(code)) return { kind: "sent", code };
  if (REFUSED_CODES.has(code)) return { kind: "refused", code };
  return { kind: "unknown", code };
}

// Applies the end of one attempt atomically. Returns true when applied,
// false when the attempt no longer owned the withdrawal.
async function finishAttempt(db, { wRef, attemptId, kind, w, adminUid, adminEmail, transactionId, detail = {} }) {
  const paymentRef = db.collection("payments").doc(transactionId);
  const driverRef = db.collection("drivers").doc(w.userId);
  const applied = await db.runTransaction(async (tx) => {
    const wSnap = await tx.get(wRef);
    const cur = wSnap.data() ?? {};
    const driverSnap = kind === "refused" ? await tx.get(driverRef) : null;
    if (cur.status !== "processing" || cur.attemptId !== attemptId || cur.payoutOutcome !== "sending") {
      return false;
    }
    const now = FieldValue.serverTimestamp();
    const audit = (action) => tx.set(db.collection("audit_log").doc(), {
      action, withdrawalId: wRef.id, driverId: w.userId, amount: w.amount, attemptId,
      ...detail, adminUid, adminEmail, createdAt: now,
    });
    if (kind === "not_sent") {
      tx.update(wRef, { status: "pending", payoutOutcome: FieldValue.delete(),
        attemptId: FieldValue.delete(), lastAttemptError: detail.error ?? null, updatedAt: now });
      audit("withdrawal_payout_not_sent");
    } else if (kind === "sent") {
      tx.update(wRef, { payoutOutcome: "sent", updatedAt: now });
      tx.set(paymentRef, { status: "pending", bridgeCode: detail.code, updatedAt: now }, { merge: true });
      audit("withdrawal_approved");
    } else if (kind === "unknown") {
      tx.update(wRef, { payoutOutcome: "unknown", updatedAt: now });
      tx.set(paymentRef, { status: "unconfirmed", bridgeCode: detail.code ?? null,
        failureReason: detail.error ?? null, httpStatus: detail.httpStatus ?? null, updatedAt: now },
      { merge: true });
      tx.set(db.collection("admin_alerts").doc(), { type: "payout_outcome_unknown",
        transactionId, withdrawalId: wRef.id, userId: w.userId, amount: w.amount, createdAt: now });
      audit("withdrawal_payout_unconfirmed");
    } else if (kind === "refused") {
      const d = driverSnap.exists ? driverSnap.data() : {};
      if (d.activeWithdrawalId !== wRef.id || (d.pendingWithdrawal ?? 0) < w.amount) return false;
      tx.update(driverRef, {
        walletBalance: FieldValue.increment(w.amount),
        totalEarnings: FieldValue.increment(w.amount),
        pendingWithdrawal: FieldValue.increment(-w.amount),
        activeWithdrawalId: FieldValue.delete(),
        updatedAt: now,
      });
      tx.update(wRef, { status: "failed", payoutOutcome: "refused", failedAt: now, updatedAt: now });
      tx.set(paymentRef, { status: "failed", bridgeCode: detail.code, updatedAt: now }, { merge: true });
      tx.create(db.collection("ledger").doc(`payout_refund_${wRef.id}`), {
        type: "REFUND", status: "COMPLETED", fromType: "platform",
        toUserId: w.userId, toType: "driver", amount: w.amount, currency: "GHS",
        platformFee: 0, driverNet: 0, referenceType: "withdrawal_refund", referenceId: transactionId,
        idempotencyKey: `payout_refund_${wRef.id}`, bridgeCode: detail.code,
        processedAt: now, createdAt: now,
      });
      audit("withdrawal_payout_refused");
    }
    return true;
  });
  if (!applied) {
    await db.collection("admin_alerts").add({
      type: "payout_attempt_superseded", withdrawalId: wRef.id, attemptId, outcome: kind,
      createdAt: FieldValue.serverTimestamp(),
    });
  }
  return applied;
}

async function _sendBridgePayout({ db, wRef, attemptId, w, adminUid, adminEmail }) {
  const transactionId = w.bridgeTransId || wRef.id;
  const userName = w.userName || "CTS Driver";
  const ctx = { wRef, attemptId, w, adminUid, adminEmail, transactionId };

  // ── Before anything leaves the platform ──────────────────────────────────
  let target;
  try {
    target = resolveBridgeTarget("bridgePayoutCallback"); // fails closed
    await db.collection("payments").doc(transactionId).set({
      transactionId, userId: w.userId, userName, role: "driver",
      phone: w.phone, network: w.network, amount: w.amount, currency: "GHS",
      type: "payout", status: "pending", withdrawalId: wRef.id, txId: null,
      attemptId, bridgeStatus: null,
      createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp(),
    });
  } catch (preErr) {
    console.error("[_sendBridgePayout] not sent:", preErr.message);
    await finishAttempt(db, { ...ctx, kind: "not_sent", detail: { error: preErr.message } });
    throw new HttpsError("unavailable", "The payout was not sent. It can be approved again.");
  }

  // ── The request: from here on the outcome may be unknown ────────────────
  const requestTime = new Date().toISOString().replace("T", " ").split(".")[0];
  let response;
  try {
    response = await axios.post(
      `${target.apiBase}/make_payment`,
      {
        service_id: Number(BRIDGE_SERVICE_ID.value()),
        reference: userName, customer_number: w.phone,
        transaction_id: transactionId, trans_type: "MTC",
        amount: w.amount, nw: w.network, nickname: userName,
        payment_option: "MOM", currency_code: "GHS", currency_val: w.amount,
        callback_url: target.callbackUrl, request_time: requestTime,
      },
      { headers: getBridgeHeaders(BRIDGE_CLIENT_KEY.value(), BRIDGE_SECRET_KEY.value()),
        timeout: BRIDGE_TIMEOUT_MS },
    );
  } catch (bridgeErr) {
    console.error("[_sendBridgePayout] outcome unknown:", bridgeErr.message);
    await finishAttempt(db, { ...ctx, kind: "unknown",
      detail: { error: bridgeErr.message, httpStatus: bridgeErr.response?.status ?? null } });
    throw new PayoutOutcomeUnknownError(transactionId);
  }

  const outcome = classifyBridgeResponse(response);
  const applied = await finishAttempt(db, { ...ctx, kind: outcome.kind, detail: { code: outcome.code } });
  if (!applied) {
    throw new HttpsError("aborted", "This payout attempt was already resolved by an admin.");
  }
  if (outcome.kind === "unknown") throw new PayoutOutcomeUnknownError(transactionId);
  if (outcome.kind === "refused") {
    await notifyDriver(db, w.userId, "failed", w.amount, wRef.id);
    throw new HttpsError("failed-precondition",
      `Payout could not be initiated (${outcome.code}). Balance restored.`);
  }
  console.log(`[_sendBridgePayout] accepted ${transactionId} | ${outcome.code} | GHS${w.amount}`);
}

async function notifyDriver(db, driverId, outcome, amount, withdrawalId) {
  try {
    const driverDoc = await db.collection("drivers").doc(driverId).get();
    const fcmToken = driverDoc.data()?.fcmToken;
    if (!fcmToken) return;
    await admin.messaging().send({
      token: fcmToken,
      notification: outcome === "paid"
        ? { title: "💸 Withdrawal Successful!", body: `GH₵${Number(amount).toFixed(2)} sent to your MoMo account.` }
        : { title: "Withdrawal Failed", body: `GH₵${Number(amount).toFixed(2)} could not be sent. Your balance has been restored.` },
      data: { type: outcome === "paid" ? "withdrawal_success" : "withdrawal_failed", withdrawalId },
    });
  } catch (e) {
    console.warn("[withdrawals] FCM failed (non-fatal):", e.message);
  }
}

// The withdrawal's money must be held for this driver, by this withdrawal:
// initiateBridgePayout sets drivers.activeWithdrawalId (server-only) in the
// transaction that debits the balance, so a withdrawal document created any
// other way (or a second one) can never be paid, refunded or resolved.
function assertHeldFor(driverSnap, withdrawalId, amount) {
  const d = driverSnap.exists ? driverSnap.data() : {};
  if (d.activeWithdrawalId !== withdrawalId || (d.pendingWithdrawal ?? 0) < amount) {
    throw new HttpsError("failed-precondition", "The withdrawal amount is not held for this driver.");
  }
}

// ── approveWithdrawal (admin) ────────────────────────────────────────────────
exports.approveWithdrawal = onCall(
  { region: "europe-west2", timeoutSeconds: 120,
    secrets: [BRIDGE_CLIENT_KEY, BRIDGE_SECRET_KEY, BRIDGE_SERVICE_ID] },
  async (request) => {
    const { adminUid, adminEmail } = await requireSuperAdminRole(request);
    const db = getDb();

    const withdrawalId = request.data?.withdrawalId;
    if (!withdrawalId) throw new HttpsError("invalid-argument", "withdrawalId required.");

    const wRef = db.collection("withdrawals").doc(withdrawalId);
    const attemptId = crypto.randomUUID();

    // Claim the withdrawal atomically: pending → processing. A concurrent or
    // repeated approval sees "processing" (or a later state) and stops, so
    // at most one payout request is ever sent for a withdrawal. The amount
    // must still be held for this driver (pendingWithdrawal, incremented when
    // initiateBridgePayout debited the balance), so a withdrawal whose money
    // was never held cannot be paid.
    const w = await db.runTransaction(async (tx) => {
      const wSnap = await tx.get(wRef);
      if (!wSnap.exists) throw new HttpsError("not-found", "Withdrawal not found.");
      const data = wSnap.data();
      if (data.status !== "pending") {
        throw new HttpsError("failed-precondition", `Already ${data.status}.`);
      }
      if (typeof data.userId !== "string" || !data.userId ||
          typeof data.amount !== "number" || !(data.amount > 0)) {
        throw new HttpsError("failed-precondition", "Withdrawal record is incomplete.");
      }
      const driverSnap = await tx.get(db.collection("drivers").doc(data.userId));
      assertHeldFor(driverSnap, withdrawalId, data.amount);
      tx.update(wRef, {
        status: "processing", payoutOutcome: "sending", attemptId,
        sendingStartedAt: FieldValue.serverTimestamp(),
        approvedBy: adminUid, approvedAt: FieldValue.serverTimestamp(),
      });
      return data;
    });

    // Every outcome (including the audit entry) is recorded by finishAttempt.
    await _sendBridgePayout({
      db, wRef, attemptId, w, adminUid, adminEmail,
    });

    return { success: true, status: "processing" };
  },
);

// ── rejectWithdrawal (admin) ─────────────────────────────────────────────────
exports.rejectWithdrawal = onCall(
  { region: "europe-west2" },
  async (request) => {
    const { adminUid, adminEmail } = await requireSuperAdminRole(request);
    const db = getDb();

    const withdrawalId = request.data?.withdrawalId;
    const reason = (request.data?.reason || "").toString().slice(0, 300);
    if (!withdrawalId) throw new HttpsError("invalid-argument", "withdrawalId required.");

    const wRef = db.collection("withdrawals").doc(withdrawalId);

    const result = await db.runTransaction(async (tx) => {
      const wSnap = await tx.get(wRef);
      if (!wSnap.exists) throw new HttpsError("not-found", "Withdrawal not found.");
      const w = wSnap.data();
      if (w.status !== "pending") throw new HttpsError("failed-precondition", `Already ${w.status}.`);
      if (typeof w.userId !== "string" || !w.userId ||
          typeof w.amount !== "number" || !(w.amount > 0)) {
        throw new HttpsError("failed-precondition", "Withdrawal record is incomplete.");
      }

      // Return only money that is actually held for this driver: rejecting a
      // withdrawal whose amount was never held would create balance.
      const driverRef = db.collection("drivers").doc(w.userId);
      const driverSnap = await tx.get(driverRef);
      assertHeldFor(driverSnap, withdrawalId, w.amount);
      // Return exactly what initiateBridgePayout debited (walletBalance and
      // totalEarnings), as a refunded payout does; previously totalEarnings
      // stayed reduced after a rejection.
      tx.update(driverRef, {
        walletBalance: FieldValue.increment(w.amount),
        totalEarnings: FieldValue.increment(w.amount),
        pendingWithdrawal: FieldValue.increment(-w.amount),
        activeWithdrawalId: FieldValue.delete(),
      });
      tx.update(wRef, {
        status: "rejected", rejectedBy: adminUid,
        rejectionReason: reason || "Rejected by admin",
        rejectedAt: FieldValue.serverTimestamp(),
      });
      return { amount: w.amount, driverId: w.userId };
    });

    await db.collection("audit_log").add({
      action: "withdrawal_rejected", withdrawalId, driverId: result.driverId, amount: result.amount,
      reason: reason || null, adminUid, adminEmail,
      createdAt: FieldValue.serverTimestamp(),
    });

    return { success: true, status: "rejected" };
  },
);

// Shared with gas_supplier_payouts.js, so both payout paths read Bridge's
// answer the same way.
exports._payoutShared = { classifyBridgeResponse, BRIDGE_TIMEOUT_MS, STALE_SENDING_MS };

// ── resolveUnconfirmedPayout (admin) ─────────────────────────────────────────
// The only way a payout is settled while Bridge callbacks cannot be
// authenticated. For a withdrawal in "processing" (sent, or outcome unknown),
// an admin who has confirmed the result with Bridge records it:
//   outcome "paid"   → completed; the hold is released (pendingWithdrawal)
//   outcome "failed" → failed; the hold is returned to the driver
// with the evidence (Bridge reference or support ticket) in the audit log.
// One transaction, one winner: a repeated or concurrent resolution is
// refused, so a payout is never both paid and refunded, and nothing is ever
// re-sent from here.
exports.resolveUnconfirmedPayout = onCall(
  { region: "europe-west2" },
  async (request) => {
    const { adminUid, adminEmail } = await requireSuperAdminRole(request);
    const withdrawalId = request.data?.withdrawalId;
    const outcome = request.data?.outcome;
    const evidence = (request.data?.evidence ?? "").toString().trim().slice(0, 500);
    if (typeof withdrawalId !== "string" || !withdrawalId) {
      throw new HttpsError("invalid-argument", "withdrawalId required.");
    }
    if (!["paid", "failed"].includes(outcome)) {
      throw new HttpsError("invalid-argument", 'outcome must be "paid" or "failed".');
    }
    if (evidence.length < 6) {
      throw new HttpsError("invalid-argument",
        "Record the evidence from Bridge (reference or ticket) before resolving.");
    }

    const db = getDb();
    const wRef = db.collection("withdrawals").doc(withdrawalId);
    const result = await db.runTransaction(async (tx) => {
      const wSnap = await tx.get(wRef);
      if (!wSnap.exists) throw new HttpsError("not-found", "Withdrawal not found.");
      const w = wSnap.data();
      if (w.status !== "processing") {
        throw new HttpsError("failed-precondition", `Already ${w.status}.`);
      }
      // Never while an attempt may still be talking to Bridge: its own
      // outcome would race this one. A "sending" attempt is resolvable only
      // once it is far older than the function can run.
      const startedAt = w.sendingStartedAt?.toMillis?.() ?? null;
      const staleSending = w.payoutOutcome === "sending" &&
        startedAt !== null && Date.now() - startedAt > STALE_SENDING_MS;
      if (!["sent", "unknown"].includes(w.payoutOutcome) && !staleSending) {
        throw new HttpsError("failed-precondition",
          "A payout attempt is still in progress. Try again shortly.");
      }
      const driverRef = db.collection("drivers").doc(w.userId);
      const driverSnap = await tx.get(driverRef);
      assertHeldFor(driverSnap, withdrawalId, w.amount);
      const transactionId = w.bridgeTransId || withdrawalId;
      const paymentRef = db.collection("payments").doc(transactionId);
      const paymentSnap = await tx.get(paymentRef);

      const resolution = {
        resolvedBy: adminUid, resolvedAt: FieldValue.serverTimestamp(),
        resolutionOutcome: outcome, resolutionEvidence: evidence,
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (outcome === "paid") {
        tx.update(driverRef, {
          pendingWithdrawal: FieldValue.increment(-w.amount),
          activeWithdrawalId: FieldValue.delete(),
          updatedAt: FieldValue.serverTimestamp(),
        });
        tx.update(wRef, { status: "completed", completedAt: FieldValue.serverTimestamp(), ...resolution });
        // Deterministic ids: a ledger entry per withdrawal outcome, never two.
        tx.create(db.collection("ledger").doc(`payout_${withdrawalId}`), {
          type: "PAYOUT", status: "COMPLETED", fromType: "platform",
          toUserId: w.userId, toType: "driver", amount: w.amount, currency: "GHS",
          platformFee: 0, driverNet: w.amount,
          referenceType: "withdrawal", referenceId: transactionId,
          idempotencyKey: `payout_${withdrawalId}`, resolvedBy: adminUid,
          processedAt: FieldValue.serverTimestamp(), createdAt: FieldValue.serverTimestamp(),
        });
      } else {
        tx.update(driverRef, {
          walletBalance: FieldValue.increment(w.amount),
          totalEarnings: FieldValue.increment(w.amount),
          pendingWithdrawal: FieldValue.increment(-w.amount),
          activeWithdrawalId: FieldValue.delete(),
          updatedAt: FieldValue.serverTimestamp(),
        });
        tx.update(wRef, { status: "failed", failedAt: FieldValue.serverTimestamp(), ...resolution });
        tx.create(db.collection("ledger").doc(`payout_refund_${withdrawalId}`), {
          type: "REFUND", status: "COMPLETED", fromType: "platform",
          toUserId: w.userId, toType: "driver", amount: w.amount, currency: "GHS",
          platformFee: 0, driverNet: 0,
          referenceType: "withdrawal_refund", referenceId: transactionId,
          idempotencyKey: `payout_refund_${withdrawalId}`, resolvedBy: adminUid,
          processedAt: FieldValue.serverTimestamp(), createdAt: FieldValue.serverTimestamp(),
        });
      }
      if (paymentSnap.exists) {
        tx.update(paymentRef, {
          status: outcome === "paid" ? "success" : "failed",
          resolvedBy: adminUid, updatedAt: FieldValue.serverTimestamp(),
        });
      }
      tx.set(db.collection("audit_log").doc(), {
        action: outcome === "paid" ? "withdrawal_payout_confirmed" : "withdrawal_payout_failed_confirmed",
        withdrawalId, driverId: w.userId, amount: w.amount, evidence,
        previousOutcome: w.payoutOutcome ?? null,
        adminUid, adminEmail, createdAt: FieldValue.serverTimestamp(),
      });
      return { driverId: w.userId, amount: w.amount };
    });

    // Notify once: only the resolution that committed reaches this point.
    await notifyDriver(db, result.driverId, outcome, result.amount, withdrawalId);

    return { success: true, status: outcome === "paid" ? "completed" : "failed" };
  },
);
