// functions/bridge.js
// Bridge API integration for CTS Transport — collection (top-up) and payout (withdrawal)
// This file adds 5 new functions and touches NOTHING in wallet.js / escrow.js / trips.js

"use strict";

const {
  onCall,
  HttpsError,
  onRequest,
} = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const axios = require("axios");

const {
  PaymentConfigError,
  bridgeApiBase,
  bridgeCallbackUrl,
} = require("./config");

const getDb = () => admin.firestore();
const FieldValue = admin.firestore.FieldValue;

// ── Bridge secrets ─────────────────────────────────────────────────────────────
// Set per project (Secret Manager is project-scoped); see PAYMENTS-STAGING.md:
//   firebase functions:secrets:set BRIDGE_CLIENT_KEY --project <projectId>
//   firebase functions:secrets:set BRIDGE_SECRET_KEY --project <projectId>
//   firebase functions:secrets:set BRIDGE_SERVICE_ID --project <projectId>
const BRIDGE_CLIENT_KEY = defineSecret("BRIDGE_CLIENT_KEY");
const BRIDGE_SECRET_KEY = defineSecret("BRIDGE_SECRET_KEY");
const BRIDGE_SERVICE_ID = defineSecret("BRIDGE_SERVICE_ID");

// Gateway host and callback URLs come from per-environment config
// (functions/.env.<projectId>), checked by the guard in config.js.

// Resolves where a Bridge request may go, before anything is written.
// Misconfiguration fails closed with a generic message to the caller.
function resolveBridgeTarget(callbackFunctionName) {
  try {
    return {
      apiBase: bridgeApiBase(),
      callbackUrl: bridgeCallbackUrl(callbackFunctionName),
    };
  } catch (err) {
    if (err instanceof PaymentConfigError) {
      console.error("[bridge] Payment request blocked by config guard:", err.message);
      throw new HttpsError("failed-precondition", "Payments are temporarily unavailable.");
    }
    throw err;
  }
}

// ── Constants ──────────────────────────────────────────────────────────────────

const NETWORK_MAP = {
  MTN: "MTN",
  TELECEL: "VOD",
  AIRTELTIGO: "AIR",
  // passthrough if already in Bridge format
  VOD: "VOD",
  AIR: "AIR",
};

// Bridge trans_status → local status
const STATUS_MAP = {
  "000": "success",
  "001": "failed",
  "002": "pending",
  "003": "cancelled",
};

// ── Helpers ────────────────────────────────────────────────────────────────────

function requireAuth(request) {
  if (!request.auth?.uid)
    throw new HttpsError("unauthenticated", "Login required");
  return request.auth.uid;
}

function generateTransactionId(prefix) {
  const ts = Date.now();
  const random = Math.random().toString(36).slice(2, 8).toUpperCase();
  return `${prefix}-${ts}-${random}`;
}

function getBridgeHeaders(clientKey, secretKey) {
  const creds = Buffer.from(`${clientKey}:${secretKey}`).toString("base64");
  return {
    Authorization: `Basic ${creds}`,
    "Content-Type": "application/json",
    "User-Agent": "CTS-Transport/1.0",
  };
}

// Converts local Ghana number to Bridge international format
// 0244123456 → 233244123456
// Already international → passthrough
function toInternational(phone) {
  const cleaned = phone.replace(/[\s\-+()\u00A0]/g, "");
  if (/^233\d{9}$/.test(cleaned)) return cleaned;
  if (/^0\d{9}$/.test(cleaned)) return "233" + cleaned.slice(1);
  return null;
}

// Same ledger entry shape as escrow.js writeLedger — keeps the ledger consistent
async function writeLedger(tx, entry) {
  const ref = getDb().collection("ledger").doc();
  tx.set(ref, { ...entry, createdAt: FieldValue.serverTimestamp() });
}

// ── Callback authenticity ─────────────────────────────────────────────────────
// Bridge has not documented any way to authenticate a callback: no
// signature, shared secret, IP allow-list or transaction-status API is known
// (functions/PAYMENTS-STAGING.md, "Open questions for Bridge"). An
// unauthenticated callback can be sent by anyone who knows a reference, so it
// must never credit a wallet, refund a payout or mark one paid. Until Bridge
// confirms a mechanism, every callback is recorded for operators and money
// moves only through admin reconciliation (resolveUnconfirmedPayout). Do not
// replace this with an invented check.
function verifyBridgeCallback(/* req, payment */) {
  return { verified: false, reason: "no_supported_verification_mechanism" };
}

