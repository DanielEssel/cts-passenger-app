// functions/wallet.js
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret }       = require("firebase-functions/params");
const admin                  = require("firebase-admin");
const axios                  = require("axios");

const getDb          = () => admin.firestore();
const PAYSTACK_BASE  = "https://api.paystack.co";
const paystackSecret = defineSecret("PAYSTACK_SECRET_KEY");

// ── Helpers ───────────────────────────────────────────────────────────────────

function requireAuth(request) {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Login required");
  }
  return request.auth.uid;
}

async function getRole(uid) {
  // Check drivers collection first
  const driverDoc = await getDb().collection("drivers").doc(uid).get();
  if (driverDoc.exists) return { role: "driver", data: driverDoc.data() };

  // Check users collection
  const userDoc = await getDb().collection("users").doc(uid).get();
  if (userDoc.exists) return { role: "passenger", data: userDoc.data() };

  return { role: "unknown", data: {} };
}

function validateAmount(amount, min = 1) {
  if (!amount || typeof amount !== "number" || amount < min) {
    throw new HttpsError(
      "invalid-argument",
      `Minimum amount is GH₵ ${min.toFixed(2)}`
    );
  }
}

// ── createWallet ──────────────────────────────────────────────────────────────
// Passengers only — drivers earn through trip completions

exports.createWallet = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
  const uid       = requireAuth(request);
  const walletRef = getDb().collection("wallets").doc(uid);

  return getDb().runTransaction(async (t) => {
    const existing = await t.get(walletRef);
    if (existing.exists) return existing.data();

    const wallet = {
      userId:    uid,
      email:     request.data.email ?? request.auth.token?.email ?? `${uid}@cts.app`,
      balance:   0,
      currency:  "GHS",
      isActive:  true,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    t.set(walletRef, wallet);
    return wallet;
  });
});

// ── getWalletBalance ──────────────────────────────────────────────────────────

exports.getWalletBalance = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
  const uid = requireAuth(request);
  const { role, data } = await getRole(uid);

  if (role === "driver") {
    return {
      balance:        data.totalEarnings   ?? 0,
      todayEarnings:  data.todayEarnings   ?? 0,
      completedTrips: data.completedTrips  ?? 0,
      currency:       "GHS",
      role:           "driver",
    };
  }

  const doc = await getDb().collection("wallets").doc(uid).get();
  if (!doc.exists) {
    throw new HttpsError("not-found", "Wallet not found");
  }
  return { ...doc.data(), role: "passenger" };
});

// ── initializePaystackPayment ─────────────────────────────────────────────────
// Passengers only

