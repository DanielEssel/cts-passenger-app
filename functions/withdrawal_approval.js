// ─────────────────────────────────────────────────────────────────────────────
// WITHDRAWAL APPROVAL — hybrid auto-approve + manual review
//
// These go IN bridge.js (they reuse its BRIDGE_* secrets, getBridgeHeaders,
// _refundFailedPayout, bridgePayoutCallback, getDb, FieldValue, axios,
// HttpsError, onCall). The two helpers (_sendBridgePayout, _needsManualReview)
// are private; approveWithdrawal / rejectWithdrawal are exported.
//
// FLOW:
//   initiateBridgePayout (driver) → guards → HOLD money → risk check
//        clean  → auto-approve → _sendBridgePayout() pays immediately
//        risky  → leave status:"pending" → admin decides
//   approveWithdrawal (admin) → _sendBridgePayout() → completed
//   rejectWithdrawal  (admin) → _refundFailedPayout() → rejected
//
// AUTO-APPROVE if ALL true: not first withdrawal, amount <= autoApproveMaxAmount
//   (GH₵1000), payout number matches registered. Otherwise → manual review.
// ─────────────────────────────────────────────────────────────────────────────


"use strict";
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const axios = require("axios");

const getDb = () => admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const {
  BRIDGE_CLIENT_KEY, BRIDGE_SECRET_KEY, BRIDGE_SERVICE_ID,
  BRIDGE_BASE, CALLBACK_PAYOUT,
  getBridgeHeaders, _refundFailedPayout,
} = require("./bridge")._bridgeShared;


