"use strict";

const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

// One device, one driver. When a driver saves an FCM token, any other driver
// document still holding the same token (a previous account on this device
// whose sign-out could not clear it, for example offline) loses it, so that
// account's private request notifications never reach this device.
// Dispatch also refuses a token shared by two candidates (dispatch_policy.js
// selectRecipients); this removes the stale copy for good.
//
// Cost: Firestore triggers cannot filter on a field, so this runs on every
// drivers/{id} write (location updates included) and returns before any
// read unless the token changed. syncDriverMap has the same trigger.

/** The token this write newly saved, or null. Pure. */
function newlySavedToken(before, after) {
  const token = after?.fcmToken;
  if (typeof token !== "string" || !token) return null;
  return before?.fcmToken === token ? null : token;
}

/** Milliseconds of a Firestore Timestamp, Date or ISO string; null if absent. */
function millis(t) {
  if (t == null) return null;
  if (typeof t.toMillis === "function") return t.toMillis();
  const ms = new Date(t).getTime();
  return Number.isFinite(ms) ? ms : null;
}

/**
 * Clears `token` from every driver except `ownerId` who still holds it,
 * provided the owner still holds it too and the other driver's save is not
 * newer than `savedAt` (this event's time). A late or retried event for an
 * older save therefore never takes the token from its newer owner. Returns
 * the count released.
 */
async function releaseTokenFromOtherDrivers(db, ownerId, token, savedAt) {
  const snap = await db.collection("drivers").where("fcmToken", "==", token).get();
  const ownerRef = db.collection("drivers").doc(ownerId);
  const savedMs = millis(savedAt);
  let released = 0;
  for (const doc of snap.docs) {
    if (doc.id === ownerId) continue;
    await db.runTransaction(async (tx) => {
      const [owner, other] = [await tx.get(ownerRef), await tx.get(doc.ref)];
      if (!owner.exists || owner.get("fcmToken") !== token) return; // owner moved on
      if (!other.exists || other.get("fcmToken") !== token) return;
      const otherMs = millis(other.get("fcmTokenUpdatedAt"));
      if (otherMs != null && (savedMs == null || otherMs > savedMs)) return; // newer save
      tx.update(doc.ref, { fcmToken: admin.firestore.FieldValue.delete() });
      released++;
    });
  }
  return released;
}

exports.onDriverTokenSaved = onDocumentWritten(
  { region: "europe-west2", document: "drivers/{driverId}" },
  async (event) => {
    // Location pings and other writes leave the token alone: no reads.
    const token = newlySavedToken(event.data?.before?.data(), event.data?.after?.data());
    if (!token) return;
    const released = await releaseTokenFromOtherDrivers(
      admin.firestore(), event.params.driverId, token, event.time);
    if (released > 0) console.log(`Device token moved to a new driver; released from ${released} other`);
  },
);

exports._driverTokens = { newlySavedToken, releaseTokenFromOtherDrivers };
