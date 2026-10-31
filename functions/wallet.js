// functions/wallet.js
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin                  = require("firebase-admin");

const getDb          = () => admin.firestore();

// ── Helpers ───────────────────────────────────────────────────────────────────

function requireAuth(request) {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Login required");
  }
  return request.auth.uid;
}

// A drivers/{uid} doc only counts as a driver once the driver has chosen a
// driver role. Signing into the Driver app used to leave a token-only
// drivers/{uid} (AUTH-03); that must not turn a passenger into a "driver".
function isDriverRecord(driver) {
  return !!driver && typeof driver.role === "string" &&
    driver.role.startsWith("driver_");
}

// driver/user: the docs' data, or null when the doc does not exist.
function classifyRole(driver, user) {
  if (isDriverRecord(driver)) return { role: "driver", data: driver };
  if (user) return { role: "passenger", data: user };
  // A driver part-way through signup (no role yet) and no passenger profile.
  if (driver) return { role: "driver", data: driver };
  return { role: "unknown", data: {} };
}

async function getRole(uid) {
  const [driverDoc, userDoc] = await Promise.all([
    getDb().collection("drivers").doc(uid).get(),
    getDb().collection("users").doc(uid).get(),
  ]);
  return classifyRole(
    driverDoc.exists ? driverDoc.data() : null,
    userDoc.exists ? userDoc.data() : null,
  );
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

// Wallet top-ups go through The Bridge Solutions only (bridge.js
// initiateBridgeTopUp). The Paystack callables were removed.

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
  requireAuth(request);
  // Retired: driver payouts are requested only through initiateBridgePayout
  // (bridge.js), which holds the funds, enforces one open withdrawal per
  // driver and queues the request for admin review. This older path
  // reserved a different balance field (totalEarnings, not walletBalance),
  // so the same funds could be reserved twice; its requests could never be
  // approved or rejected; and requestWithdrawal also let passengers
  // withdraw. No Passenger, Driver or admin build calls it. Refused before
  // any read or write.
  throw new HttpsError("failed-precondition",
    "This withdrawal method is no longer available. Please update the app.");
});

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
  // The withdrawable balance is walletBalance (wallet-paid earnings).
  // totalEarnings also counts cash fares the driver already holds, so it is
  // reported as earnings, never as a balance.
  const withdrawable = typeof driver.walletBalance === "number" &&
    Number.isFinite(driver.walletBalance) ? driver.walletBalance : 0;

  // Create driver wallet if it doesn't exist
  if (!walletDoc.exists) {
    await getDb().collection("driver_wallets").doc(uid).set({
      driverId:        uid,
      balance:         withdrawable,
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
    balance:        withdrawable,
    totalEarnings:  driver.totalEarnings    ?? 0,
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
  requireAuth(request);
  // Retired: driver payouts are requested only through initiateBridgePayout
  // (bridge.js), which holds the funds, enforces one open withdrawal per
  // driver and queues the request for admin review. This older path
  // reserved a different balance field (totalEarnings, not walletBalance),
  // so the same funds could be reserved twice; its requests could never be
  // approved or rejected; and requestWithdrawal also let passengers
  // withdraw. No Passenger, Driver or admin build calls it. Refused before
  // any read or write.
  throw new HttpsError("failed-precondition",
    "This withdrawal method is no longer available. Please update the app.");
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

// Test-only access (not exported from index.js, so never deployed).
exports._roles = { classifyRole };
