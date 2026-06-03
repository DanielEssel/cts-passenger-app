const { releaseEscrow, refundEscrow } = require("./escrow");
// functions/trips.js
const { onDocumentUpdated, onDocumentCreated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

const db = () => admin.firestore();

// ── Helpers ───────────────────────────────────────────────────────────────────

async function getPlatformSettings() {
  try {
    const snap = await db().collection("settings").doc("platform").get();
    return snap.exists ? snap.data() : null;
  } catch {
    return null;
  }
}

function calculateRideFare(serviceType, distanceKm, settings) {
  const type     = serviceType?.toLowerCase() === "okada" ? "okada" : "taxi";
  const pricing  = settings?.[type] || {};

  const base     = pricing.baseFare        ?? (type === "okada" ? 3.0  : 5.0);
  const perKm    = pricing.perKmRate       ?? (type === "okada" ? 1.5  : 2.5);
  const minFare  = pricing.minimumFare     ?? (type === "okada" ? 5.0  : 10.0);
  const surge    = pricing.surgeEnabled    ? (pricing.surgeMultiplier ?? 1.0) : 1.0;

  const fare = (base + (perKm * distanceKm)) * surge;
  return Math.max(fare, minFare);
}

function calculateDeliveryFare(distanceKm, weightTier, isFragile, settings) {
  const pricing = settings?.delivery || {};

  const base    = pricing.baseFare              ?? 8.0;
  const perKm   = pricing.perKmRate             ?? 2.0;
  const minFare = pricing.minimumFare           ?? 10.0;

  const weightSurcharge = weightTier === "large"
    ? (pricing.weightSurchargeLarge  ?? 15.0)
    : weightTier === "medium"
    ? (pricing.weightSurchargeMedium ?? 5.0)
    : (pricing.weightSurchargeSmall  ?? 0.0);

  const fragile = isFragile ? (pricing.fragileItemSurcharge ?? 5.0) : 0.0;
  const fare    = base + (perKm * distanceKm) + weightSurcharge + fragile;
  return Math.max(fare, minFare);
}

function calculateGasFare(cylinderSize, quantity, settings) {
  const pricing = settings?.gas || {};
  const sizeKey = `cylinder${cylinderSize?.replace(/[^0-9]/g, "")}kg`;
  const unitPrice = pricing[sizeKey] ?? pricing.cylinder6kg ?? 96.0;
  const delivery  = pricing.deliveryFee ?? 10.0;
  return (unitPrice * quantity) + delivery;
}

const PLATFORM_FEE_PERCENT = 0.15; // 15% default

// ── onTripCreated: validate & correct fare ────────────────────────────────────
exports.onTripCreated = onDocumentCreated(
  {region: "europe-west2", document: "trips/{tripId}"},
  async (event) => {
    const data    = event.data.data();
    const tripId  = event.params.tripId;

    // Only validate if fare was set by client
    const clientFare   = data.estimatedFare ?? 0;
    const distanceKm   = data.distanceKm ?? data.distance ?? 0;
    const serviceType  = data.serviceType ?? "taxi";

    if (distanceKm <= 0) return; // Can't validate without distance

    try {
      const settings    = await getPlatformSettings();
      const serverFare  = Math.round(
        calculateRideFare(serviceType, distanceKm, settings) * 100
      ) / 100;

      const deviation = Math.abs(clientFare - serverFare) / serverFare;

      // If client fare deviates more than 20% from server calculation — correct it
      if (deviation > 0.2 && serverFare > 0) {
        await db().collection("trips").doc(tripId).update({
          estimatedFare:   serverFare,
          fareValidated:   true,
          fareValidatedAt: admin.firestore.FieldValue.serverTimestamp(),
          originalClientFare: clientFare,
        });
        console.log(`Trip ${tripId}: fare corrected ${clientFare} → ${serverFare}`);
      } else {
        await db().collection("trips").doc(tripId).update({
          fareValidated:   true,
          fareValidatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      console.error("Fare validation error:", e.message);
    }
  }
);

// ── onTripCompleted: validate + deduct wallet + credit driver ────────────────
exports.onTripCompleted = onDocumentUpdated(
  {region: "europe-west2", document: "trips/{tripId}"},
  async (event) => {
    const before  = event.data.before.data();
    const after   = event.data.after.data();
    const tripId  = event.params.tripId;

    // Only fire on completion
    if (before.status === after.status)           return;
    if (after.status  !== "completed")            return;
    if (after.walletProcessed === true)           return; // idempotency

    // ── Fraud prevention checks ──────────────────────────────────────────────
    const tripRef     = db().collection("trips").doc(tripId);
    const distanceKm  = after.actualDistanceKm ?? after.distanceKm ?? 0;
    const startedAt   = after.startedAt?.toDate?.() ?? null;
    const now         = new Date();
    const tripMinutes = startedAt
      ? (now - startedAt) / 60000
      : 999; // if no startedAt, assume ok

    // ── Wait for passenger confirmation ──────────────────────────────────────
    // If passenger has not confirmed yet — set a 3-minute auto-confirm timer
    if (!after.passengerConfirmed) {
      const completedAt = after.completedAt?.toDate?.() ?? now;
      const waitMinutes = (now - completedAt) / 60000;

      if (waitMinutes < 3) {
        // Not yet confirmed and within 3 minutes — skip, wait for passenger
        // The function will re-trigger when passengerConfirmed is set
        console.log(`Trip ${tripId}: waiting for passenger confirmation (${waitMinutes.toFixed(1)} min)`);
        return;
      }

      // 3 minutes passed with no response — auto confirm
      console.log(`Trip ${tripId}: auto-confirming after 3 minutes`);
      await tripRef.update({
        passengerConfirmed:   true,
        passengerConfirmedAt: admin.firestore.FieldValue.serverTimestamp(),
        autoConfirmed:        true,
      });
    }

    // Reject if trip was too short (less than 0.3km or less than 1 minute)
    if (distanceKm < 0.3 && tripMinutes < 1) {
      console.warn(`Trip ${tripId}: suspicious completion — distance=${distanceKm}km time=${tripMinutes}min`);
      await tripRef.update({
        status:        "flagged",
        flagReason:    "Suspicious completion — insufficient distance and time",
        flaggedAt:     admin.firestore.FieldValue.serverTimestamp(),
      });
      // Notify admin
      await db().collection("admin_alerts").add({
        type:      "suspicious_trip",
        tripId,
        driverId:  after.driverId,
        reason:    `Trip completed with only ${distanceKm.toFixed(1)}km in ${tripMinutes.toFixed(1)} minutes`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    const passengerId = after.passengerId;
    const driverId    = after.driverId;

    if (!passengerId || !driverId) {
      console.error(`Trip ${tripId}: missing passengerId or driverId`);
      return;
    }

    try {
      const settings   = await getPlatformSettings();
      const feePercent = (settings?.platformFeePercent ?? 15) / 100;

      // Calculate final fare server-side
      const distanceKm  = after.actualDistanceKm ?? after.distanceKm ?? 0;
      const serviceType = after.serviceType ?? "taxi";

      let actualFare = after.actualFare ?? after.estimatedFare ?? 0;

      // Recalculate if we have distance data
      if (distanceKm > 0) {
        actualFare = Math.round(
          calculateRideFare(serviceType, distanceKm, settings) * 100
        ) / 100;
      }

      const platformFee    = Math.round(actualFare * feePercent * 100) / 100;
      const driverEarnings = Math.round((actualFare - platformFee) * 100) / 100;

      // Use escrow system for atomic wallet deduction + driver credit
      const escrowId = after.escrowId;

      if (escrowId) {
        // Release escrow — handles wallet deduction, driver credit, ledger
        await releaseEscrow(escrowId, driverId, "trip_completed");
      } else {
        // Fallback: no escrow (legacy trip) — do direct deduction
        console.warn(`Trip ${tripId}: no escrowId — using direct wallet deduction`);
        const walletRef = db().collection("wallets").doc(passengerId);
        await db().runTransaction(async (tx) => {
          const walletDoc = await tx.get(walletRef);
          const balance   = walletDoc.exists ? (walletDoc.data()?.balance ?? 0) : 0;
          if (balance >= actualFare) {
            tx.update(walletRef, {
              balance:       admin.firestore.FieldValue.increment(-actualFare),
              lastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          }
          const driverRef = db().collection("drivers").doc(driverId);
          tx.update(driverRef, {
            totalEarnings:  admin.firestore.FieldValue.increment(driverEarnings),
            todayEarnings:  admin.firestore.FieldValue.increment(driverEarnings),
            completedTrips: admin.firestore.FieldValue.increment(1),
            isAvailable:    true,
            currentTripId:  admin.firestore.FieldValue.delete(),
          });
          const tripRef = db().collection("trips").doc(tripId);
          tx.update(tripRef, {
            actualFare, platformFee, driverEarnings,
            walletProcessed: true,
            completedAt:     admin.firestore.FieldValue.serverTimestamp(),
          });
        });
      }

      // Mark trip as wallet processed
      await db().collection("trips").doc(tripId).update({
        actualFare, platformFee, driverEarnings,
        walletProcessed: true,
        completedAt:     admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(`✅ Trip ${tripId} completed via ${escrowId ? 'escrow' : 'direct'}: fare=${actualFare} driver=${driverEarnings} fee=${platformFee}`)

    } catch (e) {
      console.error(`Trip ${tripId} completion error:`, e.message);
      // Mark for retry
      await db().collection("trips").doc(tripId).update({
        walletProcessError: e.message,
        walletProcessedAt:  admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
);

// ── onDeliveryCompleted: validate OTP + deduct wallet + credit driver ───────
exports.onDeliveryCompleted = onDocumentUpdated(
  {region: "europe-west2", document: "deliveries/{deliveryId}"},
  async (event) => {
    const before     = event.data.before.data();
    const after      = event.data.after.data();
    const deliveryId = event.params.deliveryId;

    if (before.status === after.status) return;
    if (after.status  !== "completed")  return;
    if (after.walletProcessed === true) return;

    // ── OTP validation ────────────────────────────────────────────────────
    const storedOtp   = after.deliveryOtp;
    const submittedOtp = after.otpSubmitted;

    if (storedOtp && !submittedOtp) {
      console.warn(`Delivery ${deliveryId}: completed without OTP submission`);
      await db().collection("deliveries").doc(deliveryId).update({
        status:      "pendingOtp",
        flagReason:  "Completed without OTP verification",
        flaggedAt:   admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    if (storedOtp && submittedOtp && storedOtp !== submittedOtp) {
      console.error(`Delivery ${deliveryId}: OTP mismatch`);
      await db().collection("deliveries").doc(deliveryId).update({
        status:     "flagged",
        flagReason: "OTP mismatch — possible fraud",
        flaggedAt:  admin.firestore.FieldValue.serverTimestamp(),
      });
      await db().collection("admin_alerts").add({
        type:       "otp_mismatch",
        deliveryId,
        driverId:   after.driverId,
        reason:     "Driver submitted wrong OTP for delivery",
        createdAt:  admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    const passengerId = after.passengerId;
    const driverId    = after.driverId;
    if (!passengerId || !driverId) return;

    try {
      const settings     = await getPlatformSettings();
      const feePercent   = (settings?.platformFeePercent ?? 15) / 100;

      const distanceKm   = after.distanceKm    ?? 0;
      const weightTier   = after.weightTier     ?? "small";
      const isFragile    = after.isFragile      ?? false;

      let actualFare = after.actualFare ?? after.estimatedFare ?? 0;
      if (distanceKm > 0) {
        actualFare = Math.round(
          calculateDeliveryFare(distanceKm, weightTier, isFragile, settings) * 100
        ) / 100;
      }

      const platformFee    = Math.round(actualFare * feePercent * 100) / 100;
      const driverEarnings = Math.round((actualFare - platformFee) * 100) / 100;

      await db().runTransaction(async (tx) => {
        const walletRef = db().collection("wallets").doc(passengerId);
        const driverRef = db().collection("drivers").doc(driverId);
        const delivRef  = db().collection("deliveries").doc(deliveryId);

        const [walletDoc] = await Promise.all([tx.get(walletRef)]);
        const balance = walletDoc.exists ? (walletDoc.data()?.balance ?? 0) : 0;

        if (balance >= actualFare) {
          tx.update(walletRef, {
            balance:   admin.firestore.FieldValue.increment(-actualFare),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }

        tx.update(driverRef, {
          totalEarnings:  admin.firestore.FieldValue.increment(driverEarnings),
          todayEarnings:  admin.firestore.FieldValue.increment(driverEarnings),
          completedTrips: admin.firestore.FieldValue.increment(1),
          isAvailable:    true,
          currentTripId:  admin.firestore.FieldValue.delete(),
        });

        tx.update(delivRef, {
          actualFare:      actualFare,
          platformFee:     platformFee,
          driverEarnings:  driverEarnings,
          walletProcessed: true,
          completedAt:     admin.firestore.FieldValue.serverTimestamp(),
        });
      });

      console.log(`✅ Delivery ${deliveryId} completed: fare=${actualFare}`);
    } catch (e) {
      console.error(`Delivery ${deliveryId} completion error:`, e.message);
    }
  }
);

// ── onGasOrderCompleted: validate OTP + deduct wallet + credit driver ───────
exports.onGasOrderCompleted = onDocumentUpdated(
  {region: "europe-west2", document: "gas_orders/{orderId}"},
  async (event) => {
    const before  = event.data.before.data();
    const after   = event.data.after.data();
    const orderId = event.params.orderId;

    if (before.status === after.status) return;
    if (after.status  !== "delivered")  return;
    if (after.walletProcessed === true) return;

    // ── OTP validation ────────────────────────────────────────────────────
    const storedOtp    = after.deliveryOtp;
    const submittedOtp = after.otpSubmitted;

    if (storedOtp && !submittedOtp) {
      console.warn(`Gas order ${orderId}: delivered without OTP submission`);
      await db().collection("gas_orders").doc(orderId).update({
        status:     "pendingOtp",
        flagReason: "Delivered without OTP verification",
        flaggedAt:  admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    if (storedOtp && submittedOtp && storedOtp !== submittedOtp) {
      console.error(`Gas order ${orderId}: OTP mismatch`);
      await db().collection("gas_orders").doc(orderId).update({
        status:     "flagged",
        flagReason: "OTP mismatch — possible fraud",
        flaggedAt:  admin.firestore.FieldValue.serverTimestamp(),
      });
      await db().collection("admin_alerts").add({
        type:      "otp_mismatch",
        orderId,
        driverId:  after.driverId,
        reason:    "Driver submitted wrong OTP for gas delivery",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    const passengerId  = after.passengerId;
    const driverId     = after.driverId;
    if (!passengerId)  return;

    try {
      const settings     = await getPlatformSettings();
      const feePercent   = (settings?.platformFeePercent ?? 15) / 100;

      const cylinderSize = after.cylinderSize ?? "6kg";
      const quantity     = after.quantity     ?? 1;

      let actualFare = after.totalPrice ?? after.estimatedFare ?? 0;
      if (actualFare <= 0) {
        actualFare = Math.round(
          calculateGasFare(cylinderSize, quantity, settings) * 100
        ) / 100;
      }

      const platformFee    = Math.round(actualFare * feePercent * 100) / 100;
      const driverEarnings = driverId
        ? Math.round((actualFare - platformFee) * 100) / 100
        : 0;

      await db().runTransaction(async (tx) => {
        const walletRef  = db().collection("wallets").doc(passengerId);
        const gasRef     = db().collection("gas_orders").doc(orderId);

        const walletDoc  = await tx.get(walletRef);
        const balance    = walletDoc.exists ? (walletDoc.data()?.balance ?? 0) : 0;

        if (balance >= actualFare) {
          tx.update(walletRef, {
            balance:   admin.firestore.FieldValue.increment(-actualFare),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }

        if (driverId) {
          const driverRef = db().collection("drivers").doc(driverId);
          tx.update(driverRef, {
            totalEarnings:  admin.firestore.FieldValue.increment(driverEarnings),
            todayEarnings:  admin.firestore.FieldValue.increment(driverEarnings),
            completedTrips: admin.firestore.FieldValue.increment(1),
            isAvailable:    true,
            currentTripId:  admin.firestore.FieldValue.delete(),
          });
        }

        tx.update(gasRef, {
          totalPrice:      actualFare,
          platformFee:     platformFee,
          driverEarnings:  driverEarnings,
          walletProcessed: true,
          completedAt:     admin.firestore.FieldValue.serverTimestamp(),
        });
      });

      // Log passenger transaction
      await db().collection("transactions").add({
        userId:        passengerId,
        type:          "debit",
        amount:        actualFare,
        currency:      "GHS",
        description:   `Gas order — ${cylinderSize} × ${quantity}`,
        referenceId:   orderId,
        referenceType: "gas_order",
        status:        "completed",
        createdAt:     admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(`✅ Gas order ${orderId} completed: fare=${actualFare}`);
    } catch (e) {
      console.error(`Gas order ${orderId} completion error:`, e.message);
    }
  }
);

// ── autoConfirmTrips: runs every minute to process unconfirmed completions ────
const { onSchedule } = require("firebase-functions/v2/scheduler");

exports.autoConfirmTrips = onSchedule(
  { schedule: "every 1 minutes", region: "europe-west2", minInstances: 0 },
  async () => {
    const threeMinAgo = new Date(Date.now() - 3 * 60 * 1000);

    // Find completed trips where passenger hasn't confirmed in 3+ minutes
    const snap = await db().collection("trips")
      .where("status",            "==",  "completed")
      .where("walletProcessed",   "==",  false)
      .where("passengerConfirmed","==",  false)
      .where("disputed",          "==",  false)
      .get();

    const promises = [];
    for (const doc of snap.docs) {
      const data        = doc.data();
      const completedAt = data.completedAt?.toDate?.();
      if (!completedAt || completedAt > threeMinAgo) continue;

      // Auto-confirm
      promises.push(
        doc.ref.update({
          passengerConfirmed:   true,
          passengerConfirmedAt: admin.firestore.FieldValue.serverTimestamp(),
          autoConfirmed:        true,
        })
      );
    }

    await Promise.allSettled(promises);
    console.log(`autoConfirmTrips: processed ${promises.length} trips`);
  }
);

// ── onTripCancelled: refund escrow ───────────────────────────────────────────
exports.onTripCancelled = onDocumentUpdated(
  {region: "europe-west2", document: "trips/{tripId}"},
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();
    const tripId = event.params.tripId;

    if (before.status === after.status) return;

    const cancelledStatuses = ["cancelled", "cancelledByDriver", "cancelledByPassenger", "noDrivers"];
    if (!cancelledStatuses.includes(after.status)) return;
    if (after.escrowRefunded === true) return; // idempotency

    const escrowId = after.escrowId;
    if (!escrowId) {
      console.log(`Trip ${tripId}: no escrowId — nothing to refund`);
      return;
    }

    try {
      const reason = after.status === "cancelledByDriver"
        ? "driver_cancelled"
        : after.status === "noDrivers"
        ? "no_drivers_found"
        : "passenger_cancelled";

      await refundEscrow(escrowId, reason);

      await db().collection("trips").doc(tripId).update({
        escrowRefunded:   true,
        escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(`✅ Escrow ${escrowId} refunded for cancelled trip ${tripId}`);

      // Notify passenger
      const passengerId = after.passengerId;
      if (passengerId) {
        const userDoc  = await db().collection("users").doc(passengerId).get();
        const fcmToken = userDoc.data()?.fcmToken;
        if (fcmToken) {
          await admin.messaging().send({
            token: fcmToken,
            notification: {
              title: "Trip Cancelled — Refund Processed",
              body:  `Your GH₵${(after.estimatedFare || 0).toFixed(2)} has been returned to your wallet.`,
            },
            data: { type: "trip_cancelled", route: "/wallet" },
          }).catch(console.error);
        }
      }
    } catch (e) {
      console.error(`Failed to refund escrow for trip ${tripId}:`, e.message);
      await db().collection("admin_alerts").add({
        type:      "escrow_refund_failed",
        tripId,
        escrowId,
        error:     e.message,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
);

// ── onDeliveryCancelled: refund escrow ────────────────────────────────────────
exports.onDeliveryCancelled = onDocumentUpdated(
  {region: "europe-west2", document: "deliveries/{deliveryId}"},
  async (event) => {
    const before     = event.data.before.data();
    const after      = event.data.after.data();
    const deliveryId = event.params.deliveryId;

    if (before.status === after.status) return;
    if (after.status  !== "cancelled")  return;
    if (after.escrowRefunded === true)  return;

    const escrowId = after.escrowId;
    if (!escrowId) return;

    try {
      await refundEscrow(escrowId, "delivery_cancelled");
      await db().collection("deliveries").doc(deliveryId).update({
        escrowRefunded:   true,
        escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log(`✅ Escrow refunded for cancelled delivery ${deliveryId}`);
    } catch (e) {
      console.error(`Escrow refund failed for delivery ${deliveryId}:`, e.message);
    }
  }
);

// ── onGasOrderCancelled: refund escrow ───────────────────────────────────────
exports.onGasOrderCancelled = onDocumentUpdated(
  {region: "europe-west2", document: "gas_orders/{orderId}"},
  async (event) => {
    const before  = event.data.before.data();
    const after   = event.data.after.data();
    const orderId = event.params.orderId;

    if (before.status === after.status) return;
    if (after.status  !== "cancelled")  return;
    if (after.escrowRefunded === true)  return;

    const escrowId = after.escrowId;
    if (!escrowId) return;

    try {
      await refundEscrow(escrowId, "gas_order_cancelled");
      await db().collection("gas_orders").doc(orderId).update({
        escrowRefunded:   true,
        escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log(`✅ Escrow refunded for cancelled gas order ${orderId}`);
    } catch (e) {
      console.error(`Escrow refund failed for gas order ${orderId}:`, e.message);
    }
  }
);
