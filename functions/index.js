const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule }        = require("firebase-functions/v2/scheduler");
const admin                 = require("firebase-admin");

admin.initializeApp();
const trips = require("./trips");


exports.createPassengerWallet = onDocumentCreated(
  { region: "europe-west2" },
  "users/{userId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const data = snap.data();
    if (data?.role !== 'passenger') return;

    const walletRef = admin.firestore()
      .collection('wallets')
      .doc(event.params.userId);

    const existing = await walletRef.get();
    if (existing.exists) return;

    await walletRef.set({
      userId:    event.params.userId,
      balance:   0.0,
      currency:  'GHS',
      isActive:  true,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
);



// ── onDriverAlertCreated ──────────────────────────────────────────────────────

exports.onDriverAlertCreated = onDocumentCreated(
  { region: "europe-west2" },
  "driver_alerts/{tripId}",
  async (event) => {
    // v2 Firestore trigger: event.data is the DocumentSnapshot
    const snap = event.data;
    if (!snap) return;

    const alert = snap.data();
    if (!alert) return;

    const tripId     = event.params.tripId;
    const serviceType = alert.serviceType;
    const db          = admin.firestore();

    // Use plain numbers — avoids GeoPoint protobuf deserialization bug
    const pickupLocation = {
      latitude:  alert.pickupLat ?? 0,
      longitude: alert.pickupLng ?? 0,
    };

    // ── 1. Verify trip still exists and is searching ──────────────────────
    const tripRef  = db.collection("trips").doc(tripId);
    const tripSnap = await tripRef.get();

    if (!tripSnap.exists || tripSnap.data().status !== "searching") {
      console.log(`Trip ${tripId} no longer searching — aborting`);
      return;
    }

    // ── 2. Query available drivers by serviceType (string field) ──────────
    //    FIX: was "serviceTypes" (array) — driver doc has "serviceType" string
    const driversSnap = await db
      .collection("drivers")
      .where("isAvailable", "==", true)
      .where("isOnline",    "==", true)
      .where("isApproved",  "==", true)
      .where("serviceType", "==", serviceType) // ← FIXED: string not array
      .get();

    if (driversSnap.empty) {
      await tripRef.update({ status: "noDriversAvailable" });
      await snap.ref.update({ status: "noDriversFound" });
      return;
    }

    // ── 3. Filter by 5km radius ───────────────────────────────────────────
    const nearby = driversSnap.docs.filter((doc) => {
      const loc = doc.data().location;
      if (!loc) return false;
      return haversineKm(
        pickupLocation.latitude,  pickupLocation.longitude,
        loc.latitude,             loc.longitude
      ) <= 5.0;
    });

    if (nearby.length === 0) {
      await tripRef.update({ status: "noDriversAvailable" });
      await snap.ref.update({ status: "noDriversFound" });
      return;
    }

    // ── 4. Send FCM to all nearby drivers ─────────────────────────────────
    const tokens = nearby.map((d) => d.data().fcmToken).filter(Boolean);

    if (tokens.length > 0) {
      await admin.messaging().sendEachForMulticast({
        tokens,
        data: {
          tripId,
          type:           "NEW_TRIP_REQUEST",
          serviceType,
          pickupLat:      String(pickupLocation.latitude),
          pickupLng:      String(pickupLocation.longitude),
          pickupAddress:  alert.pickupAddress ?? "",
        },
        notification: {
          title: "🚗 New ride request",
          body:  `Pickup: ${alert.pickupAddress ?? "Nearby location"}`,
        },
        android: { priority: "high" },
      });
    }

    await snap.ref.update({
      status:      "sent",
      driverCount: nearby.length,
      sentAt:      admin.firestore.FieldValue.serverTimestamp(),
    });
  }
);

// ── acceptTrip — transaction-safe driver acceptance ───────────────────────────

exports.acceptTrip = require("firebase-functions/v2/https").onCall(
  { region: "europe-west2" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new Error("Unauthenticated");

    const { tripId } = request.data;
    if (!tripId) throw new Error("tripId required");

    const db      = admin.firestore();
    const tripRef = db.collection("trips").doc(tripId);

    // ── Transaction: only first driver wins ──────────────────────────────
    const result = await db.runTransaction(async (txn) => {
      const tripSnap = await txn.get(tripRef);

      if (!tripSnap.exists) {
        return { success: false, reason: "trip_not_found" };
      }

      const data   = tripSnap.data();
      const status = data.status;

      // Reject if already accepted or not searching
      if (status !== "searching") {
        return { success: false, reason: "already_accepted" };
      }

      // Check expiry
      const expiresAt = data.expiresAt?.toDate();
      if (expiresAt && new Date() > expiresAt) {
        txn.update(tripRef, { status: "expired" });
        return { success: false, reason: "expired" };
      }

      // Get driver info
      const driverSnap = await txn.get(db.collection("drivers").doc(uid));
      if (!driverSnap.exists) {
        return { success: false, reason: "driver_not_found" };
      }

      const driver = driverSnap.data();

      // Accept — write atomically
      txn.update(tripRef, {
        status:        "tripAccepted",  // ← matches driver app status
        driverId:      uid,
        driverName:    driver.displayName ?? driver.name ?? "Driver",
        driverPhone:   driver.phoneNumber ?? "",
        driverRating:  driver.rating      ?? 5.0,
        driverPlate:   driver.vehiclePlate ?? "",
        driverPhoto:   driver.photoUrl    ?? "",
        vehicleModel:  driver.vehicleModel ?? "",
        acceptedAt:    admin.firestore.FieldValue.serverTimestamp(),
      });

      // Mark driver as busy
      txn.update(db.collection("drivers").doc(uid), {
        isAvailable:    false,
        currentTripId:  tripId,
      });

      return { success: true };
    });

    if (result.success) {
      // Notify passenger via FCM
      const tripSnap    = await tripRef.get();
      const passengerId = tripSnap.data()?.passengerId;
      if (passengerId) {
        const passengerSnap = await db.collection("users").doc(passengerId).get();
        const fcmToken      = passengerSnap.data()?.fcmToken;
        if (fcmToken) {
          await admin.messaging().send({
            token:        fcmToken,
            notification: {
              title: "Driver found! 🎉",
              body:  "Your driver is on the way",
            },
            data: { type: "DRIVER_ASSIGNED", tripId },
          });
        }
      }
    }

    return result;
  }
);

// ── expireStaleTrips — runs every 2 minutes ───────────────────────────────────

exports.expireStaleTrips = onSchedule(
  { schedule: "every 2 minutes", timeZone: "Africa/Accra", region: "europe-west2", minInstances: 0 },
  async () => {
    const db  = admin.firestore();
    const now = new Date();
    const cutoff = new Date(now.getTime() - 2 * 60 * 1000); // 2 min ago

    const staleSnap = await db
      .collection("trips")
      .where("status",    "==", "searching")
      .where("createdAt", "<=", admin.firestore.Timestamp.fromDate(cutoff))
      .get();

    const batch = db.batch();
    staleSnap.docs.forEach((doc) => {
      batch.update(doc.ref, {
        status:    "noDriversAvailable",
        expiredAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    await batch.commit();
    console.log(`Expired ${staleSnap.docs.length} stale trips`);
  }
);

// ── Haversine ────────────────────────────────────────────────────────────────

function haversineKm(lat1, lon1, lat2, lon2) {
  const R    = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a    =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) *
      Math.cos(lat2 * Math.PI / 180) *
      Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// ── Wallet functions ──────────────────────────────────────────────────────────

const wallet = require("./wallet");
exports.createWallet              = wallet.createWallet;
exports.getWalletBalance          = wallet.getWalletBalance;
exports.initializePaystackPayment = wallet.initializePaystackPayment;
exports.verifyPaystackPayment     = wallet.verifyPaystackPayment;
exports.deductWalletBalance       = wallet.deductWalletBalance;
exports.getTransactionHistory     = wallet.getTransactionHistory;
exports.requestWithdrawal         = wallet.requestWithdrawal;
exports.approveDriver             = wallet.approveDriver;
exports.getPendingDrivers         = wallet.getPendingDrivers;

// ── Notification functions ────────────────────────────────────────────────────

const notifications = require("./notifications");
exports.onTripStatusChanged     = notifications.onTripStatusChanged;
exports.onGasOrderStatusChanged = notifications.onGasOrderStatusChanged;
exports.onGasOrderCreated       = notifications.onGasOrderCreated;
exports.onDeliveryStatusChanged = notifications.onDeliveryStatusChanged;
exports.onWalletChanged         = notifications.onWalletChanged;
exports.onDeliveryNotification  = notifications.onDeliveryCompleted;
exports.checkDocumentExpiry     = notifications.checkDocumentExpiry;
exports.onTripCreatedNotify = notifications.onTripCreatedNotify;

// ── Trip lifecycle (fare validation + wallet deduction + driver credit) ────────
exports.onTripCreated       = trips.onTripCreated;
exports.onTripCompleted     = trips.onTripCompleted;
exports.onDeliveryCompleted = trips.onDeliveryCompleted;
exports.onGasOrderCompleted = trips.onGasOrderCompleted;

// ── Escrow + Financial integrity ──────────────────────────────────────────────
const escrow = require("./escrow");
exports.holdBalance          = escrow.holdBalance;
exports.attachEscrowToOrder  = escrow.attachEscrowToOrder;
exports.paystackWebhook      = escrow.paystackWebhook;
exports.releaseStuckEscrows  = escrow.releaseStuckEscrows;
exports.dailyReconciliation  = escrow.dailyReconciliation;

// ── Cancellation refunds ──────────────────────────────────────────────────────
exports.onTripCancelled      = trips.onTripCancelled;
exports.onDeliveryCancelled  = trips.onDeliveryCancelled;
exports.onGasOrderCancelled  = trips.onGasOrderCancelled;
exports.resetDailyEarnings = wallet.resetDailyEarnings;
exports.getDriverWallet          = wallet.getDriverWallet;
exports.requestDriverWithdrawal  = wallet.requestDriverWithdrawal;
exports.migrateWallets = wallet.migrateWallets;
exports.refundEscrowOnError = escrow.refundEscrowOnError;
exports.broadcastNotification = notifications.broadcastNotification;
exports.onDeliveryCreated = notifications.onDeliveryCreated;

// ── Bridge payment integration (collection + payout) ──────────────────────────
const bridge = require("./bridge");
exports.initiateBridgeTopUp    = bridge.initiateBridgeTopUp;
exports.bridgeTopUpCallback    = bridge.bridgeTopUpCallback;
exports.checkBridgeTopUpStatus = bridge.checkBridgeTopUpStatus;
exports.initiateBridgePayout   = bridge.initiateBridgePayout;
exports.bridgePayoutCallback   = bridge.bridgePayoutCallback;

// ── Passenger ratings → driver aggregate ─────────────────────────────────────
const ratings = require("./ratings");
exports.onTripRated     = ratings.onTripRated;
exports.onDeliveryRated = ratings.onDeliveryRated;
exports.onGasOrderRated = ratings.onGasOrderRated;


const adminAlerts = require("./admin_alerts");
exports.onDriverSubmittedForReview = adminAlerts.onDriverSubmittedForReview;

// ── withdrawal approval ─────────────────────────────────────
const withdrawalApproval = require("./withdrawal_approval");
exports.approveWithdrawal = withdrawalApproval.approveWithdrawal;
exports.rejectWithdrawal = withdrawalApproval.rejectWithdrawal;