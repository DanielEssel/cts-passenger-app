// functions/ratings.js
// Applies passenger ratings to the driver's aggregate server-side.
// Fires when passengerRating first appears on a completed job doc.
// Keeps drivers/{id}.rating (the field the apps display) consistent
// with ratingTotal / ratingCount.

"use strict";

const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

const getDb = () => admin.firestore();

function makeRatingTrigger(collection) {
  return onDocumentUpdated(
    { region: "europe-west2", document: `${collection}/{docId}` },
    async (event) => {
      const before = event.data?.before?.data();
      const after  = event.data?.after?.data();
      if (!before || !after) return;

      // Only on first appearance of a rating — makes replays idempotent
      if (before.passengerRating != null) return;
      const stars = Number(after.passengerRating);
      if (!Number.isFinite(stars) || stars < 1 || stars > 5) return;

      const driverId = after.driverId;
      if (!driverId) return;

      const ref = getDb().collection("drivers").doc(driverId);
      await getDb().runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists) return;
        const d = snap.data();
        const total = (Number(d.ratingTotal) || 0) + stars;
        const count = (Number(d.ratingCount) || 0) + 1;
        tx.update(ref, {
          ratingTotal: total,
          ratingCount: count,
          rating: Math.round((total / count) * 100) / 100,
        });
      });

      console.log(`[rating] ${collection}/${event.params.docId}: ${stars}★ → driver ${driverId}`);
    },
  );
}

exports.onTripRated     = makeRatingTrigger("trips");
exports.onDeliveryRated = makeRatingTrigger("deliveries");
exports.onGasOrderRated = makeRatingTrigger("gas_orders");