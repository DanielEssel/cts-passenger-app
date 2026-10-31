"use strict";

/**
 * The active-job contract: drivers/{uid}.currentTripId (+ currentTripType)
 * is the one assignment lock. Server acceptance (accept_job.js,
 * gas_supplier_fulfilment.js) sets both and isAvailable=false in the claim
 * transaction; every release (cancellation, failure, completion,
 * settlement, escrow release or recovery) frees the driver only while the
 * pointer still names the job being ended, so a late event for an older job
 * can never free a driver from a newer one, and a repeat changes nothing.
 * A release clears both pointer fields.
 */

const admin = require("firebase-admin");

/**
 * The driver-document fields that free [driver] from [jobId], or {} when
 * the driver no longer holds that job (or is unknown). Merge into the same
 * transactional update that reads the driver.
 */
function releaseFieldsIfCurrent(driver, jobId) {
  if (!driver || typeof jobId !== "string" || !jobId || driver.currentTripId !== jobId) return {};
  const del = admin.firestore.FieldValue.delete();
  return { isAvailable: true, currentTripId: del, currentTripType: del };
}

/**
 * Frees driver [driverId] from [jobId] inside transaction [tx] (which must
 * not have written yet). Returns true when it did.
 */
async function releaseDriverIfCurrent(tx, driverId, jobId) {
  if (typeof driverId !== "string" || !driverId) return false;
  const ref = admin.firestore().collection("drivers").doc(driverId);
  const snap = await tx.get(ref);
  const fields = releaseFieldsIfCurrent(snap.exists ? snap.data() : null, jobId);
  if (Object.keys(fields).length === 0) return false;
  tx.update(ref, fields);
  return true;
}

module.exports = { releaseFieldsIfCurrent, releaseDriverIfCurrent };