async function recordUnverifiedCallback(kind, req, paymentRef, reason) {
  const db = getDb();
  const { trans_ref, trans_status, trans_id, amount } = req.body;
  await db.collection("bridge_callbacks").add({
    kind, transactionId: trans_ref, transStatus: String(trans_status),
    transId: trans_id ?? null, amount: amount ?? null,
    verified: false, reason, payload: req.body,
    receivedAt: FieldValue.serverTimestamp(),
  });
  await paymentRef.update({
    lastCallbackStatus: String(trans_status),
    lastCallbackAt: FieldValue.serverTimestamp(),
    callbackCount: FieldValue.increment(1),
  });
  // One alert per payment however many callbacks arrive.
  try {
    await db.collection("admin_alerts").doc(`bridge_callback_unverified_${trans_ref}`).create({
      type: "bridge_callback_unverified", kind, transactionId: trans_ref,
      createdAt: FieldValue.serverTimestamp(),
    });
  } catch (e) {
    if (e.code !== 6) throw e; // ALREADY_EXISTS: already alerted
  }
}

// ── initiateBridgeTopUp ────────────────────────────────────────────────────────
// Callable — passenger initiates MoMo wallet top-up
// Creates payments/{transactionId}, calls Bridge CTM, returns transactionId for polling

exports.initiateBridgeTopUp = onCall(
  {
    region: "europe-west2",
    minInstances: 0,
    secrets: [BRIDGE_CLIENT_KEY, BRIDGE_SECRET_KEY, BRIDGE_SERVICE_ID],
  },
  async (request) => {
    const uid = requireAuth(request);
    // Top-ups are open. Each one is credited only when its result is
    // confirmed through a documented, authenticated mechanism
    // (verifyBridgeCallback); until then it stays pending.
    const { amount, phone, network } = request.data ?? {};

    // ── Validate ──────────────────────────────────────────────────────────────
    if (!amount || typeof amount !== "number" || amount < 1) {
      throw new HttpsError("invalid-argument", "Minimum top-up is GH₵1.00");
    }
    if (!phone)
      throw new HttpsError("invalid-argument", "Phone number required");
    if (!network)
      throw new HttpsError("invalid-argument", "MoMo network required");

    const mappedNetwork = NETWORK_MAP[network.toUpperCase()];
    if (!mappedNetwork) {
      throw new HttpsError(
        "invalid-argument",
        `Invalid network "${network}". Use MTN, TELECEL, or AIRTELTIGO`,
      );
    }

    const intlPhone = toInternational(phone);
    if (!intlPhone) {
      throw new HttpsError("invalid-argument", "Invalid Ghana mobile number");
    }

    // ── Where this environment may send the request (fails closed) ──────────
    const target = resolveBridgeTarget("bridgeTopUpCallback");

    // ── Ensure wallet exists ──────────────────────────────────────────────────
    const walletRef = getDb().collection("wallets").doc(uid);
    const walletDoc = await walletRef.get();
    if (!walletDoc.exists) {
      const userDoc = await getDb().collection("users").doc(uid).get();
      const email = userDoc.data()?.email ?? `${uid}@cts.app`;
      await walletRef.set({
        userId: uid,
        email,
        balance: 0,
        heldBalance: 0,
        currency: "GHS",
        isActive: true,
        createdAt: FieldValue.serverTimestamp(),
        lastUpdatedAt: FieldValue.serverTimestamp(),
      });
    }

    // ── Get display name ──────────────────────────────────────────────────────
    const userDoc = await getDb().collection("users").doc(uid).get();
    const userName =
      userDoc.data()?.displayName ?? userDoc.data()?.name ?? "Passenger";

    // ── Generate unique transaction ID ────────────────────────────────────────
    const transactionId = generateTransactionId("CTS-TOPUP");

    // ── Create payment doc BEFORE calling Bridge ──────────────────────────────
    // bridgeTopUpCallback does .get() on this doc — must exist before callback fires
    const paymentRef = getDb().collection("payments").doc(transactionId);
    await paymentRef.set({
      transactionId,
      userId: uid,
      userName,
      phone: intlPhone,
      network: mappedNetwork,
      amount,
      currency: "GHS",
      type: "topup",
      status: "pending",
      bridgeStatus: null,
      bridgeTransId: null,
      callbackPayload: null,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // ── Call Bridge /make_payment ─────────────────────────────────────────────
    const requestTime = new Date()
      .toISOString()
      .replace("T", " ")
      .split(".")[0];
    let bridgeResponse;

    try {
      bridgeResponse = await axios.post(
        `${target.apiBase}/make_payment`,
        {
          service_id: Number(BRIDGE_SERVICE_ID.value()),
          reference: userName,
          customer_number: intlPhone,
          transaction_id: transactionId,
          trans_type: "CTM", // Collection from customer (top-up)
          amount,
          nw: mappedNetwork,
          nickname: userName,
          payment_option: "MOM",
          currency_code: "GHS",
          currency_val: amount,
          callback_url: target.callbackUrl,
          request_time: requestTime,
        },
        {
          headers: getBridgeHeaders(
            BRIDGE_CLIENT_KEY.value(),
            BRIDGE_SECRET_KEY.value(),
          ),
        },
      );
    } catch (err) {
      // Bridge unreachable — mark failed so polling doesn't spin forever
      await paymentRef.update({
        status: "failed",
        failureReason: err.message,
        updatedAt: FieldValue.serverTimestamp(),
      });
      throw new HttpsError(
        "unavailable",
        "Could not reach payment service. Please try again.",
      );
    }

    const responseCode = bridgeResponse?.data?.response_code ?? "500";
    const responseMsg =
      bridgeResponse?.data?.response_message ?? "Unknown error";
    const accepted = new Set(["000", "202"]).has(responseCode);

    await paymentRef.update({
      bridgeCode: responseCode,
      bridgeMessage: responseMsg,
      status: accepted ? "pending" : "failed",
      updatedAt: FieldValue.serverTimestamp(),
    });

    if (!accepted) {
      const errorMessages = {
        402: "Insufficient balance in payment gateway. Please contact support.",
        "016": "Amount exceeds the allowed limit.",
        "019": "Phone number not registered for mobile money on this network.",
        219: "Duplicate payment. Please try again in a moment.",
        100: "Payment authentication failed. Please contact support.",
        429: "Too many requests. Please wait a moment and try again.",
      };
      throw new HttpsError(
        "failed-precondition",
        errorMessages[responseCode] ??
          `Payment could not be initiated (${responseCode}). Please try again.`,
      );
    }

    console.log(
      `[initiateBridgeTopUp] ✅ ${transactionId} | ${responseCode} | GHS${amount} → ${intlPhone}`,
    );

    return { success: true, transactionId };
  },
);

// ── bridgeTopUpCallback ────────────────────────────────────────────────────────
// HTTP webhook — Bridge calls this when the MoMo transaction settles
// Atomically credits wallets/{uid}.balance on trans_status "000"
// Credits only after verifyBridgeCallback confirms the callback (see below)

exports.bridgeTopUpCallback = onRequest(
  { region: "europe-west2", cors: false },
  async (req, res) => {
    const { trans_ref, trans_status, trans_id, amount } = req.body;
    console.log("[bridgeTopUpCallback]:", JSON.stringify(req.body, null, 2));

    // ── 1. Validate payload ───────────────────────────────────────────────────
    if (!trans_ref || !trans_status) {
      return res
        .status(400)
        .json({ success: false, message: "Invalid payload" });
    }

    // ── 2. Fetch payment document ─────────────────────────────────────────────
    const paymentRef = getDb().collection("payments").doc(trans_ref);
    let paymentSnap;
    try {
      paymentSnap = await paymentRef.get();
    } catch (err) {
      console.error("[bridgeTopUpCallback] Firestore read failed:", err);
      return res
        .status(500)
        .json({ success: false, message: "Database read failed" });
    }

    if (!paymentSnap.exists) {
      // Not our payment — acknowledge so Bridge stops retrying
      console.warn(
        `[bridgeTopUpCallback] ${trans_ref} not found — acknowledging`,
      );
      return res.status(200).json({ success: true, note: "not_found" });
    }

    const payment = paymentSnap.data();

    // ── 3. Authenticity: unverified callbacks are recorded, never applied ────
    const verification = verifyBridgeCallback(req, payment);
    if (!verification.verified) {
      try {
        await recordUnverifiedCallback("topup", req, paymentRef, verification.reason);
      } catch (err) {
        console.error("[bridgeTopUpCallback] record failed:", err);
        return res.status(500).json({ success: false, message: "Database write failed" });
      }
      console.warn(`[bridgeTopUpCallback] ${trans_ref}: unverified callback recorded, not applied`);
      return res.status(200).json({ success: true, note: "recorded_unverified" });
    }

    // ── 3b. Duplicate guard ───────────────────────────────────────────────────
    if (payment.status === "success" && payment.bridgeTransId === trans_id) {
      console.log(`[bridgeTopUpCallback] ${trans_ref} already processed`);
      return res.status(200).json({ success: true, note: "already_processed" });
    }

    // ── 4. Write Firestore FIRST, respond to Bridge, then send FCM ───────────
    try {
      if (trans_status === "000") {
        // SUCCESS — atomically credit wallet
        const userId = payment.userId;
        // Credit the amount recorded when the top-up was initiated, never a
        // figure taken from the callback body (PT-02). A callback reporting a
        // different amount credits nothing and is held for review.
        const recorded = Number(payment.amount);
        const reported = amount === undefined || amount === null || amount === ""
          ? null : Number(amount);
        if (!(recorded > 0) ||
            (reported !== null && Math.round(reported * 100) !== Math.round(recorded * 100))) {
          await paymentRef.update({
            status: "amount_mismatch",
            bridgeStatus: trans_status,
            bridgeTransId: trans_id ?? null,
            callbackPayload: req.body,
            updatedAt: FieldValue.serverTimestamp(),
          });
          await getDb().collection("admin_alerts").add({
            type: "topup_amount_mismatch",
            transactionId: trans_ref,
            recordedAmount: Number.isFinite(recorded) ? recorded : null,
            reportedAmount: Number.isFinite(reported) ? reported : null,
            createdAt: FieldValue.serverTimestamp(),
          });
          console.warn(`[bridgeTopUpCallback] ${trans_ref}: amount mismatch, not credited`);
          return res.status(200).json({ success: true, note: "amount_mismatch" });
        }
        const amountGhs = recorded;
        const walletRef = getDb().collection("wallets").doc(userId);

        await getDb().runTransaction(async (tx) => {
          // Terminal guard inside the transaction: a concurrent or replayed
          // success callback (even with a different trans_id) sees "success".
          const fresh = await tx.get(paymentRef);
          if (fresh.data()?.status === "success") return;

          // Ledger-level idempotency check
          const idempotencyKey = `bridge_topup_${trans_ref}`;
          const existing = await getDb()
            .collection("ledger")
            .where("idempotencyKey", "==", idempotencyKey)
            .limit(1)
            .get();
          if (!existing.empty) {
            console.log(
              `[bridgeTopUpCallback] Ledger already has ${trans_ref}`,
            );
            return; // Already processed — exit transaction cleanly
          }

          // Credit wallet
          const wallet = await tx.get(walletRef);
          if (!wallet.exists) {
            tx.set(walletRef, {
              userId,
              balance: amountGhs,
              heldBalance: 0,
              currency: "GHS",
              isActive: true,
              createdAt: FieldValue.serverTimestamp(),
              lastUpdatedAt: FieldValue.serverTimestamp(),
            });
          } else {
            tx.update(walletRef, {
              balance: FieldValue.increment(amountGhs),
              lastUpdatedAt: FieldValue.serverTimestamp(),
            });
          }

          // Update payment record
          tx.update(paymentRef, {
            status: "success",
            bridgeStatus: trans_status,
            bridgeTransId: trans_id,
            amountPaid: amountGhs,
            paidAt: FieldValue.serverTimestamp(),
            callbackPayload: req.body,
            updatedAt: FieldValue.serverTimestamp(),
          });

          // Immutable ledger entry
          await writeLedger(tx, {
            type: "TOPUP",
            status: "COMPLETED",
            toUserId: userId,
            toType: "passenger",
            fromType: "bridge_momo",
            amount: amountGhs,
            currency: "GHS",
            platformFee: 0,
            driverNet: 0,
            referenceType: "topup",
            referenceId: trans_ref,
            bridgeRef: trans_id,
            idempotencyKey,
            processedAt: FieldValue.serverTimestamp(),
          });
        });

        console.log(
          `[bridgeTopUpCallback] ✅ Credited: ${userId} +GHS${amountGhs}`,
        );

        // ── 5. Respond 200 to Bridge BEFORE FCM ──────────────────────────────
        // Bridge considers callback delivered on 200. FCM must never block this.
        res.status(200).json({ success: true });

        // ── 6. FCM — non-blocking, isolated try-catch ─────────────────────────
        try {
          const userDoc = await getDb().collection("users").doc(userId).get();
          const fcmToken = userDoc.data()?.fcmToken;
          if (fcmToken) {
            await admin.messaging().send({
              token: fcmToken,
              notification: {
                title: "💰 Wallet Topped Up!",
                body: `GH₵${amountGhs.toFixed(2)} added to your CTS wallet.`,
              },
              data: { type: "wallet_topup", amount: String(amountGhs) },
            });
          }
        } catch (fcmErr) {
          console.warn(
            "[bridgeTopUpCallback] FCM failed (non-fatal):",
            fcmErr.message,
          );
        }
      } else {
        // FAILED (001) / PENDING (002) / CANCELLED (003)
        const localStatus = STATUS_MAP[trans_status] ?? "unknown";
        // A success is terminal: a later failure or pending callback never
        // overwrites it (PT-06).
        await getDb().runTransaction(async (tx) => {
          const fresh = await tx.get(paymentRef);
          if (fresh.data()?.status === "success") return;
          tx.update(paymentRef, {
            status: localStatus,
            bridgeStatus: trans_status,
            bridgeTransId: trans_id ?? null,
            callbackPayload: req.body,
            updatedAt: FieldValue.serverTimestamp(),
          });
        });
        console.log(`[bridgeTopUpCallback] ${trans_ref} → ${localStatus}`);
        res.status(200).json({ success: true });
      }
    } catch (err) {
      // Firestore write failed — return 500 so Bridge retries
      console.error("[bridgeTopUpCallback] ❌ Firestore write failed:", err);
      return res
        .status(500)
        .json({ success: false, message: "Database write failed" });
    }
  },
);

// ── checkBridgeTopUpStatus ─────────────────────────────────────────────────────
// Callable — Flutter polls this every 5s while showing the "Approve on your phone" UI
// Reads from payments/{transactionId} which bridgeTopUpCallback writes

exports.checkBridgeTopUpStatus = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
    const uid = requireAuth(request);
    const { transactionId } = request.data;

    if (!transactionId) {
      throw new HttpsError("invalid-argument", "transactionId required");
    }

    const snap = await getDb().collection("payments").doc(transactionId).get();

    if (!snap.exists) {
      // Callback hasn't arrived yet — stay pending
      return { localStatus: "pending", status: null, amount: null };
    }

    const payment = snap.data();

    // Security: passengers can only check their own payments
    if (payment.userId !== uid) {
      throw new HttpsError("permission-denied", "Not your payment");
    }

    return {
      localStatus: payment.status, // "pending" | "success" | "failed" | "cancelled"
      status: payment.bridgeStatus, // Bridge raw code e.g. "000"
      amount: payment.amountPaid ?? null,
      transactionId: payment.bridgeTransId ?? transactionId,
      // Bridge has reported a result for this top-up that cannot be
      // verified yet: it stays pending and is credited only once confirmed.
      // The app must tell the customer not to pay again.
      awaitingVerification: payment.status === "pending" && payment.lastCallbackStatus != null,
    };
  },
);