exports.initializePaystackPayment = onCall(
  { region: "europe-west2", minInstances: 0, secrets: [paystackSecret] },
  async (request) => {
    const uid    = requireAuth(request);
    const secret = paystackSecret.value();
    const { amount, email, paymentMethod } = request.data;

    validateAmount(amount, 1);

    if (!email) {
      throw new HttpsError("invalid-argument", "Email required for payment");
    }

    // Ensure passenger wallet exists
    const walletRef = getDb().collection("wallets").doc(uid);
    const wallet    = await walletRef.get();
    if (!wallet.exists) {
      await walletRef.set({
        userId:    uid,
        email,
        balance:   0,
        currency:  "GHS",
        isActive:  true,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Create pending transaction with idempotency key
    const idempotencyKey = `topup_${uid}_${Date.now()}`;
    const txRef = getDb().collection("transactions").doc(idempotencyKey);

    const txSnap = await txRef.get();
    if (txSnap.exists && txSnap.data()?.status === "completed") {
      throw new HttpsError("already-exists", "Payment already processed");
    }

    await txRef.set({
      id:             idempotencyKey,
      userId:         uid,
      type:           "credit",
      category:       "top_up",
      amount,
      currency:       "GHS",
      status:         "pending",
      description:    `Wallet top-up — GH₵ ${amount.toFixed(2)}`,
      reference:      null,
      idempotencyKey,
      createdAt:      admin.firestore.FieldValue.serverTimestamp(),
    });

    try {
      const response = await axios.post(
        `${PAYSTACK_BASE}/transaction/initialize`,
        {
          email,
          amount:       Math.round(amount * 100),
          currency:     "GHS",
          callback_url: "https://ctstransportapp.web.app/payment/callback",
          channels: ["mobile_money", "card", "bank", "ussd"],
          channels:     paymentMethod === "mobile_money"
              ? ["mobile_money"] : ["card"],
          metadata: {
            userId:           uid,
            transactionDocId: idempotencyKey,
            type:             "wallet_topup",
          },
        },
        {
          headers: {
            Authorization:  `Bearer ${secret}`,
            "Content-Type": "application/json",
          },
        }
      );

      const { authorization_url, reference } = response.data.data;
      await txRef.update({ reference });
      return { authorization_url, reference, transactionDocId: idempotencyKey };
    } catch (err) {
      await txRef.update({ status: "failed", failedAt: admin.firestore.FieldValue.serverTimestamp() });
      throw new HttpsError(
        "internal",
        err.response?.data?.message ?? "Failed to initialize payment"
      );
    }
  }
);

// ── verifyPaystackPayment ─────────────────────────────────────────────────────

exports.verifyPaystackPayment = onCall(
  { region: "europe-west2", minInstances: 0, secrets: [paystackSecret] },
  async (request) => {
    // ⚠️  Deprecated: wallet credits are now handled exclusively by
    // the paystackWebhook Cloud Function (HMAC-verified).
    // This callable is kept for backwards compatibility but does
    // NOT credit the wallet — it only returns the payment status.
    const uid       = requireAuth(request);
    const secret    = paystackSecret.value();
    const { reference } = request.data;

    if (!reference) {
      throw new HttpsError("invalid-argument", "Payment reference required");
    }

    // Verify with Paystack
    let paystackData;
    try {
      const response = await axios.get(
        `${PAYSTACK_BASE}/transaction/verify/${reference}`,
        { headers: { Authorization: `Bearer ${secret}` } }
      );
      paystackData = response.data.data;
    } catch (err) {
      throw new HttpsError("internal", "Could not verify payment with Paystack");
    }

    if (paystackData.status !== "success") {
      throw new HttpsError("failed-precondition", "Payment was not successful");
    }

    const amountPaid = paystackData.amount / 100;
    const walletRef  = getDb().collection("wallets").doc(uid);

    // Find transaction by reference
    const txSnap = await getDb()
      .collection("transactions")
      .where("reference", "==", reference)
      .where("userId",    "==", uid)
      .limit(1)
      .get();

    if (txSnap.empty) {
      throw new HttpsError("not-found", "Transaction record not found");
    }

    const txRef  = txSnap.docs[0].ref;
    const txData = txSnap.docs[0].data();

    // Idempotent — already processed
    if (txData.status === "completed") {
      return { success: true, alreadyProcessed: true };
    }

    // Wallet credit is handled by paystackWebhook — not here
    // Just return payment status for UI confirmation
    return {
      success:        true,
      alreadyProcessed: txData.status === "completed",
      amount:         amountPaid,
      message:        "Payment verified. Wallet will be credited via webhook.",
    };
  }
);

// ── deductWalletBalance ───────────────────────────────────────────────────────
// Passengers only — deducts from wallets/{uid}

exports.deductWalletBalance = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
  // ⚠️  Deprecated: wallet deductions now happen via escrow release in trips.js
  // This CF is disabled to prevent client-side wallet manipulation
  throw new HttpsError("permission-denied", "Direct wallet deduction is disabled. Payments are processed automatically on trip completion.");
  // eslint-disable-next-line no-unreachable
  const uid = requireAuth(request);
  const { amount, description, category } = request.data;

  validateAmount(amount);

  const walletRef = getDb().collection("wallets").doc(uid);

  await getDb().runTransaction(async (t) => {
    const walletDoc = await t.get(walletRef);

    if (!walletDoc.exists) {
      throw new HttpsError("not-found", "Wallet not found");
    }

    const balance = walletDoc.data()?.balance ?? 0;
    if (balance < amount) {
      throw new HttpsError(
        "failed-precondition",
        `Insufficient balance. Available: GH₵ ${balance.toFixed(2)}`
      );
    }

    const txRef = getDb().collection("transactions").doc();

    t.update(walletRef, {
      balance:   balance - amount,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    t.set(txRef, {
      id:          txRef.id,
      userId:      uid,
      type:        "debit",
      category:    category ?? "ride_payment",
      amount,
      currency:    "GHS",
      status:      "completed",
      description: description ?? `Payment — GH₵ ${amount.toFixed(2)}`,
      createdAt:   admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  return { success: true };
});

// ── getTransactionHistory ─────────────────────────────────────────────────────

exports.getTransactionHistory = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
  const uid   = requireAuth(request);
  const limit = Math.min(request.data.limit ?? 50, 100); // cap at 100

  const snap = await getDb()
    .collection("transactions")
    .where("userId", "==", uid)
    .orderBy("createdAt", "desc")
    .limit(limit)
    .get();

  return {
    transactions: snap.docs.map((doc) => ({ id: doc.id, ...doc.data() })),
  };
});

// ── requestWithdrawal ─────────────────────────────────────────────────────────
// Handles BOTH drivers (from totalEarnings) and passengers (from wallet balance)
// Production approach:
//   - Driver: deducts from drivers/{uid}.totalEarnings, creates withdrawal record
//   - Passenger: deducts from wallets/{uid}.balance
//   - Both: creates transaction record + withdrawal record for admin processing
//   - Idempotent: prevents duplicate submissions

exports.requestWithdrawal = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
  const uid = requireAuth(request);
  const { amount, method, phoneNumber, accountName } = request.data;

  // ── Validation ──────────────────────────────────────────────────────────
  validateAmount(amount, 10);

  if (!method) {
    throw new HttpsError("invalid-argument", "Payment method required");
  }
  if (!phoneNumber && !accountName) {
    throw new HttpsError("invalid-argument", "Phone number or account name required");
  }

  // ── Determine role ──────────────────────────────────────────────────────
  const { role } = await getRole(uid);

  if (role === "unknown") {
    throw new HttpsError("not-found", "User account not found");
  }

  const db = getDb();

  // ── Idempotency check — prevent duplicate withdrawals ───────────────────
  // Block if a pending withdrawal exists for this user
  const pendingSnap = await db
    .collection("withdrawals")
    .where("userId",  "==", uid)
    .where("status",  "==", "pending")
    .limit(1)
    .get();

  if (!pendingSnap.empty) {
    throw new HttpsError(
      "already-exists",
      "You have a pending withdrawal. Please wait for it to be processed."
    );
  }

  // ── Process based on role ───────────────────────────────────────────────
  if (role === "driver") {
    await _processDriverWithdrawal(db, uid, amount, method, phoneNumber, accountName);
  } else {
    await _processPassengerWithdrawal(db, uid, amount, method, phoneNumber, accountName);
  }

  return {
    success: true,
    message: "Withdrawal request submitted. Processing within 24 hours.",
  };
});

// ── Driver withdrawal ─────────────────────────────────────────────────────────
// Deducts from drivers/{uid}.totalEarnings

async function _processDriverWithdrawal(db, uid, amount, method, phoneNumber, accountName) {
  const driverRef     = db.collection("drivers").doc(uid);
  const withdrawalRef = db.collection("withdrawals").doc();
  const txRef         = db.collection("transactions").doc();

  await db.runTransaction(async (t) => {
    const driverDoc = await t.get(driverRef);

    if (!driverDoc.exists) {
      throw new HttpsError("not-found", "Driver account not found");
    }

    const totalEarnings = (driverDoc.data()?.totalEarnings ?? 0);
    const minBalance    = 0; // driver can withdraw everything

    if (totalEarnings < amount) {
      throw new HttpsError(
        "failed-precondition",
        `Insufficient earnings. Available: GH₵ ${totalEarnings.toFixed(2)}`
      );
    }

    // Deduct from earnings
    t.update(driverRef, {
      totalEarnings: totalEarnings - amount,
      updatedAt:     admin.firestore.FieldValue.serverTimestamp(),
    });

    // Transaction record (for history)
    t.set(txRef, {
      id:          txRef.id,
      userId:      uid,
      type:        "debit",
      category:    "withdrawal",
      amount,
      currency:    "GHS",
      status:      "pending",
      description: `Earnings withdrawal — ${method} ${phoneNumber ?? accountName ?? ""}`,
      method,
      phoneNumber:  phoneNumber ?? null,
      accountName:  accountName ?? null,
      role:        "driver",
      createdAt:   admin.firestore.FieldValue.serverTimestamp(),
    });

    // Withdrawal record (for admin processing)
    t.set(withdrawalRef, {
      id:          withdrawalRef.id,
      userId:      uid,
      role:        "driver",
      amount,
      currency:    "GHS",
      method,
      phoneNumber:  phoneNumber ?? null,
      accountName:  accountName ?? null,
      status:      "pending",
      txId:        txRef.id,
      createdAt:   admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}

// ── Passenger withdrawal ──────────────────────────────────────────────────────
// Deducts from wallets/{uid}.balance

async function _processPassengerWithdrawal(db, uid, amount, method, phoneNumber, accountName) {
  const walletRef     = db.collection("wallets").doc(uid);
  const withdrawalRef = db.collection("withdrawals").doc();
  const txRef         = db.collection("transactions").doc();

  await db.runTransaction(async (t) => {
    const walletDoc = await t.get(walletRef);

    if (!walletDoc.exists) {
      throw new HttpsError("not-found", "Wallet not found");
    }

    const balance = walletDoc.data()?.balance ?? 0;

    if (balance < amount) {
      throw new HttpsError(
        "failed-precondition",
        `Insufficient balance. Available: GH₵ ${balance.toFixed(2)}`
      );
    }

    t.update(walletRef, {
      balance:   balance - amount,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    t.set(txRef, {
      id:          txRef.id,
      userId:      uid,
      type:        "debit",
      category:    "withdrawal",
      amount,
      currency:    "GHS",
      status:      "pending",
      description: `Wallet withdrawal — ${method} ${phoneNumber ?? accountName ?? ""}`,
      method,
      phoneNumber:  phoneNumber ?? null,
      accountName:  accountName ?? null,
      role:        "passenger",
      createdAt:   admin.firestore.FieldValue.serverTimestamp(),
    });

    t.set(withdrawalRef, {
      id:          withdrawalRef.id,
      userId:      uid,
      role:        "passenger",
      amount,
      currency:    "GHS",
      method,
      phoneNumber:  phoneNumber ?? null,
      accountName:  accountName ?? null,
      status:      "pending",
      txId:        txRef.id,
      createdAt:   admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}

// ── approveDriver ─────────────────────────────────────────────────────────────

exports.approveDriver = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
  const uid = requireAuth(request);

  const adminDoc = await getDb().collection("admins").doc(uid).get();
  if (!adminDoc.exists) {
    throw new HttpsError("permission-denied", "Admin access required");
  }

  const { driverUid, action, rejectionReasons } = request.data;

  if (!driverUid || !action) {
    throw new HttpsError("invalid-argument", "driverUid and action required");
  }

  if (!["approve", "reject"].includes(action)) {
    throw new HttpsError("invalid-argument", "action must be approve or reject");
  }

  const driverRef = getDb().collection("drivers").doc(driverUid);
  const driverDoc = await driverRef.get();

  if (!driverDoc.exists) {
    throw new HttpsError("not-found", "Driver not found");
  }

  const fcmToken = driverDoc.data()?.fcmToken;

  if (action === "approve") {
    // Cascade: approving the driver also approves all their uploaded documents.
    const driverData = driverDoc.data() || {};
    const documents  = driverData.documents || {};

    const update = {
      isApproved:        true,
      isRejected:        false,
      documentsRejected: false,
      approvedAt:        admin.firestore.FieldValue.serverTimestamp(),
      approvedBy:        uid,
      signupStep:        "approved",
    };

    // Flip every uploaded document's status to "approved".
    for (const key of Object.keys(documents)) {
      update[`documents.${key}.status`] = "approved";
    }

    await driverRef.update(update);

    if (fcmToken) {
      await admin.messaging().send({
        token: fcmToken,
        notification: {
          title: "🎉 Account Approved!",
          body:  "Your CTS Go driver account is verified. Start driving now!",
        },
        data: { type: "account_approved", route: "/driver-shell" },
      }).catch(console.error); // Don't fail if FCM fails
    }

    await getDb()
      .collection("drivers")
      .doc(driverUid)
      .collection("notifications")
      .add({
        type:      "account_approved",
        title:     "Account Approved! 🎉",
        body:      "Your account has been verified. You can now start accepting rides.",
        isRead:    false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

  } else {
    const updates = {};
    if (rejectionReasons && typeof rejectionReasons === "object") {
      for (const [docKey, reason] of Object.entries(rejectionReasons)) {
        if (typeof reason === "string") {
          updates[`documents.${docKey}.status`]          = "rejected";
          updates[`documents.${docKey}.rejectionReason`] = reason;
        }
      }
    }

    await driverRef.update({
      ...updates,
      isApproved:        false,
      documentsRejected: true,
      rejectedAt:        admin.firestore.FieldValue.serverTimestamp(),
      rejectedBy:        uid,
    });

    if (fcmToken) {
      await admin.messaging().send({
        token: fcmToken,
        notification: {
          title: "Documents Need Attention",
          body:  "Some of your documents were rejected. Please re-upload and resubmit.",
        },
        data: { type: "documents_rejected", route: "/driver/documents" },
      }).catch(console.error);
    }

    await getDb()
      .collection("drivers")
      .doc(driverUid)
      .collection("notifications")
      .add({
        type:      "documents_rejected",
        title:     "Documents Rejected",
        body:      "Some documents need to be re-uploaded. Tap to view details.",
        isRead:    false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
  }

  return { success: true, action };
});

// ── getPendingDrivers ─────────────────────────────────────────────────────────

exports.getPendingDrivers = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
  const uid = requireAuth(request);

  const adminDoc = await getDb().collection("admins").doc(uid).get();
  if (!adminDoc.exists) {
    throw new HttpsError("permission-denied", "Admin access required");
  }

  const snap = await getDb()
    .collection("drivers")
    .where("documentsUploaded", "==", true)
    .where("isApproved",        "==", false)
    .where("documentsRejected", "==", false)
    .orderBy("submittedForReviewAt", "desc")
    .get();

  return {
    drivers: snap.docs.map((doc) => ({ uid: doc.id, ...doc.data() })),
  };
});

// ── Driver Wallet ─────────────────────────────────────────────────────────────
// Drivers have earnings tracked in drivers/{uid} AND a proper wallet

exports.getDriverWallet = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
  const uid = requireAuth(request);

  const [driverDoc, walletDoc] = await Promise.all([
    getDb().collection("drivers").doc(uid).get(),
    getDb().collection("driver_wallets").doc(uid).get(),
  ]);

  if (!driverDoc.exists) throw new HttpsError("not-found", "Driver not found");

  const driver = driverDoc.data();

  // Create driver wallet if it doesn't exist
  if (!walletDoc.exists) {
    await getDb().collection("driver_wallets").doc(uid).set({
      driverId:        uid,
      balance:         driver.totalEarnings    ?? 0,
      pendingBalance:  driver.pendingEarnings  ?? 0,
      totalEarned:     driver.totalEarnings    ?? 0,
      totalWithdrawn:  0,
      currency:        "GHS",
      createdAt:       admin.firestore.FieldValue.serverTimestamp(),
      lastUpdatedAt:   admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  const wallet = walletDoc.exists ? walletDoc.data() : {};

  return {
    balance:        driver.totalEarnings    ?? wallet.balance ?? 0,
    todayEarnings:  driver.todayEarnings    ?? 0,
    completedTrips: driver.completedTrips   ?? 0,
    totalWithdrawn: wallet.totalWithdrawn   ?? 0,
    currency:       "GHS",
  };
});

// ── Driver withdrawal request ─────────────────────────────────────────────────
// Keeps existing requestWithdrawal but adds proper validation

exports.requestDriverWithdrawal = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
  const uid = requireAuth(request);
  const { amount, phoneNumber, network, accountName } = request.data;

  if (!amount || amount <= 0)     throw new HttpsError("invalid-argument", "Invalid amount");
  if (!phoneNumber)               throw new HttpsError("invalid-argument", "Phone number required");
  if (!network)                   throw new HttpsError("invalid-argument", "Mobile money network required");

  const settings = await getDb().collection("settings").doc("platform").get();
  const minWithdrawal = settings.data()?.minWithdrawalAmount ?? 10;
  const maxWithdrawal = settings.data()?.maxWithdrawalAmount ?? 5000;

  if (amount < minWithdrawal) throw new HttpsError("invalid-argument", `Minimum withdrawal is GH₵${minWithdrawal}`);
  if (amount > maxWithdrawal) throw new HttpsError("invalid-argument", `Maximum withdrawal is GH₵${maxWithdrawal}`);

  // Check driver balance
  const driverDoc = await getDb().collection("drivers").doc(uid).get();
  if (!driverDoc.exists) throw new HttpsError("not-found", "Driver not found");

  const balance = driverDoc.data()?.totalEarnings ?? 0;
  if (balance < amount) {
    throw new HttpsError("failed-precondition",
      `Insufficient earnings. Available: GH₵${balance.toFixed(2)}`,
      { available: balance, requested: amount }
    );
  }

  // Check no pending withdrawal
  const pending = await getDb().collection("withdrawals")
    .where("driverId", "==", uid)
    .where("status", "==", "pending")
    .limit(1).get();

  if (!pending.empty) {
    throw new HttpsError("failed-precondition", "You already have a pending withdrawal request");
  }

  // Deduct from driver earnings atomically
  await getDb().runTransaction(async (tx) => {
    const driverRef = getDb().collection("drivers").doc(uid);
    const driver    = await tx.get(driverRef);
    const current   = driver.data()?.totalEarnings ?? 0;

    if (current < amount) throw new HttpsError("failed-precondition", "Insufficient balance");

    tx.update(driverRef, {
      totalEarnings:   admin.firestore.FieldValue.increment(-amount),
      pendingWithdrawal: admin.firestore.FieldValue.increment(amount),
    });

    // Create withdrawal record
    const withdrawalRef = getDb().collection("withdrawals").doc();
    tx.set(withdrawalRef, {
      driverId:    uid,
      driverName:  driver.data()?.displayName ?? "",
      amount,
      currency:    "GHS",
      phoneNumber,
      network,
      accountName: accountName ?? driver.data()?.displayName ?? "",
      status:      "pending",
      role:        "driver",
      createdAt:   admin.firestore.FieldValue.serverTimestamp(),
    });

    // Immutable ledger entry
    const ledgerRef = getDb().collection("ledger").doc();
    tx.set(ledgerRef, {
      type:          "WITHDRAWAL_REQUEST",
      status:        "PENDING",
      fromUserId:    uid,
      fromType:      "driver",
      toType:        "mobile_money",
      amount,
      currency:      "GHS",
      platformFee:   0,
      driverNet:     amount,
      referenceType: "withdrawal",
      referenceId:   withdrawalRef.id,
      idempotencyKey: `withdrawal_${uid}_${Date.now()}`,
      createdAt:     admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  // Write in-app notification
  await getDb().collection("drivers").doc(uid)
    .collection("notifications").add({
      type:      "withdrawal_requested",
      title:     "Withdrawal Requested",
      body:      `Your withdrawal of GH₵${amount.toFixed(2)} is being processed.`,
      isRead:    false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

  return { success: true, message: `Withdrawal of GH₵${amount.toFixed(2)} submitted successfully` };
});

// ── Reset todayEarnings at midnight Ghana time ────────────────────────────────
const { onSchedule } = require("firebase-functions/v2/scheduler");

exports.resetDailyEarnings = onSchedule(
  { schedule: "0 0 * * *", timeZone: "Africa/Accra", region: "europe-west2", minInstances: 0 },
  async () => {
    const today   = new Date();
    const isSunday = today.getDay() === 0;

    const driversSnap = await getDb().collection("drivers")
      .where("isApproved", "==", true).get();

    // Reset in batches
    const BATCH_SIZE = 500;
    let batch = getDb().batch();
    let count = 0;

    for (const doc of driversSnap.docs) {
      // Reset drivers/{uid} fields
      const driverUpdates = {
        todayEarnings: 0,
        lastResetAt:   admin.firestore.FieldValue.serverTimestamp(),
      };
      if (isSunday) driverUpdates.weekEarnings = 0;
      batch.update(doc.ref, driverUpdates);

      // Reset earnings/summary subcollection
      const summaryRef = getDb().collection("drivers").doc(doc.id)
                          .collection("earnings").doc("summary");
      const summaryUpdates = {
        todayEarnings: 0,
        lastResetAt:   admin.firestore.FieldValue.serverTimestamp(),
      };
      if (isSunday) summaryUpdates.weekEarnings = 0;
      batch.set(summaryRef, summaryUpdates, { merge: true });

      count++;
      if (count >= BATCH_SIZE) {
        await batch.commit();
        batch = getDb().batch();
        count = 0;
      }
    }

    if (count > 0) await batch.commit();
    console.log(`✅ Reset todayEarnings for ${driversSnap.size} drivers. Week reset: ${isSunday}`);
  }
);

// ── One-time migration: add heldBalance to existing wallets ───────────────────
// Call once from admin panel, then remove
exports.migrateWallets = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
  const uid = requireAuth(request);
  const adminDoc = await getDb().collection("admins").doc(uid).get();
  if (!adminDoc.exists) throw new HttpsError("permission-denied", "Admin only");

  const walletsSnap  = await getDb().collection("wallets").get();
  const driversSnap  = await getDb().collection("drivers")
    .where("isApproved", "==", true).get();

  let walletsMigrated = 0;
  let driverWallets   = 0;

  // Migrate in batches of 500
  const BATCH_SIZE = 500;
  let batch = getDb().batch();
  let batchCount = 0;

  for (const doc of walletsSnap.docs) {
    const data    = doc.data();
    const updates = {};
    if (data.heldBalance  === undefined) updates.heldBalance  = 0;
    if (data.currency     === undefined) updates.currency     = "GHS";
    if (data.lastUpdatedAt === undefined) updates.lastUpdatedAt = admin.firestore.FieldValue.serverTimestamp();

    if (Object.keys(updates).length > 0) {
      batch.update(doc.ref, updates);
      walletsMigrated++;
      batchCount++;

      if (batchCount >= BATCH_SIZE) {
        await batch.commit();
        batch = getDb().batch();
        batchCount = 0;
      }
    }
  }
  if (batchCount > 0) await batch.commit();

  // Create driver_wallets for approved drivers
  let batch2 = getDb().batch();
  let batchCount2 = 0;

  for (const doc of driversSnap.docs) {
    const data      = doc.data();
    const walletRef = getDb().collection("driver_wallets").doc(doc.id);
    const existing  = await walletRef.get();

    if (!existing.exists) {
      batch2.set(walletRef, {
        driverId:       doc.id,
        driverName:     data.displayName    ?? "",
        balance:        data.totalEarnings  ?? 0,
        pendingBalance: 0,
        totalEarned:    data.totalEarnings  ?? 0,
        totalWithdrawn: 0,
        currency:       "GHS",
        createdAt:      admin.firestore.FieldValue.serverTimestamp(),
        lastUpdatedAt:  admin.firestore.FieldValue.serverTimestamp(),
      });
      driverWallets++;
      batchCount2++;

      if (batchCount2 >= BATCH_SIZE) {
        await batch2.commit();
        batch2 = getDb().batch();
        batchCount2 = 0;
      }
    }
  }
  if (batchCount2 > 0) await batch2.commit();

  // Log migration in audit log
  await getDb().collection("audit_log").add({
    adminUid:  uid,
    action:    "migrate_wallets",
    details:   `Migrated ${walletsMigrated} wallets, created ${driverWallets} driver wallets`,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  console.log(`✅ Migration: ${walletsMigrated} wallets, ${driverWallets} driver wallets`);
  return { success: true, walletsMigrated, driverWallets };
});
