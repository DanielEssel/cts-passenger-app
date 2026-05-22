// functions/notifications.js
const { onDocumentUpdated, onDocumentCreated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

const db  = admin.firestore();
const fcm = admin.messaging();

// ─────────────────────────────────────────────────────────────────────────────
// Helper
// ─────────────────────────────────────────────────────────────────────────────

async function sendNotification(uid, { type, title, body, route, metadata = {} }) {
  if (!uid) return;

  await db.collection("notifications").doc(uid)
    .collection("items").add({
      type,
      title,
      body,
      route:     route ?? null,
      metadata,
      isRead:    false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

  const userDoc = await db.collection("users").doc(uid).get();
  const token   = userDoc.data()?.fcmToken;
  if (!token) return;

  try {
    await fcm.send({
      token,
      notification: { title, body },
      data: {
        type,
        route: route ?? "",
        ...Object.fromEntries(
          Object.entries(metadata).map(([k, v]) => [k, String(v)])
        ),
      },
      android: {
        notification: {
          channelId: "ctsride_general",
          priority:  "high",
          sound:     "default",
        },
      },
      apns: {
        payload: {
          aps: { sound: "default", badge: 1 },
        },
      },
    });
  } catch (e) {
    console.error("FCM send error:", e.message);
  }
}

function statusChanged(before, after) {
  return before.status !== after.status;
}

// ─────────────────────────────────────────────────────────────────────────────
// RIDE
// ─────────────────────────────────────────────────────────────────────────────

exports.onTripStatusChanged = onDocumentUpdated(
  "trips/{tripId}",
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();
    const tripId = event.params.tripId;

    if (!statusChanged(before, after)) return;

    const uid      = after.passengerId;
    const route    = `/ride-tracking?tripId=${tripId}`;
    const metadata = { tripId };

    switch (after.status) {
      case "tripAccepted":
        await sendNotification(uid, {
          type: "ride", title: "Driver assigned 🚗",
          body: `${after.metadata?.driverName ?? "Your driver"} is on the way.`,
          route, metadata,
        });
        break;
      case "driverArrived":
        await sendNotification(uid, {
          type: "ride", title: "Driver has arrived 📍",
          body: `${after.metadata?.driverName ?? "Your driver"} is waiting at your pickup.`,
          route, metadata,
        });
        break;
      case "tripStarted":
      case "inProgress":
        await sendNotification(uid, {
          type: "ride", title: "Trip started 🚦",
          body: `You're on your way to ${after.dropoffAddress ?? "your destination"}.`,
          route, metadata,
        });
        break;
      case "completed": {
        const fare = after.actualFare?.toFixed(2) ?? after.estimatedFare?.toFixed(2) ?? "0.00";
        await sendNotification(uid, {
          type: "ride", title: "Trip completed ✓",
          body: `Your trip to ${after.dropoffAddress} was GHS ${fare}. Rate your driver!`,
          route: `/trip-complete?tripId=${tripId}`,
          metadata: { ...metadata, fare },
        });
        break;
      }
      case "cancelled":
        await sendNotification(uid, {
          type: "ride", title: "Trip cancelled",
          body: "Your trip was cancelled. Book a new ride anytime.",
          route: "/shell", metadata,
        });
        break;
      case "noDrivers":
        await sendNotification(uid, {
          type: "ride", title: "No drivers nearby 😔",
          body: "We couldn't find a driver right now. Please try again.",
          route: "/shell", metadata,
        });
        break;
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// GAS ORDERS
// ─────────────────────────────────────────────────────────────────────────────

exports.onGasOrderCreated = onDocumentCreated(
  "gas_orders/{orderId}",
  async (event) => {
    const data    = event.data.data();
    const orderId = event.params.orderId;
    const uid     = data.passengerId;

    await sendNotification(uid, {
      type:  "gas",
      title: "Gas order placed ✓",
      body:  `Your ${data.cylinderSize ?? "gas"} order is pending approval.`,
      route: `/gas-tracking?orderId=${orderId}`,
      metadata: { orderId },
    });
  }
);

exports.onGasOrderStatusChanged = onDocumentUpdated(
  "gas_orders/{orderId}",
  async (event) => {
    const before  = event.data.before.data();
    const after   = event.data.after.data();
    const orderId = event.params.orderId;

    if (!statusChanged(before, after)) return;

    const uid      = after.passengerId;
    const route    = `/gas-tracking?orderId=${orderId}`;
    const metadata = { orderId };

    switch (after.status) {
      case "approved":
      case "driverAssigned":
        await sendNotification(uid, {
          type: "gas", title: "Gas order confirmed 🔥",
          body: `Your ${after.cylinderSize ?? "gas"} order is confirmed. Driver is on the way.`,
          route, metadata,
        });
        break;
      case "driverEnRoute":
        await sendNotification(uid, {
          type: "gas", title: "Driver en route 🚗",
          body: "Your gas delivery driver is heading to your location.",
          route, metadata,
        });
        break;
      case "driverArrived":
        await sendNotification(uid, {
          type: "gas", title: "Driver has arrived 📍",
          body: "Your gas delivery driver is at your location.",
          route, metadata,
        });
        break;
      case "pickedUp":
      case "refilling":
        await sendNotification(uid, {
          type: "gas", title: "Cylinder picked up ✓",
          body: "Your cylinder has been collected for refilling.",
          route, metadata,
        });
        break;
      case "delivered": {
        const total = after.totalPrice?.toFixed(2) ?? "0.00";
        await sendNotification(uid, {
          type: "gas", title: "Gas delivered! 🎉",
          body: `Your gas cylinder has been delivered. Total: GHS ${total}.`,
          route: "/shell", metadata: { ...metadata, total },
        });
        break;
      }
      case "cancelled":
        await sendNotification(uid, {
          type: "gas", title: "Gas order cancelled",
          body: "Your gas order was cancelled. Any wallet deduction will be refunded.",
          route: "/shell", metadata,
        });
        break;
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// DELIVERY
// ─────────────────────────────────────────────────────────────────────────────

exports.onDeliveryStatusChanged = onDocumentUpdated(
  "delivery_requests/{deliveryId}",
  async (event) => {
    const before     = event.data.before.data();
    const after      = event.data.after.data();
    const deliveryId = event.params.deliveryId;

    if (!statusChanged(before, after)) return;

    const uid      = after.passengerId ?? after.userId;
    const route    = `/delivery-tracking?deliveryId=${deliveryId}`;
    const metadata = { deliveryId };

    switch (after.status) {
      case "driverAssigned":
      case "accepted":
        await sendNotification(uid, {
          type: "delivery", title: "Rider assigned 🏍️",
          body: `${after.driverName ?? "Your rider"} will pick up your parcel shortly.`,
          route, metadata,
        });
        break;
      case "pickupComplete":
      case "pickedUp":
        await sendNotification(uid, {
          type: "delivery", title: "Parcel picked up 📦",
          body: `${after.driverName ?? "Your rider"} has collected your parcel.`,
          route, metadata,
        });
        break;
      case "inTransit":
      case "outForDelivery":
        await sendNotification(uid, {
          type: "delivery", title: "Parcel out for delivery 🚀",
          body: `Your parcel is heading to ${after.dropoffAddress ?? "the destination"}.`,
          route, metadata,
        });
        break;
      case "delivered":
      case "completed": {
        const fare = after.actualFare?.toFixed(2) ?? "0.00";
        await sendNotification(uid, {
          type: "delivery", title: "Parcel delivered! ✓",
          body: `Your parcel was delivered to ${after.dropoffAddress ?? "the destination"}.`,
          route: "/shell", metadata: { ...metadata, fare },
        });
        break;
      }
      case "cancelled":
        await sendNotification(uid, {
          type: "delivery", title: "Delivery cancelled",
          body: "Your delivery was cancelled. Contact support if you need help.",
          route: "/shell", metadata,
        });
        break;
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// WALLET
// ─────────────────────────────────────────────────────────────────────────────

exports.onWalletChanged = onDocumentUpdated(
  "wallets/{uid}",
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();
    const uid    = event.params.uid;

    const prevBalance = before.balance ?? 0;
    const newBalance  = after.balance  ?? 0;
    const diff        = newBalance - prevBalance;

    if (Math.abs(diff) < 0.01) return;

    if (diff > 0) {
      await sendNotification(uid, {
        type:  "wallet",
        title: "Wallet topped up 💳",
        body:  `GHS ${diff.toFixed(2)} added. Balance: GHS ${newBalance.toFixed(2)}.`,
        route: "/shell?tab=wallet",
        metadata: { amount: diff, balance: newBalance },
      });
    } else if (newBalance < 10 && prevBalance >= 10) {
      await sendNotification(uid, {
        type:  "wallet",
        title: "Low wallet balance ⚠️",
        body:  `Your balance is GHS ${newBalance.toFixed(2)}. Top up to keep using CTSRide.`,
        route: "/shell?tab=wallet",
        metadata: { balance: newBalance },
      });
    }
  }
);

// ── Wallet deduction on delivery completion ──────────────────────────────────

exports.onDeliveryCompleted = onDocumentUpdated(
  "deliveries/{deliveryId}",
  async (event) => {
    const before     = event.data.before.data();
    const after      = event.data.after.data();
    const deliveryId = event.params.deliveryId;

    // Only fire on status → completed
    if (before.status === after.status) return;
    if (after.status !== "completed")   return;

    const uid  = after.passengerId;
    const fare = after.actualFare ?? after.estimatedFare ?? 0;

    if (!uid || fare <= 0) return;

    try {
      // 1 — Deduct from wallet
      const walletRef = db.collection("wallets").doc(uid);
      await db.runTransaction(async (tx) => {
        const wallet = await tx.get(walletRef);
        if (!wallet.exists) throw new Error("Wallet not found");

        const currentBalance = wallet.data().balance ?? 0;
        if (currentBalance < fare) throw new Error("Insufficient balance");

        tx.update(walletRef, {
          balance:   admin.firestore.FieldValue.increment(-fare),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      });

      // 2 — Write transaction record
      await db.collection("transactions").add({
        userId:      uid,
        type:        "debit",
        amount:      fare,
        currency:    "GHS",
        description: `Delivery to ${after.dropoffAddress ?? "destination"}`,
        referenceId: deliveryId,
        referenceType: "delivery",
        status:      "completed",
        createdAt:   admin.firestore.FieldValue.serverTimestamp(),
      });

      // 3 — Notify passenger
      await sendNotification(uid, {
        type:  "wallet",
        title: "Payment deducted 💳",
        body:  `GHS ${fare.toFixed(2)} deducted for your delivery to ${after.dropoffAddress ?? "destination"}.`,
        route: "/shell?tab=wallet",
        metadata: { amount: fare, deliveryId },
      });

    } catch (e) {
      console.error("Delivery wallet deduction failed:", e.message);

      // Notify passenger of failure
      await sendNotification(uid, {
        type:  "wallet",
        title: "Payment failed ⚠️",
        body:  "We couldn't process your delivery payment. Please top up your wallet.",
        route: "/shell?tab=wallet",
        metadata: { deliveryId },
      });
    }
  }
);