// ── initiateBridgePayout ───────────────────────────────────────────────────────
// Callable — passenger OR driver withdraws to MoMo immediately via Bridge MTC
// Replaces the manual withdrawal queue — money goes out in real time
// Role detection: checks drivers/{uid} first, then wallets/{uid}

exports.initiateBridgePayout = onCall(
  {
    region: "europe-west2",
    minInstances: 0,
    secrets: [BRIDGE_CLIENT_KEY, BRIDGE_SECRET_KEY, BRIDGE_SERVICE_ID],
  },
  async (request) => {
    const uid = requireAuth(request);
    const { amount, phone, network } = request.data;

    // ── Validate ──────────────────────────────────────────────────────────────
    if (!amount || typeof amount !== "number" || amount < 10) {
      throw new HttpsError(
        "invalid-argument",
        "Minimum withdrawal is GH₵10.00",
      );
    }
    if (!phone)
      throw new HttpsError("invalid-argument", "Phone number required");
    if (!network)
      throw new HttpsError("invalid-argument", "MoMo network required");

    const mappedNetwork = NETWORK_MAP[network.toUpperCase()];
    if (!mappedNetwork) {
      throw new HttpsError("invalid-argument", `Invalid network: ${network}`);
    }

    const intlPhone = toInternational(phone);
    if (!intlPhone) {
      throw new HttpsError("invalid-argument", "Invalid Ghana mobile number");
    }

    // ── Where this environment may send the payout (fails closed) ───────────
    // Checked before any read-modify-write: a refused environment must never
    // hold funds it cannot pay out. _sendBridgePayout checks again at send.
    resolveBridgeTarget("bridgePayoutCallback");

    const db = getDb();

    // ── Platform limits ───────────────────────────────────────────────────────
    const settingsDoc = await db.collection("settings").doc("platform").get();
    const minWithdrawal = settingsDoc.data()?.minWithdrawalAmount ?? 10;
    const maxWithdrawal = settingsDoc.data()?.maxWithdrawalAmount ?? 5000;

    if (amount < minWithdrawal) {
      throw new HttpsError(
        "invalid-argument",
        `Minimum withdrawal is GH₵${minWithdrawal}`,
      );
    }
    if (amount > maxWithdrawal) {
      throw new HttpsError(
        "invalid-argument",
        `Maximum withdrawal is GH₵${maxWithdrawal}`,
      );
    }

   // ── Driver-only: passengers must never withdraw (laundering vector) ────────
    const driverDoc = await db.collection("drivers").doc(uid).get();
    if (!driverDoc.exists) {
      throw new HttpsError(
        "permission-denied",
        "Withdrawals are only available to drivers.",
      );
    }
    const isDriver = true;

    // ── Approved, non-suspended drivers only ──────────────────────────────────
    const dData = driverDoc.data() ?? {};
    if (dData.isApproved !== true || dData.signupStep === "suspended") {
      throw new HttpsError(
        "permission-denied",
        "Your account is not approved for withdrawals.",
      );
    }

    const userName = dData.displayName ?? "Driver";

    // ── Idempotency: block if pending withdrawal exists ───────────────────────
    const pending = await db
      .collection("withdrawals")
      .where("userId", "==", uid)
      .where("status", "==", "pending")
      .limit(1)
      .get();

    if (!pending.empty) {
      throw new HttpsError(
        "failed-precondition",
        "You have a pending withdrawal. Please wait for it to complete.",
      );
    }

    const transactionId = generateTransactionId("CTS-PAYOUT");
    const withdrawalRef = db.collection("withdrawals").doc();
    const txRef = db.collection("transactions").doc();


    // ── Daily cap + velocity (anti-laundering throughput limit) ───────────────
    const startOfDay = new Date();
    startOfDay.setHours(0, 0, 0, 0);

    const todays = await db
      .collection("withdrawals")
      .where("userId", "==", uid)
      .where("createdAt", ">=", startOfDay)
      .get();

    const dailyCap =
      settingsDoc.data()?.dailyWithdrawalCap ?? 5000;
    const maxPerDay =
      settingsDoc.data()?.maxWithdrawalsPerDay ?? 3;

    // Count only non-failed withdrawals toward the caps.
    const counted = todays.docs.filter(
      (d) => d.data().status !== "failed",
    );
    const todayTotal = counted.reduce(
      (s, d) => s + (d.data().amount || 0),
      0,
    );

    if (counted.length >= maxPerDay) {
      throw new HttpsError(
        "resource-exhausted",
        `Daily withdrawal limit reached (${maxPerDay} per day). Try again tomorrow.`,
      );
    }
    if (todayTotal + amount > dailyCap) {
      throw new HttpsError(
        "resource-exhausted",
        `Daily withdrawal cap reached. Remaining today: GH₵${(dailyCap - todayTotal).toFixed(2)}`,
      );
    }

    // ── Atomically deduct balance + create records ────────────────────────────
    try {
      await db.runTransaction(async (tx) => {
        if (isDriver) {
          const driver = await tx.get(driverDoc.ref);
          const d = driver.data() ?? {};
          // One open withdrawal per driver, enforced atomically: the pending
          // query above is only a fast path, and concurrent requests both
          // pass it. activeWithdrawalId is server-only (drivers rules) and
          // is cleared when the withdrawal is rejected, refunded or paid.
          if (d.activeWithdrawalId) {
            throw new HttpsError(
              "failed-precondition",
              "You have a withdrawal in progress. Please wait for it to complete.",
            );
          }
          // Only walletBalance can be paid out: it is credited server-side
          // when a wallet-paid job settles (releaseEscrow, legacy wallet
          // settlement) and is the withdrawable figure the Driver app shows.
          // totalEarnings is a lifetime counter that also includes the full
          // fare of every cash job, cash the driver already holds, so it
          // never stands in for a missing walletBalance.
          const walletBalance  = typeof d.walletBalance === "number" &&
            Number.isFinite(d.walletBalance) ? d.walletBalance : 0;
          const commissionOwed = d.commissionOwed ?? 0;

          // ── Settle outstanding cash-job commission BEFORE withdrawal ──────
          // Cash fares were pocketed physically by the driver; the platform's
          // cut is collected here, from wallet (escrow-paid) earnings.
          const settled = Math.min(commissionOwed, walletBalance);
          const withdrawable =
            Math.round((walletBalance - settled) * 100) / 100;

          if (withdrawable < amount) {
            throw new HttpsError(
              "failed-precondition",
              commissionOwed > 0
                ? `Insufficient balance. GH₵${settled.toFixed(2)} outstanding commission was deducted; withdrawable: GH₵${withdrawable.toFixed(2)}`
                : `Insufficient earnings. Available: GH₵${withdrawable.toFixed(2)}`,
            );
          }

          tx.update(driverDoc.ref, {
            walletBalance:     FieldValue.increment(-(amount + settled)),
            totalEarnings:     FieldValue.increment(-amount),
            commissionOwed:    FieldValue.increment(-settled),
            pendingWithdrawal: FieldValue.increment(amount),
            activeWithdrawalId: withdrawalRef.id,
            updatedAt:         FieldValue.serverTimestamp(),
          });

          // Ledger: commission collected is reportable platform revenue
          if (settled > 0) {
            await writeLedger(tx, {
              type:           "COMMISSION_SETTLED",
              status:         "COMPLETED",
              fromUserId:     uid,
              fromType:       "driver",
              toType:         "platform",
              amount:         settled,
              currency:       "GHS",
              platformFee:    settled,
              driverNet:      0,
              referenceType:  "withdrawal",
              referenceId:    transactionId,
              idempotencyKey: `commission_settle_${transactionId}`,
              processedAt:    FieldValue.serverTimestamp(),
            });
          }
        }

        // Withdrawal record — status:"pending" until callback
        tx.set(withdrawalRef, {
          id: withdrawalRef.id,
          userId: uid,
          userName,
          role: "driver",
          amount,
          currency: "GHS",
          phone: intlPhone,
          network: mappedNetwork,
          method: "mobile_money",
          status: "pending",
          // Every payout is reviewed by an admin (approveWithdrawal /
          // rejectWithdrawal); nothing is paid automatically.
          needsReview: true,
          reviewReason: "admin_review_required",
          bridgeTransId: transactionId,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });

        tx.set(db.collection("audit_log").doc(), {
          action: "withdrawal_requested", withdrawalId: withdrawalRef.id,
          driverId: uid, amount, createdAt: FieldValue.serverTimestamp(),
        });

        // Transaction record — visible in history immediately
        tx.set(txRef, {
          id: txRef.id,
          userId: uid,
          type: "debit",
          category: "withdrawal",
          amount,
          currency: "GHS",
          status: "pending",
          description: `MoMo withdrawal — ${mappedNetwork} ${intlPhone}`,
          reference: transactionId,
          createdAt: FieldValue.serverTimestamp(),
        });
      });
    } catch (txnErr) {
      if (txnErr instanceof HttpsError) throw txnErr;
      console.error("[initiateBridgePayout] Transaction failed:", txnErr);
      throw new HttpsError(
        "internal",
        "Could not process withdrawal. Please try again.",
      );
    }

    // Money is HELD (walletBalance debited, pendingWithdrawal incremented,
    // activeWithdrawalId set) and the request is queued for admin review in
    // the same transaction. Payouts are reviewed only: there is no automatic
    // payout path (the previous one called helpers that were never defined
    // here, and failed after holding the funds, PT-12).
    return {
      success: true,
      status: "pending_review",
      withdrawalId: withdrawalRef.id,
      message: "Withdrawal submitted for review. You'll be paid once approved.",
    };
  },
);


