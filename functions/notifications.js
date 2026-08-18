// functions/notifications.js
const {
  onDocumentUpdated,
  onDocumentCreated,
} = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

// Lazy getters — avoids calling before admin.initializeApp()
const getDb = () => admin.firestore();
const getFcm = () => admin.messaging();

// ── Haversine distance formula ────────────────────────────────────────────────
function haversineKm(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

function statusChanged(before, after) {
  return before.status !== after.status;
}

// ── Send to PASSENGER ────────────────────────────────────────────────────────
// Reads FCM token from users/{uid}

async function notifyPassenger(
  uid,
  { type, title, body, route, metadata = {} },
) {
  if (!uid) return;

  // Write in-app notification
  await getDb()
    .collection("notifications")
    .doc(uid)
    .collection("items")
    .add({
      type,
      title,
      body,
      route: route ?? null,
      metadata,
      isRead: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    })
    .catch((e) => console.error("Passenger notif write error:", e.message));

  // FCM push
  const userDoc = await getDb().collection("users").doc(uid).get();
  const token = userDoc.data()?.fcmToken;
  if (!token) return;

  await _sendFcm(token, { type, title, body, route, metadata });
}

// ── onTripCreatedNotify: broadcast new ride requests to nearby drivers ───────
// Companion to onGasOrderCreated / onDeliveryCreated. The fare-validation
// onTripCreated in trips.js is separate; two create-triggers on trips/ is fine.
exports.onTripCreatedNotify = onDocumentCreated(
  { region: "europe-west2", document: "trips/{tripId}" },
  async (event) => {
    const data = event.data?.data();
    const tripId = event.params.tripId;
    if (!data) return;

    // Only broadcast while unassigned & searching
    if (data.driverId) return;
    if (data.status && data.status !== "searching") return;

    try {
      const lat = data.pickupLocation?.latitude ?? 0;
      const lng = data.pickupLocation?.longitude ?? 0;

      const driversSnap = await getDb()
        .collection("drivers")
        .where("isAvailable", "==", true)
        .where("isOnline", "==", true)
        .where("isApproved", "==", true)
        .where("role", "==", "driver_hailing") // ← ride vs delivery bucket
        .where("serviceType", "==", data.serviceType) // ← taxi vs pragyia, matches the trip
        .get();

      if (driversSnap.empty) {
        console.log(`Trip ${tripId}: no available ride drivers`);
        return;
      }

      const now = Date.now();
      const nearby = driversSnap.docs.filter((doc) => {
        const d = doc.data();
        const loc = d.location;
        if (!loc) return false;
        // Stale-location tolerance: if the last update is >15 min old the
        // position is unreliable — include the driver rather than silently
        // excluding them. Over-notifying beats no-dispatch for a small fleet.
        const updatedAt =
          d.locationUpdatedAt?.toMillis?.() ??
          d.lastLocationUpdate?.toMillis?.() ??
          0;
        if (now - updatedAt > 15 * 60 * 1000) return true;
        return haversineKm(lat, lng, loc.latitude, loc.longitude) <= 10.0;
      });

      if (nearby.length === 0) {
        console.log(`Trip ${tripId}: no drivers within 10km`);
        return;
      }

      const tokens = nearby.map((d) => d.data().fcmToken).filter(Boolean);
      if (tokens.length === 0) return;

      // Write in-app notification doc for each nearby driver (bell inbox)
      const batch = getDb().batch();
      for (const doc of nearby) {
        const ref = getDb()
          .collection("drivers")
          .doc(doc.id)
          .collection("notifications")
          .doc();
        batch.set(ref, {
          type: "rideRequest",
          title: "New Ride Request 🛵",
          body: `${data.pickupAddress ?? "Nearby pickup"} → ${data.dropoffAddress ?? "destination"} · GH₵${Number(data.estimatedFare ?? 0).toFixed(2)}`,
          route: "/driver-shell",
          metadata: { tripId },
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      await batch
        .commit()
        .catch((e) =>
          console.error(`Trip ${tripId}: notif batch write failed:`, e.message),
        );

      const response = await admin.messaging().sendEachForMulticast({
        tokens,
        android: {
          priority: "high", // ← immediate delivery even in Doze
          notification: {
            channelId: "driver_trips", // ← the high-importance channel the app creates
            sound: "default",
          },
        },
        apns: {
          payload: { aps: { sound: "default" } },
        },
        data: {
          type: "NEW_RIDE_REQUEST",
          tripId,
          pickupAddress: data.pickupAddress ?? "",
          dropoffAddress: data.dropoffAddress ?? "",
          estimatedFare: String(data.estimatedFare ?? 0),
          title: "🛵 New Ride Request",
          body: `${data.pickupAddress ?? "Nearby pickup"} → ${data.dropoffAddress ?? "destination"} · GH₵${Number(data.estimatedFare ?? 0).toFixed(2)}`,
        },
      });

      console.log(
        `Trip ${tripId}: FCM successCount=${response.successCount}, failureCount=${response.failureCount}`,
      );
      response.responses.forEach((r, i) => {
        if (!r.success) {
          console.error(
            `Trip ${tripId}: token ${tokens[i].slice(0, 20)}... failed:`,
            r.error?.code,
            r.error?.message,
          );
        } else {
          console.log(
            `Trip ${tripId}: token ${tokens[i].slice(0, 20)}... delivered OK`,
          );
        }
      });
    } catch (err) {
      console.error(`Trip ${tripId}: notify failed (non-fatal):`, err);
    }
  },
);

// ── Send to DRIVER ────────────────────────────────────────────────────────────
// Reads FCM token from drivers/{uid}

async function notifyDriver(uid, { type, title, body, route, metadata = {} }) {
  if (!uid) return;

  // Write in-app notification to driver notifications subcollection
  await getDb()
    .collection("drivers")
    .doc(uid)
    .collection("notifications")
    .add({
      type,
      title,
      body,
      route: route ?? null,
      metadata,
      isRead: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    })
    .catch((e) => console.error("Driver notif write error:", e.message));

  // FCM push — token from drivers/{uid}
  const driverDoc = await getDb().collection("drivers").doc(uid).get();
  const token = driverDoc.data()?.fcmToken;
  if (!token) return;

  await _sendFcm(token, { type, title, body, route, metadata });
}

// ── FCM sender ────────────────────────────────────────────────────────────────

async function _sendFcm(token, { type, title, body, route, metadata = {} }) {
  try {
    await getFcm().send({
      token,
      notification: { title, body },
      data: {
        type,
        route: route ?? "",
        ...Object.fromEntries(
          Object.entries(metadata).map(([k, v]) => [k, String(v)]),
        ),
      },
      android: {
        priority: "high",
        notification: {
          channelId: "CTSDriver_general",
          priority: "high",
          sound: "default",
        },
      },
      apns: {
        payload: { aps: { sound: "default", badge: 1 } },
      },
    });
  } catch (e) {
    console.error("FCM send error:", e.message);
  }
}

// ── Document label ────────────────────────────────────────────────────────────

function _docLabel(key) {
  const labels = {
    profile_photo: "Profile Photo",
    national_id: "National ID",
    drivers_license: "Driver's License",
    vehicle_registration: "Vehicle Registration",
    roadworthy_certificate: "Roadworthy Certificate",
    insurance: "Vehicle Insurance",
    police_clearance: "Police Clearance",
    vehicle_photo_front: "Vehicle Front Photo",
    vehicle_photo_side: "Vehicle Side Photo",
  };
  return labels[key] ?? key;
}

// ─────────────────────────────────────────────────────────────────────────────
// TRIPS — Passenger & Driver notifications
// ─────────────────────────────────────────────────────────────────────────────

exports.onTripStatusChanged = onDocumentUpdated(
  { region: "europe-west2", document: "trips/{tripId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const tripId = event.params.tripId;

    if (!statusChanged(before, after)) return;

    const passengerId = after.passengerId;
    const driverId = after.driverId;
    const driverName = after.driverName ?? "Your driver";
    const passengerName = after.passengerName ?? "Passenger";
    const dropoff = after.dropoffAddress ?? "destination";
    const pickup = after.pickupAddress ?? "pickup";
    const fare = (after.actualFare ?? after.estimatedFare ?? 0).toFixed(2);

    const passengerRoute = `/ride-tracking?tripId=${tripId}`;
    const driverRoute = `/driver/trip-active?tripId=${tripId}`;
    const meta = { tripId };

    switch (after.status) {
      // ── Driver accepted — notify passenger ──
      case "tripAccepted":
        await notifyPassenger(passengerId, {
          type: "ride",
          title: "Driver assigned 🚗",
          body: `${driverName} is on the way to ${pickup}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      // ── Driver arrived — notify passenger ──
      case "driverArrived":
        await notifyPassenger(passengerId, {
          type: "ride",
          title: "Driver has arrived 📍",
          body: `${driverName} is waiting at your pickup point.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      // ── Trip started — notify passenger ──
      case "tripStarted":
        await notifyPassenger(passengerId, {
          type: "ride",
          title: "Trip started 🚦",
          body: `You're on your way to ${dropoff}. Sit back and enjoy!`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      // ── Trip completed — notify both ──
      case "completed":
        await Promise.all([
          // Passenger
          notifyPassenger(passengerId, {
            type: "ride",
            title: "Trip completed ✓",
            body: `Your trip to ${dropoff} was GHS ${fare}. Rate your driver!`,
            route: `/trip-complete?tripId=${tripId}`,
            metadata: { ...meta, fare },
          }),
          // Driver
          driverId
            ? notifyDriver(driverId, {
                type: "ride",
                title: "Trip completed 💰",
                body: `GHS ${fare} earned. Great job!`,
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
          // Reset driver availability
          driverId
            ? getDb()
                .collection("drivers")
                .doc(driverId)
                .update({
                  isAvailable: true,
                  currentTripId: admin.firestore.FieldValue.delete(),
                })
                .catch((e) => console.error("Driver reset error:", e.message))
            : Promise.resolve(),
        ]);
        break;

      // ── Cancelled by passenger — notify driver ──
      case "cancelledByPassenger":
        await Promise.all([
          driverId
            ? notifyDriver(driverId, {
                type: "ride",
                title: "Trip cancelled by passenger",
                body: `${passengerName} cancelled the trip. You're available for new requests.`,
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
          // Reset driver
          driverId
            ? getDb()
                .collection("drivers")
                .doc(driverId)
                .update({
                  isAvailable: true,
                  currentTripId: admin.firestore.FieldValue.delete(),
                })
                .catch((e) => console.error("Driver reset error:", e.message))
            : Promise.resolve(),
        ]);
        break;

      // ── Cancelled by driver — notify passenger ──
      case "cancelledByDriver":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "ride",
            title: "Driver cancelled",
            body: "Your driver cancelled the trip. Please book again.",
            route: "/shell",
            metadata: meta,
          }),
          // Reset driver
          driverId
            ? getDb()
                .collection("drivers")
                .doc(driverId)
                .update({
                  isAvailable: true,
                  currentTripId: admin.firestore.FieldValue.delete(),
                })
                .catch((e) => console.error("Driver reset error:", e.message))
            : Promise.resolve(),
        ]);
        break;

      // ── No drivers — notify passenger ──
      case "noDriversAvailable":
        await notifyPassenger(passengerId, {
          type: "ride",
          title: "No drivers nearby 😔",
          body: "We couldn't find a driver right now. Please try again in a few minutes.",
          route: "/shell",
          metadata: meta,
        });
        break;
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// GAS ORDERS — Passenger & Driver notifications
// ─────────────────────────────────────────────────────────────────────────────

exports.onGasOrderCreated = onDocumentCreated(
  { region: "europe-west2", minInstances: 0, document: "gas_orders/{orderId}" },
  async (event) => {
    const data = event.data.data();
    const orderId = event.params.orderId;
    const uid = data.passengerId;

    // ── 1. Notify passenger ───────────────────────────────────────────────
    await notifyPassenger(uid, {
      type: "gas",
      title: "Gas order placed ✓",
      body: `Your ${data.cylinderSize ?? "gas"} order is pending approval.`,
      route: `/gas-tracking?orderId=${orderId}`,
      metadata: { orderId },
    });

    // ── 2. Notify nearby available delivery drivers via FCM ───────────────
    try {
      const deliveryLat =
        data.deliveryLocation?.latitude ?? data.pickupLocation?.latitude ?? 0;
      const deliveryLng =
        data.deliveryLocation?.longitude ?? data.pickupLocation?.longitude ?? 0;

      const driversSnap = await getDb()
        .collection("drivers")
        .where("isAvailable", "==", true)
        .where("isOnline", "==", true)
        .where("isApproved", "==", true)
        .where("role", "==", "driver_delivery")
        .get();

      if (driversSnap.empty) {
        console.log(`Gas order ${orderId}: no available delivery drivers`);
        return;
      }

      const nearby = driversSnap.docs.filter((doc) => {
        const loc = doc.data().location;
        if (!loc) return false;
        return (
          haversineKm(deliveryLat, deliveryLng, loc.latitude, loc.longitude) <=
          10.0
        );
      });

      if (nearby.length === 0) {
        console.log(`Gas order ${orderId}: no drivers within 10km`);
        return;
      }

      const tokens = nearby.map((d) => d.data().fcmToken).filter(Boolean);
      if (tokens.length === 0) return;

      const batch = getDb().batch();
      for (const doc of nearby) {
        const ref = getDb()
          .collection("drivers")
          .doc(doc.id)
          .collection("notifications")
          .doc();
        batch.set(ref, {
          type: "gasOrder",
          title: "New Gas Order 🔥",
          body: `${data.cylinderSize ?? "Gas cylinder"} delivery — ${data.deliveryAddress ?? "Nearby"}`,
          route: "/driver-shell",
          metadata: { orderId },
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      await batch
        .commit()
        .catch((e) =>
          console.error(
            `Gas order ${orderId}: notif batch write failed:`,
            e.message,
          ),
        );

      await admin.messaging().sendEachForMulticast({
        tokens,
        android: {
          priority: "high",
          notification: { channelId: "driver_trips", sound: "default" },
        },
        apns: { payload: { aps: { sound: "default" } } },
        data: {
          type: "NEW_GAS_REQUEST",
          orderId,
          pickupAddress: data.pickupAddress ?? "",
          deliveryAddress: data.deliveryAddress ?? "",
          cylinderSize: data.cylinderSize ?? "",
          totalPrice: String(data.totalPrice ?? 0),
          title: "🔥 New Gas Order",
          body: `${data.cylinderSize ?? "Gas cylinder"} delivery — ${data.deliveryAddress ?? "Nearby"}`,
        },
      });
      console.log(`Gas order ${orderId}: FCM sent to ${tokens.length} drivers`);
    } catch (e) {
      console.error(
        `Gas order ${orderId}: driver notification failed:`,
        e.message,
      );
    }
  },
);

// ── onDeliveryCreated: notify passenger + nearby drivers ─────────────────────
exports.onDeliveryCreated = onDocumentCreated(
  {
    region: "europe-west2",
    minInstances: 0,
    document: "deliveries/{deliveryId}",
  },
  async (event) => {
    const data = event.data.data();
    const deliveryId = event.params.deliveryId;
    const uid = data.passengerId;

    // ── 1. Notify passenger ───────────────────────────────────────────────
    await notifyPassenger(uid, {
      type: "delivery",
      title: "Delivery request placed ✓",
      body: `Looking for a driver to deliver your ${data.parcelType ?? "parcel"}.`,
      route: `/delivery-tracking?deliveryId=${deliveryId}`,
      metadata: { deliveryId },
    });

    // ── 2. Notify nearby delivery drivers ─────────────────────────────────
    try {
      const pickupLat = data.pickupLocation?.latitude ?? 0;
      const pickupLng = data.pickupLocation?.longitude ?? 0;

      const driversSnap = await getDb()
        .collection("drivers")
        .where("isAvailable", "==", true)
        .where("isOnline", "==", true)
        .where("isApproved", "==", true)
        .where("role", "==", "driver_delivery")
        .get();

      if (driversSnap.empty) {
        console.log(`Delivery ${deliveryId}: no available drivers`);
        return;
      }

      const nearby = driversSnap.docs.filter((doc) => {
        const loc = doc.data().location;
        if (!loc) return false;
        return (
          haversineKm(pickupLat, pickupLng, loc.latitude, loc.longitude) <= 10.0
        );
      });

      if (nearby.length === 0) {
        console.log(`Delivery ${deliveryId}: no drivers within 10km`);
        return;
      }

      const tokens = nearby.map((d) => d.data().fcmToken).filter(Boolean);
      if (tokens.length === 0) return;

      const batch = getDb().batch();
      for (const doc of nearby) {
        const ref = getDb()
          .collection("drivers")
          .doc(doc.id)
          .collection("notifications")
          .doc();
        batch.set(ref, {
          type: "delivery",
          title: "New Delivery Request 📦",
          body: `${data.parcelType ?? "Parcel"} — ${data.pickupAddress ?? "Nearby"}`,
          route: "/driver-shell",
          metadata: { deliveryId },
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      await batch
        .commit()
        .catch((e) =>
          console.error(
            `Delivery ${deliveryId}: notif batch write failed:`,
            e.message,
          ),
        );

      await admin.messaging().sendEachForMulticast({
        tokens,
        android: {
          priority: "high",
          notification: { channelId: "driver_trips", sound: "default" },
        },
        apns: { payload: { aps: { sound: "default" } } },
        data: {
          type: "NEW_DELIVERY_REQUEST",
          deliveryId,
          pickupAddress: data.pickupAddress ?? "",
          dropoffAddress: data.dropoffAddress ?? "",
          parcelType: data.parcelType ?? "",
          estimatedFare: String(data.estimatedFare ?? 0),
          weightTier: data.weightTier ?? "",
          title: "📦 New Delivery Request",
          body: `${data.parcelType ?? "Parcel"} — ${data.pickupAddress ?? "Nearby"}`,
        },
      });
      console.log(
        `Delivery ${deliveryId}: FCM sent to ${tokens.length} drivers`,
      );
    } catch (e) {
      console.error(
        `Delivery ${deliveryId}: driver notification failed:`,
        e.message,
      );
    }
  },
);

exports.onGasOrderStatusChanged = onDocumentUpdated(
  { region: "europe-west2", document: "gas_orders/{orderId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const orderId = event.params.orderId;

    if (!statusChanged(before, after)) return;

    const passengerId = after.passengerId;
    const driverId = after.driverId;
    const driverName = after.driverName ?? "Your driver";
    const cylinderSize = after.cylinderSize ?? "gas cylinder";
    const totalPrice = (after.totalPrice ?? 0).toFixed(2);

    const passengerRoute = `/gas-tracking?orderId=${orderId}`;
    const driverRoute = `/driver/active-gas?orderId=${orderId}`;
    const meta = { orderId };

    switch (after.status) {
      case "driverAssigned":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "gas",
            title: "Gas order confirmed 🔥",
            body: `${driverName} will pick up your ${cylinderSize} shortly.`,
            route: passengerRoute,
            metadata: meta,
          }),
          driverId
            ? notifyDriver(driverId, {
                type: "gas",
                title: "New gas order 🔥",
                body: `Pick up ${cylinderSize} for delivery.`,
                route: driverRoute,
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;

      case "driverEnRoute":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "Driver en route 🚗",
          body: `${driverName} is heading to your location.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "driverArrived":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "Driver has arrived 📍",
          body: `${driverName} is at your location with your ${cylinderSize}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "pickedUp":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "Cylinder collected 📦",
          body: `${driverName} has collected your ${cylinderSize}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;
      case "atStation":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "At the refill station ⛽",
          body: `Your ${cylinderSize} has reached the station for refilling.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;
      case "refilling":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "Refilling your cylinder 🔥",
          body: `Your ${cylinderSize} is being refilled now.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;
      case "returning":
        await notifyPassenger(passengerId, {
          type: "gas",
          title: "On the way back 🔄",
          body: `${driverName} is returning with your refilled ${cylinderSize}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "delivered":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "gas",
            title: "Gas delivered! 🎉",
            body: `Your ${cylinderSize} has been delivered. Total: GHS ${totalPrice}.`,
            route: "/shell",
            metadata: { ...meta, totalPrice },
          }),
          driverId
            ? notifyDriver(driverId, {
                type: "gas",
                title: "Gas order completed 💰",
                body: `GHS ${totalPrice} earned for gas delivery.`,
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;

      case "cancelledByPassenger":
      case "cancelled":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "gas",
            title: "Gas order cancelled",
            body: "Your gas order was cancelled. Any charges will be refunded.",
            route: "/shell",
            metadata: meta,
          }),
          driverId
            ? notifyDriver(driverId, {
                type: "gas",
                title: "Gas order cancelled",
                body: "The gas order was cancelled by the passenger.",
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// DELIVERIES — Passenger & Driver notifications
// ─────────────────────────────────────────────────────────────────────────────

exports.onDeliveryStatusChanged = onDocumentUpdated(
  { region: "europe-west2", document: "deliveries/{deliveryId}" }, // ✅ Fixed collection name
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const deliveryId = event.params.deliveryId;

    if (!statusChanged(before, after)) return;

    const passengerId = after.passengerId ?? after.userId;
    const driverId = after.driverId;
    const driverName = after.driverName ?? "Your rider";
    const dropoff = after.dropoffAddress ?? "destination";
    const fare = (after.actualFare ?? after.estimatedFare ?? 0).toFixed(2);

    const passengerRoute = `/delivery-tracking?deliveryId=${deliveryId}`;
    const driverRoute = `/driver/active-delivery?deliveryId=${deliveryId}`;
    const meta = { deliveryId };

    switch (after.status) {
      case "driverAssigned":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "delivery",
            title: "Rider assigned 🏍️",
            body: `${driverName} will pick up your parcel shortly.`,
            route: passengerRoute,
            metadata: meta,
          }),
          driverId
            ? notifyDriver(driverId, {
                type: "delivery",
                title: "New delivery request 📦",
                body: `Pick up parcel for delivery to ${dropoff}.`,
                route: driverRoute,
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;

      case "pickupEnroute":
        await notifyPassenger(passengerId, {
          type: "delivery",
          title: "Rider on the way 🏍️",
          body: `${driverName} is heading to pick up your parcel.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "arrivedAtPickup":
        await notifyPassenger(passengerId, {
          type: "delivery",
          title: "Rider arrived at pickup 📍",
          body: `${driverName} has arrived to collect your parcel.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "packagePicked":
        await notifyPassenger(passengerId, {
          type: "delivery",
          title: "Parcel picked up 📦",
          body: `${driverName} has collected your parcel and is heading to ${dropoff}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "deliveryEnroute":
        await notifyPassenger(passengerId, {
          type: "delivery",
          title: "Parcel out for delivery 🚀",
          body: `Your parcel is on the way to ${dropoff}.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "arrivedAtDropoff":
        await notifyPassenger(passengerId, {
          type: "delivery",
          title: "Rider at drop-off 📍",
          body: `${driverName} has arrived at ${dropoff} with your parcel.`,
          route: passengerRoute,
          metadata: meta,
        });
        break;

      case "completed":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "delivery",
            title: "Parcel delivered! ✓",
            body: `Your parcel was delivered to ${dropoff}. Total: GHS ${fare}.`,
            route: "/shell",
            metadata: { ...meta, fare },
          }),
          driverId
            ? notifyDriver(driverId, {
                type: "delivery",
                title: "Delivery completed 💰",
                body: `GHS ${fare} earned for delivery to ${dropoff}.`,
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;

      case "cancelledByPassenger":
      case "cancelled":
        await Promise.all([
          notifyPassenger(passengerId, {
            type: "delivery",
            title: "Delivery cancelled",
            body: "Your delivery was cancelled. Contact support if you need help.",
            route: "/shell",
            metadata: meta,
          }),
          driverId
            ? notifyDriver(driverId, {
                type: "delivery",
                title: "Delivery cancelled",
                body: "The delivery was cancelled by the passenger.",
                route: "/driver-shell",
                metadata: meta,
              })
            : Promise.resolve(),
        ]);
        break;
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// WALLET — Low balance alert (passengers only)
// ─────────────────────────────────────────────────────────────────────────────

exports.onWalletChanged = onDocumentUpdated(
  { region: "europe-west2", document: "wallets/{uid}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const uid = event.params.uid;

    const prevBalance = before.balance ?? 0;
    const newBalance = after.balance ?? 0;
    const diff = newBalance - prevBalance;

    if (Math.abs(diff) < 0.01) return;

    // ✅ Only notify on top-up (credit) or low balance — not every debit
    if (diff > 0) {
      // Wallet topped up
      await notifyPassenger(uid, {
        type: "wallet",
        title: "Wallet topped up 💳",
        body: `GHS ${diff.toFixed(2)} added. Balance: GHS ${newBalance.toFixed(2)}.`,
        route: "/shell?tab=wallet",
        metadata: { amount: diff, balance: newBalance },
      });
    } else if (newBalance < 10 && prevBalance >= 10) {
      // Only notify once when balance drops below threshold
      await notifyPassenger(uid, {
        type: "wallet",
        title: "Low wallet balance ⚠️",
        body: `Your balance is GHS ${newBalance.toFixed(2)}. Top up to keep using CTSTransport.`,
        route: "/shell?tab=wallet",
        metadata: { balance: newBalance },
      });
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// DELIVERY WALLET DEDUCTION — on delivery completion
// ─────────────────────────────────────────────────────────────────────────────

exports.onDeliveryCompleted = onDocumentUpdated(
  { region: "europe-west2", document: "deliveries/{deliveryId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const deliveryId = event.params.deliveryId;

    if (before.status === after.status) return;
    if (after.status !== "completed") return;

    const uid = after.passengerId;
    const fare = after.actualFare ?? after.estimatedFare ?? 0;

    if (!uid || fare <= 0) return;

    try {
      const walletRef = getDb().collection("wallets").doc(uid);

      await getDb().runTransaction(async (tx) => {
        const wallet = await tx.get(walletRef);
        if (!wallet.exists) throw new Error("Wallet not found");
        const balance = wallet.data().balance ?? 0;
        if (balance < fare) throw new Error("Insufficient balance");
        tx.update(walletRef, {
          balance: admin.firestore.FieldValue.increment(-fare),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      });

      await getDb()
        .collection("transactions")
        .add({
          userId: uid,
          type: "debit",
          amount: fare,
          currency: "GHS",
          description: `Delivery to ${after.dropoffAddress ?? "destination"}`,
          referenceId: deliveryId,
          referenceType: "delivery",
          status: "completed",
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    } catch (e) {
      console.error("Delivery wallet deduction failed:", e.message);
      await notifyPassenger(uid, {
        type: "wallet",
        title: "Payment failed ⚠️",
        body: "We couldn't process your delivery payment. Please top up your wallet.",
        route: "/shell?tab=wallet",
        metadata: { deliveryId },
      });
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// DOCUMENT EXPIRY CHECK — daily at 8am Ghana time
// ─────────────────────────────────────────────────────────────────────────────

exports.checkDocumentExpiry = onSchedule(
  {
    schedule: "0 8 * * *",
    timeZone: "Africa/Accra",
    region: "europe-west2",
    minInstances: 0,
  },
  async () => {
    const now = new Date();

    const drivers = await getDb()
      .collection("drivers")
      .where("isApproved", "==", true)
      .get();

    const promises = [];

    for (const driverDoc of drivers.docs) {
      const data = driverDoc.data();
      const documents = data.documents ?? {};
      const fcmToken = data.fcmToken;
      const uid = driverDoc.id;

      for (const [key, value] of Object.entries(documents)) {
        if (!value?.expiryDate) continue;

        const expiry = value.expiryDate.toDate();
        const daysLeft = Math.ceil((expiry - now) / (1000 * 60 * 60 * 24));
        const label = _docLabel(key);

        let payload = null;

        if (daysLeft <= 0) {
          payload = {
            type: "documentExpiry",
            title: `⚠️ ${label} Expired`,
            body: `Your ${label} has expired. Upload a new one to continue driving.`,
            route: "/driver/documents",
          };
        } else if (daysLeft <= 7) {
          payload = {
            type: "documentExpiry",
            title: `⏰ ${label} Expiring Soon`,
            body: `Your ${label} expires in ${daysLeft} day${daysLeft === 1 ? "" : "s"}. Update it now.`,
            route: "/driver/documents",
          };
        } else if (daysLeft <= 30) {
          payload = {
            type: "documentExpiry",
            title: `📅 ${label} Expiring in ${daysLeft} Days`,
            body: `Your ${label} expires on ${expiry.toDateString()}. Plan to renew it soon.`,
            route: "/driver/documents",
          };
        }

        if (payload) {
          promises.push(notifyDriver(uid, payload));
        }
      }
    }

    await Promise.allSettled(promises);
    console.log(
      `Document expiry check complete. Processed ${drivers.size} drivers.`,
    );
  },
);

// ── Admin broadcast notification ──────────────────────────────────────────────
const { onCall, HttpsError } = require("firebase-functions/v2/https");

exports.broadcastNotification = onCall(
  { region: "europe-west2", minInstances: 0 },
  async (request) => {
    // Verify admin
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in");

    const adminDoc = await getDb().collection("admins").doc(uid).get();
    if (!adminDoc.exists || !adminDoc.data()?.active) {
      throw new HttpsError("permission-denied", "Admin access required");
    }

    const { title, message, target, userId } = request.data;
    if (!title || !message) {
      throw new HttpsError("invalid-argument", "Title and message required");
    }

    let tokens = [];
    let targetUids = [];

    if (target === "all_passengers") {
      const snap = await getDb()
        .collection("users")
        .where("fcmToken", "!=", null)
        .get();
      snap.docs.forEach((d) => {
        if (d.data().fcmToken) {
          tokens.push(d.data().fcmToken);
          targetUids.push(d.id);
        }
      });
    } else if (target === "all_drivers") {
      const snap = await getDb()
        .collection("drivers")
        .where("fcmToken", "!=", null)
        .get();
      snap.docs.forEach((d) => {
        if (d.data().fcmToken) {
          tokens.push(d.data().fcmToken);
          targetUids.push(d.id);
        }
      });
    } else if (target === "specific_user" && userId) {
      // Try users first, then drivers
      const userDoc = await getDb().collection("users").doc(userId).get();
      const driverDoc = await getDb().collection("drivers").doc(userId).get();
      const token = userDoc.data()?.fcmToken || driverDoc.data()?.fcmToken;
      if (token) {
        tokens.push(token);
        targetUids.push(userId);
      }
    }

    if (tokens.length === 0) {
      return {
        success: false,
        message: "No FCM tokens found for target audience",
      };
    }

    // Send FCM in batches of 500
    const batchSize = 500;
    let successCount = 0;
    let failCount = 0;

    for (let i = 0; i < tokens.length; i += batchSize) {
      const batch = tokens.slice(i, i + batchSize);
      try {
        const response = await getFcm().sendEachForMulticast({
          tokens: batch,
          notification: { title, body: message },
          data: { type: "admin_broadcast", route: "" },
          android: {
            priority: "high",
            notification: {
              channelId: "CTSDriver_general",
              sound: "default",
            },
          },
          apns: {
            payload: { aps: { sound: "default", badge: 1 } },
          },
        });
        successCount += response.successCount;
        failCount += response.failureCount;
      } catch (e) {
        console.error("Batch FCM error:", e.message);
        failCount += batch.length;
      }
    }

    // Write to in-app notifications for all targets
    const batch = getDb().batch();
    for (const uid of targetUids) {
      const collection =
        target === "all_drivers"
          ? getDb().collection("drivers").doc(uid).collection("notifications")
          : getDb().collection("notifications").doc(uid).collection("items");
      const ref = collection.doc();
      batch.set(ref, {
        type: "admin_broadcast",
        title,
        body: message,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    await batch
      .commit()
      .catch((e) => console.error("Batch write error:", e.message));

    console.log(
      `Broadcast: ${successCount} sent, ${failCount} failed to ${tokens.length} devices`,
    );
    return {
      success: true,
      sent: successCount,
      failed: failCount,
      totalTargets: tokens.length,
    };
  },
);
