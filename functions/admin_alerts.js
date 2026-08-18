const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

// Fires once when a driver crosses into the "submitted for review" state.
exports.onDriverSubmittedForReview = onDocumentUpdated(
  { region: "europe-west2", document: "drivers/{driverId}" },
  async (event) => {
    const before = event.data?.before.data() || {};
    const after = event.data?.after.data() || {};

    // Only fire on the transition into documentsUploaded — not on every edit,
    // and not if it was already in that state.
    const justSubmitted =
      after.documentsUploaded === true &&
      before.documentsUploaded !== true;

    if (!justSubmitted) return;

    const db = getFirestore();
    await db.collection("admin_alerts").add({
      type: "driver_pending",
      driverId: event.params.driverId,
      driverName: after.displayName || "New driver",
      serviceType: after.serviceType || null,
      message: `${after.displayName || "A new driver"} submitted documents for review`,
      read: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  }
);