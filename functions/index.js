const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

admin.initializeApp();

exports.onDriverAlertCreated = onDocumentCreated(
  "driver_alerts/{tripId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const alert = snap.data();
    const { tripId, pickupLocation, serviceType } = alert;

    const db = admin.firestore();

    // Query available drivers
    const driversSnap = await db
      .collection("drivers")
      .where("isAvailable", "==", true)
      .where("isOnline", "==", true)
      .where("serviceTypes", "array-contains", serviceType)
      .get();

    if (driversSnap.empty) {
      await db.collection("trips").doc(tripId).update({
        status: "noDriversAvailable",
      });
      return;
    }

    // Filter by distance (5km)
    const nearby = driversSnap.docs.filter((doc) => {
      const driverLoc = doc.data().location;
      const dist = haversineKm(
        pickupLocation.latitude,
        pickupLocation.longitude,
        driverLoc.latitude,
        driverLoc.longitude
      );
      return dist <= 5.0;
    });

    if (nearby.length === 0) {
      await db.collection("trips").doc(tripId).update({
        status: "noDriversAvailable",
      });
      return;
    }

    // Send FCM
    const tokens = nearby.map((d) => d.data().fcmToken).filter(Boolean);

    await admin.messaging().sendEachForMulticast({
      tokens,
      data: { tripId, type: "NEW_TRIP_REQUEST" },
      notification: {
        title: "New ride request",
        body: `Pickup: ${alert.pickupAddress ?? "Nearby location"}`,
      },
    });

    await snap.ref.update({
      status: "sent",
      driverCount: nearby.length,
    });
  }
);

// Haversine distance
function haversineKm(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) *
      Math.cos(lat2 * Math.PI / 180) *
      Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}