// functions/wallet.js
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret }       = require("firebase-functions/params");
const admin                  = require("firebase-admin");
const axios                  = require("axios");

const getDb          = () => admin.firestore();
const PAYSTACK_BASE  = "https://api.paystack.co";
const paystackSecret = defineSecret("PAYSTACK_SECRET_KEY");

// ── Auth helper ──────────────────────────────────────────────────────────────

function requireAuth(request) {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Login required");
  }
  return request.auth.uid;
}

// ── createWallet ─────────────────────────────────────────────────────────────

exports.createWallet = onCall(async (request) => {
  const uid       = requireAuth(request);
  const data      = request.data;
  const walletRef = getDb().collection("wallets").doc(uid);
  const existing  = await walletRef.get();

  if (existing.exists) return existing.data();

  const wallet = {
    userId:    uid,
    email:     data.email ?? request.auth.token?.email ?? `${uid}@cts.app`,
    balance:   0,
    currency:  "GHS",
    isActive:  true,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  await walletRef.set(wallet);
  return wallet;
});

// ── getWalletBalance ──────────────────────────────────────────────────────────

exports.getWalletBalance = onCall(async (request) => {
  const uid = requireAuth(request);
  const doc = await getDb().collection("wallets").doc(uid).get();

  if (!doc.exists) {
    throw new HttpsError("not-found", "Wallet not found. Please contact support.");
  }
  return doc.data();
});

// ── initializePaystackPayment ─────────────────────────────────────────────────

exports.initializePaystackPayment = onCall(
  { secrets: [paystackSecret] },
  async (request) => {
    const uid    = requireAuth(request);
    const data   = request.data;
    const secret = paystackSecret.value();
    const { amount, email, paymentMethod } = data;

    if (!amount || amount < 1) {
      throw new HttpsError("invalid-argument", "Minimum top-up is ₵1");
    }

    // Ensure wallet exists
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

    // Create pending transaction
    const txRef = getDb().collection("transactions").doc();
    await txRef.set({
      id:          txRef.id,
      userId:      uid,
      type:        "credit",
      category:    "top_up",
      amount,
      currency:    "GHS",
      status:      "pending",
      description: `Wallet top-up — ₵${amount.toFixed(2)}`,
      reference:   null,
      createdAt:   admin.firestore.FieldValue.serverTimestamp(),
    });

    try {
      const response = await axios.post(
        `${PAYSTACK_BASE}/transaction/initialize`,
        {
          email,
          amount:   Math.round(amount * 100),
          currency: "GHS",
          callback_url: "https://ctstransportapp.web.app/payment/callback",
          channels: paymentMethod === "mobile_money"
            ? ["mobile_money"] : ["card"],
          metadata: {
            userId:           uid,
            transactionDocId: txRef.id,
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
      return { authorization_url, reference, transactionDocId: txRef.id };
    } catch (err) {
      await txRef.delete();
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
    const data      = request.data;
    const secret    = paystackSecret.value();
    const { reference } = data;

    if (!reference) {
      throw new HttpsError("invalid-argument", "Payment reference required");
    }

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

    const txSnap = await getDb()
      .collection("transactions")
      .where("reference", "==", reference)
      .where("userId", "==", uid)
      .limit(1)
      .get();

    if (txSnap.empty) {
      throw new HttpsError("not-found", "Transaction record not found");
    }

    const txRef  = txSnap.docs[0].ref;
    const txData = txSnap.docs[0].data();

    if (txData.status === "completed") {
      return { success: true, alreadyProcessed: true };
    }

    await getDb().runTransaction(async (t) => {
      const walletDoc      = await t.get(walletRef);
      const currentBalance = walletDoc.data()?.balance ?? 0;

      t.update(walletRef, {
        balance:   currentBalance + amountPaid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      t.update(txRef, {
        status:             "completed",
        amount:             amountPaid,
        paystackReference:  reference,
        completedAt:        admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    return { success: true, amountCredited: amountPaid };
  }
);

// ── deductWalletBalance ───────────────────────────────────────────────────────

exports.deductWalletBalance = onCall(async (request) => {
  const uid = requireAuth(request);
  const { amount, description, category } = request.data;

  if (!amount || amount <= 0) {
    throw new HttpsError("invalid-argument", "Invalid amount");
  }

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
        `Insufficient balance. Available: ₵${balance.toFixed(2)}`
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
      category,
      amount,
      currency:    "GHS",
      status:      "completed",
      description,
      createdAt:   admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  return { success: true };
});

// ── getTransactionHistory ─────────────────────────────────────────────────────

exports.getTransactionHistory = onCall(async (request) => {
  const uid   = requireAuth(request);
  const limit = request.data.limit ?? 50;

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

exports.requestWithdrawal = onCall(async (request) => {
  const uid = requireAuth(request);
  const { amount, method, phoneNumber, accountName } = request.data;

  if (!amount || amount < 10) {
    throw new HttpsError("invalid-argument", "Minimum withdrawal is GH₵ 10");
  }

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
      category:    "withdrawal",
      amount,
      currency:    "GHS",
      status:      "pending",
      description: `Withdrawal to ${method} — ${phoneNumber ?? accountName ?? ""}`,
      method,
      phoneNumber:  phoneNumber ?? null,
      accountName:  accountName ?? null,
      createdAt:   admin.firestore.FieldValue.serverTimestamp(),
    });

    const withdrawalRef = getDb()
      .collection("drivers")
      .doc(uid)
      .collection("withdrawals")
      .doc();

    t.set(withdrawalRef, {
      id:          withdrawalRef.id,
      amount,
      method,
      phoneNumber:  phoneNumber ?? null,
      accountName:  accountName ?? null,
      status:      "pending",
      createdAt:   admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  return { success: true, message: "Withdrawal request submitted" };
});

// ── approveDriver ─────────────────────────────────────────────────────────────
exports.approveDriver = onCall(async (request) => {
  if (!request.auth?.uid) {
    throw new HttpsError('unauthenticated', 'Login required');
  }

  // Check admin collection — no hardcoded UIDs
  const adminDoc = await admin.firestore()
    .collection('admins')
    .doc(request.auth.uid)
    .get();

  if (!adminDoc.exists) {
    throw new HttpsError('permission-denied', 'Admin access required');
  }

  const { driverUid, action, rejectionReasons } = request.data;
  // action: 'approve' | 'reject'

  if (!driverUid || !action) {
    throw new HttpsError('invalid-argument', 'driverUid and action required');
  }

  const driverRef = admin.firestore().collection('drivers').doc(driverUid);
  const driverDoc = await driverRef.get();

  if (!driverDoc.exists) {
    throw new HttpsError('not-found', 'Driver not found');
  }

  if (action === 'approve') {
    await driverRef.update({
      isApproved:        true,
      isRejected:        false,
      documentsRejected: false,
      approvedAt:        admin.firestore.FieldValue.serverTimestamp(),
      approvedBy:        request.auth.uid,
      signupStep:        'approved',
    });

    // Notify driver
    const fcmToken = driverDoc.data()?.fcmToken;
    if (fcmToken) {
      await admin.messaging().send({
        token: fcmToken,
        notification: {
          title: '🎉 Account Approved!',
          body:  'Your CTS Transport driver account is verified. Start driving now!',
        },
        data: {
          type:  'account_approved',
          route: '/driver-shell',
        },
      });
    }

    // Write notification to Firestore
    await admin.firestore()
      .collection('drivers')
      .doc(driverUid)
      .collection('notifications')
      .add({
        type:      'account_approved',
        title:     'Account Approved! 🎉',
        body:      'Your account has been verified. You can now start accepting rides.',
        isRead:    false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

  } else if (action === 'reject') {
    // rejectionReasons: { drivers_license: 'Expired', insurance: 'Unclear photo' }
    const documents = driverDoc.data()?.documents ?? {};

    // Mark each rejected doc
    const updates = {};
    if (rejectionReasons) {
      for (const [docKey, reason] of Object.entries(rejectionReasons)) {
        updates[`documents.${docKey}.status`]          = 'rejected';
        updates[`documents.${docKey}.rejectionReason`] = reason;
      }
    }

    await driverRef.update({
      ...updates,
      isApproved:        false,
      documentsRejected: true,
      rejectedAt:        admin.firestore.FieldValue.serverTimestamp(),
      rejectedBy:        request.auth.uid,
    });

    // Notify driver
    const fcmToken = driverDoc.data()?.fcmToken;
    if (fcmToken) {
      await admin.messaging().send({
        token: fcmToken,
        notification: {
          title: 'Documents Need Attention',
          body:  'Some of your documents were rejected. Please re-upload and resubmit.',
        },
        data: {
          type:  'documents_rejected',
          route: '/driver/documents',
        },
      });
    }

    await admin.firestore()
      .collection('drivers')
      .doc(driverUid)
      .collection('notifications')
      .add({
        type:      'documents_rejected',
        title:     'Documents Rejected',
        body:      'Some documents need to be re-uploaded. Tap to view details.',
        isRead:    false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
  }

  return { success: true, action };
});

// ── rejectDriver (convenience wrapper) ───────────────────────────────────────
exports.getPendingDrivers = onCall(async (request) => {
  if (!request.auth?.uid) {
    throw new HttpsError('unauthenticated', 'Login required');
  }

  const adminDoc = await admin.firestore()
    .collection('admins')
    .doc(request.auth.uid)
    .get();

  if (!adminDoc.exists) {
    throw new HttpsError('permission-denied', 'Admin access required');
  }

  const snap = await admin.firestore()
    .collection('drivers')
    .where('documentsUploaded', '==', true)
    .where('isApproved',        '==', false)
    .where('documentsRejected', '==', false)
    .orderBy('submittedForReviewAt', 'desc')
    .get();

  return {
    drivers: snap.docs.map(doc => ({
      uid:  doc.id,
      ...doc.data(),
    })),
  };
});