// ── Shared: send a Bridge payout (extracted from the old inline call) ─────────
async function _sendBridgePayout({
  db, uid, userName, amount, intlPhone, mappedNetwork,
  transactionId, withdrawalRef, txRef, isDriver,
}) {
  const paymentRef = db.collection("payments").doc(transactionId);
  await paymentRef.set({
    transactionId, userId: uid, userName,
    role: isDriver ? "driver" : "passenger",
    phone: intlPhone, network: mappedNetwork, amount, currency: "GHS",
    type: "payout", status: "pending",
    withdrawalId: withdrawalRef.id,
    txId: txRef ? txRef.id : null,
    bridgeStatus: null,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  const requestTime = new Date().toISOString().replace("T", " ").split(".")[0];

  let bridgeResponse;
  try {
    bridgeResponse = await axios.post(
      `${BRIDGE_BASE}/make_payment`,
      {
        service_id: Number(BRIDGE_SERVICE_ID.value()),
        reference: userName, customer_number: intlPhone,
        transaction_id: transactionId, trans_type: "MTC",
        amount, nw: mappedNetwork, nickname: userName,
        payment_option: "MOM", currency_code: "GHS", currency_val: amount,
        callback_url: CALLBACK_PAYOUT, request_time: requestTime,
      },
      { headers: getBridgeHeaders(BRIDGE_CLIENT_KEY.value(), BRIDGE_SECRET_KEY.value()) },
    );
  } catch (bridgeErr) {
    console.error("[_sendBridgePayout] Bridge call failed:", bridgeErr.message);
    await _refundFailedPayout(db, uid, isDriver, amount, withdrawalRef.id, txRef ? txRef.id : null);
    await paymentRef.update({ status: "failed", failureReason: bridgeErr.message, updatedAt: FieldValue.serverTimestamp() });
    throw new HttpsError("unavailable", "Could not reach payment service. Balance restored.");
  }

  const code = bridgeResponse?.data?.response_code ?? "500";
  const msg = bridgeResponse?.data?.response_message ?? "Unknown";
  const accepted = new Set(["000", "202"]).has(code);

  await paymentRef.update({ bridgeCode: code, bridgeMessage: msg, status: accepted ? "pending" : "failed", updatedAt: FieldValue.serverTimestamp() });

  if (!accepted) {
    await _refundFailedPayout(db, uid, isDriver, amount, withdrawalRef.id, txRef ? txRef.id : null);
    throw new HttpsError("failed-precondition", `Payout could not be initiated (${code}). Balance restored.`);
  }

  console.log(`[_sendBridgePayout] OK ${transactionId} | ${code} | GHS${amount} -> ${intlPhone}`);
  return code;
}

// ── Risk check: auto-approve or manual review? ───────────────────────────────
async function _needsManualReview({ db, uid, amount, intlPhone, dData, settings }) {
  const autoMax = settings?.autoApproveMaxAmount ?? 1000;

  // 1. First withdrawal ever → always review.
  const priorCompleted = await db.collection("withdrawals")
    .where("userId", "==", uid).where("status", "==", "completed").limit(1).get();
  if (priorCompleted.empty) return { review: true, reason: "first_withdrawal" };

  // 2. Over the auto-approve ceiling → review.
  if (amount > autoMax) return { review: true, reason: "large_amount" };

  // 3. Payout number differs from registered → review.
  const registered = (dData.phone || "").replace(/\D/g, "").slice(-9);
  const payingTo = (intlPhone || "").replace(/\D/g, "").slice(-9);
  if (registered && payingTo && registered !== payingTo) {
    return { review: true, reason: "number_mismatch" };
  }

  return { review: false, reason: null };
}

// ═══════════════════════════════════════════════════════════════════════════
// In initiateBridgePayout, REPLACE everything from
//   "// ── Create payment tracking doc ──" through "return { success: true, transactionId };"
// with this block (the guards + hold-money transaction ABOVE stay unchanged):
// ═══════════════════════════════════════════════════════════════════════════
/*
    // Money is HELD (walletBalance debited, pendingWithdrawal incremented above).
    // Decide: auto-approve and pay now, or queue for admin review.
    const { review, reason } = await _needsManualReview({
      db, uid, amount, intlPhone, dData, settings: settingsDoc.data(),
    });

    if (review) {
      await withdrawalRef.update({ reviewReason: reason, needsReview: true });
      return {
        success: true,
        status: "pending_review",
        withdrawalId: withdrawalRef.id,
        message: "Withdrawal submitted for review. You'll be paid once approved.",
      };
    }

    await _sendBridgePayout({
      db, uid, userName, amount, intlPhone, mappedNetwork,
      transactionId, withdrawalRef, txRef, isDriver: true,
    });
    await withdrawalRef.update({ autoApproved: true });
    return { success: true, status: "processing", transactionId };
*/

// ── approveWithdrawal (admin) ────────────────────────────────────────────────
exports.approveWithdrawal = onCall(
  { region: "europe-west2", secrets: [BRIDGE_CLIENT_KEY, BRIDGE_SECRET_KEY, BRIDGE_SERVICE_ID] },
  async (request) => {
    const adminUid = request.auth?.uid;
    if (!adminUid) throw new HttpsError("unauthenticated", "Sign in required.");

    const db = getDb();
    const adminDoc = await db.collection("admins").doc(adminUid).get();
    if (!adminDoc.exists || adminDoc.data()?.active !== true) {
      throw new HttpsError("permission-denied", "Admins only.");
    }

    const withdrawalId = request.data?.withdrawalId;
    if (!withdrawalId) throw new HttpsError("invalid-argument", "withdrawalId required.");

    const wRef = db.collection("withdrawals").doc(withdrawalId);
    const wSnap = await wRef.get();
    if (!wSnap.exists) throw new HttpsError("not-found", "Withdrawal not found.");
    const w = wSnap.data();
    if (w.status !== "pending") throw new HttpsError("failed-precondition", `Already ${w.status}.`);

    await wRef.update({ status: "processing", approvedBy: adminUid, approvedAt: FieldValue.serverTimestamp() });

    try {
      await _sendBridgePayout({
        db, uid: w.userId, userName: w.userName || "CTS Driver",
        amount: w.amount, intlPhone: w.phone, mappedNetwork: w.network,
        transactionId: w.bridgeTransId || withdrawalId,
        withdrawalRef: wRef, txRef: null, isDriver: true,
      });
    } catch (err) {
      await wRef.update({ status: "pending", approvedBy: FieldValue.delete(), approvedAt: FieldValue.delete() });
      throw err;
    }

    await db.collection("drivers").doc(w.userId).update({ pendingWithdrawal: FieldValue.increment(-w.amount) });

    await db.collection("audit_log").add({
      action: "withdrawal_approved", withdrawalId, driverId: w.userId, amount: w.amount,
      adminUid, adminEmail: adminDoc.data()?.email || null,
      createdAt: FieldValue.serverTimestamp(),
    });

    return { success: true, status: "processing" };
  },
);

// ── rejectWithdrawal (admin) ─────────────────────────────────────────────────
exports.rejectWithdrawal = onCall(
  { region: "europe-west2" },
  async (request) => {
    const adminUid = request.auth?.uid;
    if (!adminUid) throw new HttpsError("unauthenticated", "Sign in required.");

    const db = getDb();
    const adminDoc = await db.collection("admins").doc(adminUid).get();
    if (!adminDoc.exists || adminDoc.data()?.active !== true) {
      throw new HttpsError("permission-denied", "Admins only.");
    }

    const withdrawalId = request.data?.withdrawalId;
    const reason = (request.data?.reason || "").toString().slice(0, 300);
    if (!withdrawalId) throw new HttpsError("invalid-argument", "withdrawalId required.");

    const wRef = db.collection("withdrawals").doc(withdrawalId);

    const result = await db.runTransaction(async (tx) => {
      const wSnap = await tx.get(wRef);
      if (!wSnap.exists) throw new HttpsError("not-found", "Withdrawal not found.");
      const w = wSnap.data();
      if (w.status !== "pending") throw new HttpsError("failed-precondition", `Already ${w.status}.`);

      const driverRef = db.collection("drivers").doc(w.userId);
      tx.update(driverRef, {
        walletBalance: FieldValue.increment(w.amount),
        pendingWithdrawal: FieldValue.increment(-w.amount),
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
      reason: reason || null, adminUid, adminEmail: adminDoc.data()?.email || null,
      createdAt: FieldValue.serverTimestamp(),
    });

    return { success: true, status: "rejected" };
  },
);