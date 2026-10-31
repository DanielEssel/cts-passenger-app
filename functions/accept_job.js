"use strict";

/**
 * Server-side acceptance for Ride, Delivery and Gas requests.
 *
 * One transaction reads the job and the driver, applies the dispatch policy
 * (dispatch_policy.js: the same checks notification dispatch uses,
 * including the offer radius), then assigns the job and marks the driver
 * busy (isAvailable false, currentTripId) in the same commit. Two claims
 * for the same job, or one driver claiming two jobs at once, conflict on a
 * document the other transaction read, so exactly one succeeds.
 *
 * Results are { success: true, <idField>: id } or
 * { success: false, reason, detail? }. `reason` keeps the values the
 * released Driver App maps for acceptGasOrder; `detail` is the policy's own
 * reason, for newer builds and logs. No names, phones or locations are
 * logged.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { jobRejection, driverRejection } = require("./dispatch_policy");
const { verifyGasOrderPrice, verifiedPriceStamp, stampedPrice } = require("./gas_pricing");
const { OFFER_COLLECTION } = require("./order_offers");
const { stampedDeliveryPrice } = require("./delivery_quotes");

const JOBS = Object.freeze({
  ride: { collection: "trips", open: "searching", accepted: "tripAccepted", referenceType: "trip" },
  delivery: { collection: "deliveries", open: "pending", accepted: "driverAssigned", referenceType: "delivery" },
  gas: { collection: "gas_orders", open: "pendingApproval", accepted: "driverAssigned", referenceType: "gas_order" },
});

/** Policy reason → the reason the released Driver App understands. */
function clientReason(rejection) {
  switch (rejection) {
    case "driver_not_found":
    case "vehicle_not_eligible":
    case "driver_on_job":
      return rejection;
    case "driver_location_invalid":
    case "outside_radius":
      return "outside_radius";
    default:
      return "driver_not_eligible";
  }
}

