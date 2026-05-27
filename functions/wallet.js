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

exports.createWallet = onCall(async (request) => {
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

exports.getWalletBalance = onCall(async (request) => {
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
  { secrets: [paystackSecret] },
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
  { secrets: [paystackSecret] },
  async (request) => {
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

    await getDb().runTransaction(async (t) => {
      const walletDoc      = await t.get(walletRef);
      const currentBalance = walletDoc.exists
          ? (walletDoc.data()?.balance ?? 0)
          : 0;

      if (!walletDoc.exists) {
        t.set(walletRef, {
          userId:    uid,
          balance:   amountPaid,
          currency:  "GHS",
          isActive:  true,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } else {
        t.update(walletRef, {
          balance:   currentBalance + amountPaid,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      t.update(txRef, {
        status:            "completed",
        amount:            amountPaid,
        paystackReference: reference,
        completedAt:       admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    return { success: true, amountCredited: amountPaid };
  }
);

// ── deductWalletBalance ───────────────────────────────────────────────────────
// Passengers only — deducts from wallets/{uid}

exports.deductWalletBalance = onCall(async (request) => {
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

exports.getTransactionHistory = onCall(async (request) => {
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

exports.requestWithdrawal = onCall(async (request) => {
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

exports.approveDriver = onCall(async (request) => {
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
    await driverRef.update({
      isApproved:        true,
      isRejected:        false,
      documentsRejected: false,
      approvedAt:        admin.firestore.FieldValue.serverTimestamp(),
      approvedBy:        uid,
      signupStep:        "approved",
    });

    if (fcmToken) {
      await admin.messaging().send({
        token: fcmToken,
        notification: {
          title: "🎉 Account Approved!",
          body:  "Your CTS Transport driver account is verified. Start driving now!",
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

exports.getPendingDrivers = onCall(async (request) => {
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