// ── bridgePayoutCallback ───────────────────────────────────────────────────────
// HTTP webhook — Bridge calls this when payout settles
// On success: marks withdrawal complete
// On failure: atomically refunds the deducted balance

exports.bridgePayoutCallback = onRequest(
  { region: "europe-west2", cors: false },
  async (req, res) => {
    const { trans_ref, trans_status, trans_id, amount } = req.body;
    console.log("[bridgePayoutCallback]:", JSON.stringify(req.body, null, 2));

    if (!trans_ref || !trans_status) {
      return res
        .status(400)
        .json({ success: false, message: "Invalid payload" });
    }

    const paymentRef = getDb().collection("payments").doc(trans_ref);
    let paymentSnap;
    try {
      paymentSnap = await paymentRef.get();
    } catch (err) {
      console.error("[bridgePayoutCallback] Firestore read failed:", err);
      return res
        .status(500)
        .json({ success: false, message: "Database read failed" });
    }

    if (!paymentSnap.exists) {
      console.warn(
        `[bridgePayoutCallback] ${trans_ref} not found — acknowledging`,
      );
      return res.status(200).json({ success: true, note: "not_found" });
    }

    const payment = paymentSnap.data();

    // Authenticity: unverified callbacks are recorded, never applied.
    const verification = verifyBridgeCallback(req, payment);
    if (!verification.verified) {
      try {
        await recordUnverifiedCallback("payout", req, paymentRef, verification.reason);
      } catch (err) {
        console.error("[bridgePayoutCallback] record failed:", err);
        return res.status(500).json({ success: false, message: "Database write failed" });
      }
      console.warn(`[bridgePayoutCallback] ${trans_ref}: unverified callback recorded, not applied`);
      return res.status(200).json({ success: true, note: "recorded_unverified" });
    }

    // Duplicate guard — already in terminal state
    if (["success", "failed"].includes(payment.status)) {
      return res.status(200).json({ success: true, note: "already_processed" });
    }

    const db = getDb();

    try {
      if (trans_status === "000") {
        // ── SUCCESS — mark withdrawal complete ────────────────────────────────
        await db.runTransaction(async (tx) => {
          // Re-checked inside the transaction: concurrent duplicates settle once.
          const fresh = await tx.get(paymentRef);
          if (["success", "failed"].includes(fresh.data()?.status)) return;
          tx.update(paymentRef, {
            status: "success",
            bridgeStatus: trans_status,
            bridgeTransId: trans_id,
            paidAt: FieldValue.serverTimestamp(),
            callbackPayload: req.body,
            updatedAt: FieldValue.serverTimestamp(),
          });

          if (payment.withdrawalId) {
            tx.update(db.collection("withdrawals").doc(payment.withdrawalId), {
              status: "completed",
              completedAt: FieldValue.serverTimestamp(),
            });
          }

          if (payment.txId) {
            tx.update(db.collection("transactions").doc(payment.txId), {
              status: "completed",
              completedAt: FieldValue.serverTimestamp(),
            });
          }

          // Clear driver's pendingWithdrawal counter
          if (payment.role === "driver") {
            tx.update(db.collection("drivers").doc(payment.userId), {
              pendingWithdrawal: FieldValue.increment(-payment.amount),
              updatedAt: FieldValue.serverTimestamp(),
            });
          }

          await writeLedger(tx, {
            type: "PAYOUT",
            status: "COMPLETED",
            fromType: "platform",
            toUserId: payment.userId,
            toType: payment.role,
            amount: payment.amount,
            currency: "GHS",
            platformFee: 0,
            driverNet: payment.amount,
            referenceType: "withdrawal",
            referenceId: trans_ref,
            bridgeRef: trans_id,
            idempotencyKey: `bridge_payout_${trans_ref}`,
            processedAt: FieldValue.serverTimestamp(),
          });
        });

        console.log(
          `[bridgePayoutCallback] ✅ Payout complete: ${trans_ref} GHS${amount}`,
        );
        res.status(200).json({ success: true });

        // FCM — after response
        try {
          const collection = payment.role === "driver" ? "drivers" : "users";
          const userDoc = await db
            .collection(collection)
            .doc(payment.userId)
            .get();
          const fcmToken = userDoc.data()?.fcmToken;
          if (fcmToken) {
            await admin.messaging().send({
              token: fcmToken,
              notification: {
                title: "💸 Withdrawal Successful!",
                body: `GH₵${Number(payment.amount).toFixed(2)} sent to your MoMo account.`,
              },
              data: {
                type: "withdrawal_success",
                amount: String(payment.amount),
              },
            });
          }
        } catch (fcmErr) {
          console.warn(
            "[bridgePayoutCallback] FCM failed (non-fatal):",
            fcmErr.message,
          );
        }
      } else if (["001", "003"].includes(trans_status)) {
        // ── FAILED or CANCELLED — refund atomically ───────────────────────────
        await db.runTransaction(async (tx) => {
          // Re-checked inside the transaction: concurrent duplicate failure
          // callbacks refund once (PT-08).
          const fresh = await tx.get(paymentRef);
          if (["success", "failed"].includes(fresh.data()?.status)) return;
          tx.update(paymentRef, {
            status: "failed",
            bridgeStatus: trans_status,
            bridgeTransId: trans_id ?? null,
            callbackPayload: req.body,
            updatedAt: FieldValue.serverTimestamp(),
          });

          if (payment.withdrawalId) {
            tx.update(db.collection("withdrawals").doc(payment.withdrawalId), {
              status: "failed",
              failedAt: FieldValue.serverTimestamp(),
            });
          }

          if (payment.txId) {
            tx.update(db.collection("transactions").doc(payment.txId), {
              status: "failed",
              failedAt: FieldValue.serverTimestamp(),
            });
          }

          // Restore balance
          if (payment.role === "driver") {
            tx.update(db.collection("drivers").doc(payment.userId), {
  totalEarnings:     FieldValue.increment(payment.amount),
  walletBalance:     FieldValue.increment(payment.amount),  // ← refund both
  pendingWithdrawal: FieldValue.increment(-payment.amount),
  updatedAt:         FieldValue.serverTimestamp(),
});
          } else {
            tx.update(db.collection("wallets").doc(payment.userId), {
              balance: FieldValue.increment(payment.amount),
              updatedAt: FieldValue.serverTimestamp(),
            });
          }

          await writeLedger(tx, {
            type: "REFUND",
            status: "COMPLETED",
            fromType: "platform",
            toUserId: payment.userId,
            toType: payment.role,
            amount: payment.amount,
            currency: "GHS",
            platformFee: 0,
            driverNet: 0,
            referenceType: "withdrawal_refund",
            referenceId: trans_ref,
            idempotencyKey: `bridge_payout_refund_${trans_ref}`,
            processedAt: FieldValue.serverTimestamp(),
          });
        });

        console.log(
          `[bridgePayoutCallback] ❌ Payout failed → refunded: ${trans_ref}`,
        );
        res.status(200).json({ success: true });

        // FCM — notify failure + refund
        try {
          const collection = payment.role === "driver" ? "drivers" : "users";
          const userDoc = await db
            .collection(collection)
            .doc(payment.userId)
            .get();
          const fcmToken = userDoc.data()?.fcmToken;
          if (fcmToken) {
            await admin.messaging().send({
              token: fcmToken,
              notification: {
                title: "Withdrawal Failed",
                body: `GH₵${Number(payment.amount).toFixed(2)} could not be sent. Your balance has been restored.`,
              },
              data: { type: "withdrawal_failed" },
            });
          }
        } catch (fcmErr) {
          console.warn(
            "[bridgePayoutCallback] FCM failed (non-fatal):",
            fcmErr.message,
          );
        }
      } else {
        // Still pending (002)
        await paymentRef.update({
          bridgeStatus: trans_status,
          updatedAt: FieldValue.serverTimestamp(),
        });
        res.status(200).json({ success: true });
      }
    } catch (err) {
      console.error("[bridgePayoutCallback] ❌ Firestore write failed:", err);
      return res
        .status(500)
        .json({ success: false, message: "Database write failed" });
    }
  },
);

// ── Shared internals for withdrawal_approval.js ──
exports._bridgeShared = {
  BRIDGE_CLIENT_KEY, BRIDGE_SECRET_KEY, BRIDGE_SERVICE_ID,
  resolveBridgeTarget,
  getBridgeHeaders,
};