/** The fields the Driver App's accept transaction wrote, now written here. */
function assignmentFields(service, uid, driver, accepted) {
  return {
    driverId: uid,
    driverName: driver.displayName ?? driver.name ?? "Driver",
    driverPhone: driver.phone ?? driver.phoneNumber ?? "",
    driverRating: driver.rating ?? 5.0,
    ...(service === "ride" ? { driverPlate: driver.vehiclePlate ?? "" } : {}),
    status: accepted,
    acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

/**
 * Accepts [jobId] of [service] for driver [uid]. Never throws for a refusal;
 * throws only when the transaction itself fails.
 */
async function acceptJob(service, uid, jobId) {
  const job = JOBS[service];
  const db = admin.firestore();
  const jobRef = db.collection(job.collection).doc(jobId);
  const driverRef = db.collection("drivers").doc(uid);
  // Delivery and Gas: the open-request projection drivers browse
  // (order_offers.js). It goes in the same commit as the assignment, and a
  // stale one (its order taken or gone) is removed when someone tries it.
  const offerRef = OFFER_COLLECTION[job.collection]
    ? db.collection(OFFER_COLLECTION[job.collection]).doc(jobId) : null;
  const dropOffer = (tx) => { if (offerRef) tx.delete(offerRef); };

  return db.runTransaction(async (tx) => {
    const [jobSnap, driverSnap] = await Promise.all([tx.get(jobRef), tx.get(driverRef)]);
    if (!jobSnap.exists) {
      dropOffer(tx);
      return { success: false, reason: "order_not_found" };
    }
    if (!driverSnap.exists) return { success: false, reason: "driver_not_found" };

    const data = jobSnap.data();
    const driver = driverSnap.data();
    if (data.status !== job.open) {
      dropOffer(tx);
      return { success: false, reason: "order_unavailable" };
    }
    if (data.driverId != null) {
      dropOffer(tx);
      return { success: false, reason: "order_already_assigned" };
    }
    // A driver never serves their own order (one account booking and
    // earning from the same job).
    if (data.passengerId === uid || data.customerId === uid) {
      return { success: false, reason: "order_unavailable", detail: "own_order" };
    }

    // A job dispatch would offer to nobody (unknown service, no location,
    // vehicle that cannot carry the load) cannot be claimed either.
    const jobProblem = jobRejection(service, data);
    if (jobProblem) return { success: false, reason: "order_unavailable", detail: jobProblem };

    const rejection = driverRejection(service, data, driver);
    if (rejection) {
      return { success: false, reason: clientReason(rejection), detail: rejection };
    }

    // A Gas order is taken only at its verified price: the verifiedPrice
    // stamped by onGasOrderCreated (gas_pricing.js), which settlement uses
    // too, never the settings as they are now. An order not yet stamped
    // (created before that trigger ran) is verified here against the
    // current price and stamped in this commit, or refused.
    // A delivery is taken only at its verified price (delivery_quotes.js);
    // the server cannot re-measure a route inside this transaction.
    if (service === "delivery" && !stampedDeliveryPrice(data)) {
      return { success: false, reason: "order_unavailable", detail: "price_not_verified" };
    }
    let gasStamp = null;
    if (service === "gas" && !stampedPrice(data)) {
      const settings = await tx.get(db.collection("settings").doc("platform"));
      const check = verifyGasOrderPrice(data, settings.exists ? settings.data() : null);
      if (!check.ok) return { success: false, reason: "order_unavailable", detail: check.reason };
      gasStamp = { ...verifiedPriceStamp(check.quote), verifiedAt: admin.firestore.FieldValue.serverTimestamp() };
    }

    // A wallet job is taken only once its payment is in place: the
    // customer's HELD hold, linked to exactly this job (attachEscrowToOrder
    // checked its price). Read in this transaction, before any write.
    if (data.paymentMethod === "wallet") {
      const escrowId = typeof data.escrowId === "string" && data.escrowId && !data.escrowId.includes("/")
        ? data.escrowId : null;
      const hold = escrowId ? await tx.get(db.collection("escrows").doc(escrowId)) : null;
      const e = hold?.exists ? hold.data() : null;
      if (!e || e.status !== "HELD" || e.userId !== data.passengerId ||
          e.referenceId !== jobId || e.referenceType !== job.referenceType) {
        return { success: false, reason: "order_unavailable", detail: "payment_not_verified" };
      }
    }

    tx.update(jobRef, {
      ...assignmentFields(service, uid, driver, job.accepted),
      ...(gasStamp ? { verifiedPrice: gasStamp } : {}),
    });
    dropOffer(tx);
    tx.update(driverRef, {
      isAvailable: false,
      currentTripId: jobId,
      currentTripType: job.collection,
    });
    return { success: true };
  });
}

/** A callable accepting one [service] job named by request.data[idField]. */
function acceptCallable(service, idField) {
  return onCall({ region: "europe-west2" }, async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "You must be signed in.");

    const jobId = request.data?.[idField];
    if (typeof jobId !== "string" || !jobId.trim() || jobId.includes("/")) {
      throw new HttpsError("invalid-argument", `${idField} is required.`);
    }

    let result;
    try {
      result = await acceptJob(service, uid, jobId);
    } catch (error) {
      console.error(`${service} ${jobId}: acceptance transaction failed`, error.message);
      throw new HttpsError("internal", "Unable to accept this request right now.");
    }
    if (!result.success) {
      console.log(`${service} ${jobId}: acceptance refused (${result.detail ?? result.reason})`);
      return result;
    }
    return { success: true, [idField]: jobId };
  });
}

/**
 * acceptTrip, the name Driver builds 1.0.0+1 of 2026-05-24..27 call with
 * { tripId }. It used to assign any searching trip to any caller with a
 * driver document (no eligibility at all). It now runs the same server
 * acceptance as acceptRide and answers in the reasons those builds map
 * ('already_accepted', 'trip_not_found'; anything else shows their generic
 * "Could not accept ride").
 */
function legacyTripReason(reason) {
  switch (reason) {
    case "order_unavailable":
    case "order_already_assigned":
      return "already_accepted";
    case "order_not_found":
      return "trip_not_found";
    default:
      return reason;
  }
}

const acceptTrip = onCall({ region: "europe-west2" }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  const tripId = request.data?.tripId;
  if (typeof tripId !== "string" || !tripId.trim() || tripId.includes("/")) {
    throw new HttpsError("invalid-argument", "tripId is required.");
  }
  let result;
  try {
    result = await acceptJob("ride", uid, tripId);
  } catch (error) {
    console.error(`ride ${tripId}: legacy acceptance transaction failed`, error.message);
    throw new HttpsError("internal", "Unable to accept this request right now.");
  }
  if (!result.success) {
    console.log(`ride ${tripId}: legacy acceptance refused (${result.detail ?? result.reason})`);
    return { success: false, reason: legacyTripReason(result.reason), detail: result.detail };
  }
  return { success: true };
});

exports.JOBS = JOBS;
exports.acceptTrip = acceptTrip;
exports._legacyTripReason = legacyTripReason;
exports.acceptJob = acceptJob;
exports.acceptCallable = acceptCallable;
exports.acceptRide = acceptCallable("ride", "tripId");
exports.acceptDelivery = acceptCallable("delivery", "deliveryId");
