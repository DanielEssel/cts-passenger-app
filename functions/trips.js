const { releaseEscrow, refundEscrow } = require("./escrow");
// functions/trips.js
const {
  onDocumentUpdated,
  onDocumentCreated,
} = require("firebase-functions/v2/firestore");
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

// ════════════════════════════════════════════════════════════════════════════
// PRODUCTION FARE CALCULATORS — single source of truth
// Match the admin panel schema (settings/platform) field-for-field.
//
// Replace the existing calculateRideFare / calculateDeliveryFare /
// calculateGasFare in functions/trips.js with these.
//
// Schema (settings/platform):
//   okada/taxi: { baseFare, perKmRate, perMinRate, minimumFare,
//                 cancellationFee, surgeMultiplier, surgeEnabled }
//   delivery:   { baseFare, perKmRate, minimumFare,
//                 weightSurchargeSmall, weightSurchargeMedium, weightSurchargeLarge,
//                 fragileItemSurcharge, cancellationFee }
//   gas:        { cylinder3kg, cylinder6kg, cylinder12kg, cylinder14kg,
//                 deliveryFee, minimumOrder }
// ════════════════════════════════════════════════════════════════════════════

const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

// ── RIDE (okada / taxi) ──────────────────────────────────────────────────────
// fare = (baseFare + perKmRate*km + perMinRate*min), floored at minimumFare,
//        then × surgeMultiplier if surge enabled. Surge applies AFTER the floor
//        so a surged minimum is still surged (matches rider expectation).
function calculateRideFare(serviceType, distanceKm, durationMin, settings) {
  const type = serviceType?.toLowerCase() === "okada" ? "okada" : "taxi";
  const p = settings?.[type] || {};

  const base = p.baseFare ?? (type === "okada" ? 3.0 : 5.0);
  const perKm = p.perKmRate ?? (type === "okada" ? 1.5 : 2.5);
  const perMin = p.perMinRate ?? (type === "okada" ? 0.2 : 0.3);
  const minFare = p.minimumFare ?? (type === "okada" ? 5.0 : 10.0);

  const km = Math.max(0, Number(distanceKm) || 0);
  const min = Math.max(0, Number(durationMin) || 0);

  // Match the client PricingService ordering exactly: apply surge to the whole
  // fare first, THEN floor at the minimum. (Client: (base+perKm·km+perMin·min)*surge,
  // then max with minFare.) Keeping the order identical guarantees client display
  // == server hold == completion calc.
  const surgeOn = !!p.surgeEnabled;
  const surgeMul = p.surgeMultiplier ?? p.surgeMutiplier ?? 1.0;
  const surge = surgeOn && surgeMul > 1 ? surgeMul : 1.0;

  let fare = (base + perKm * km) * surge;   // distance-only; perMin reserved for future
  fare = Math.max(fare, minFare);

  return round2(fare);
}

// ── DELIVERY ─────────────────────────────────────────────────────────────────
function calculateDeliveryFare(distanceKm, weightTier, isFragile, settings, vehicleType, requiresHelpers) {
  const d = settings?.delivery || {};
 
  // Normalise vehicle key: "Mini Truck" -> "minitruck", "Okada" -> "okada"
  const vkeyRaw = String(vehicleType || "okada").toLowerCase().replace(/[^a-z]/g, "");
  const vkey =
    vkeyRaw.includes("mini") || vkeyRaw.includes("truck") ? "miniTruck" :
    vkeyRaw.includes("aboboya")                            ? "aboboya"  :
                                                             "okada";
 
  // Default per-vehicle rates (seeded from prior hardcoded client values).
  const VEH_DEFAULTS = {
    okada:     { baseFare: 5.0,  perKmRate: 2.5, minimumFare: 10.0 },
    aboboya:   { baseFare: 15.0, perKmRate: 4.0, minimumFare: 20.0 },
    miniTruck: { baseFare: 40.0, perKmRate: 7.0, minimumFare: 50.0 },
  };
 
  const veh = d[vkey] || {};
  const def = VEH_DEFAULTS[vkey];
 
  // Per-vehicle block first, then legacy flat delivery.*, then hard default.
  const base    = veh.baseFare    ?? d.baseFare    ?? def.baseFare;
  const perKm   = veh.perKmRate   ?? d.perKmRate   ?? def.perKmRate;
  const minFare = veh.minimumFare ?? d.minimumFare ?? def.minimumFare;
 
  const tier = String(weightTier || "small").toLowerCase();
  const weightSurcharge =
    tier === "large"  ? (d.weightSurchargeLarge  ?? 15.0) :
    tier === "medium" ? (d.weightSurchargeMedium ??  5.0) :
                        (d.weightSurchargeSmall  ??  0.0);
 
  const fragile = isFragile      ? (d.fragileItemSurcharge ?? 5.0)  : 0.0;
  const helpers = requiresHelpers ? (d.helperSurcharge      ?? 10.0) : 0.0;
  const km = Math.max(0, Number(distanceKm) || 0);
 
  let fare = base + perKm * km + weightSurcharge + fragile + helpers;
  fare = Math.max(fare, minFare);
  return round2(fare);
}

// ── GAS ──────────────────────────────────────────────────────────────────────
// fare = cylinderPrice[size] * quantity + deliveryFee.
// Size key normalises "6kg"/"6 kg"/"6" → cylinder6kg.
function calculateGasFare(cylinderSize, quantity, settings) {
  const p = settings?.gas || {};
  const digits = String(cylinderSize ?? "6").replace(/[^0-9]/g, "") || "6";
  const sizeKey = `cylinder${digits}kg`;

  const unitPrice = p[sizeKey] ?? p.cylinder6kg ?? 55.0; // sane default matching panel's 6kg default

  const deliveryFee = p.deliveryFee ?? 10.0;
  const qty = Math.max(1, Number(quantity) || 1);

  return round2(unitPrice * qty + deliveryFee);
}

const PLATFORM_FEE_PERCENT = 0.15; // 15% default

// ── onTripCreated: validate & correct fare ────────────────────────────────────
exports.onTripCreated = onDocumentCreated(
  { region: "europe-west2", document: "trips/{tripId}" },
  async (event) => {
    const data = event.data.data();
    const tripId = event.params.tripId;

    // Only validate if fare was set by client
    const clientFare = data.estimatedFare ?? 0;
    const distanceKm = data.distanceKm ?? data.distance ?? 0;
    const serviceType = data.serviceType ?? "taxi";

    if (distanceKm <= 0) return; // Can't validate without distance

    try {
      const settings = await getPlatformSettings();
      const serverFare =
        Math.round(
          calculateRideFare(
            serviceType,
            distanceKm,
            data.estimatedDuration ?? 0,
            settings,
          ) * 100,
        ) / 100;
      

      const deviation = Math.abs(clientFare - serverFare) / serverFare;

      // If client fare deviates more than 20% from server calculation — correct it
      if (deviation > 0.2 && serverFare > 0) {
        await db().collection("trips").doc(tripId).update({
          estimatedFare: serverFare,
          fareValidated: true,
          fareValidatedAt: admin.firestore.FieldValue.serverTimestamp(),
          originalClientFare: clientFare,
        });
        console.log(
          `Trip ${tripId}: fare corrected ${clientFare} → ${serverFare}`,
        );
      } else {
        await db().collection("trips").doc(tripId).update({
          fareValidated: true,
          fareValidatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      console.error("Fare validation error:", e.message);
    }
  },
);

// REPLACE the existing exports.onTripCompleted in functions/trips.js with this.

// REPLACE the existing exports.onTripCompleted in functions/trips.js with this.
//
// Fixes:
//   1. CASH trips no longer debit the passenger wallet (was double-charging:
//      driver collected cash AND wallet was deducted).
//   2. CASH commission tracked as driver debt (commissionOwed + COMMISSION_DEBT
//      ledger entry) so the platform's 15% is accounted for.
//   3. Removed the duplicate unconditional walletProcessed write that ran even
//      after the escrow branch already handled everything.
//   4. Single, idempotent walletProcessed write after the branch.
//
// Requires (already present): const { releaseEscrow } = require("./escrow");

exports.onTripCompleted = onDocumentUpdated(
  { region: "europe-west2", document: "trips/{tripId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const tripId = event.params.tripId;

    // Act on completed, unprocessed trips. Do NOT gate on which field changed:
    // the payout should run whenever the trip is completed and either already
    // confirmed or past the auto-confirm window. Gating on specific field
    // changes (status / passengerConfirmed) silently dropped re-trigger and
    // confirmation events and stalled payouts.
    if (after.status !== "completed") return;
    if (after.walletProcessed === true) return; // idempotency

    const tripRef = db().collection("trips").doc(tripId);
    const distanceKm = after.actualDistanceKm ?? after.distanceKm ?? 0;
    const startedAt = after.startedAt?.toDate?.() ?? null;
    const now = new Date();
    const tripMinutes = startedAt ? (now - startedAt) / 60000 : 999;

    // ── Wait for passenger confirmation (auto-confirm after 3 min) ───────────
    if (!after.passengerConfirmed) {
      const completedAt = after.completedAt?.toDate?.() ?? now;
      const waitMinutes = (now - completedAt) / 60000;
      if (waitMinutes < 3) {
        console.log(
          `Trip ${tripId}: waiting for passenger confirmation (${waitMinutes.toFixed(1)} min)`,
        );
        return; // re-triggers when passengerConfirmed flips (app or autoConfirmTrips)
      }
      console.log(`Trip ${tripId}: auto-confirming after 3 minutes`);
      await tripRef.update({
        passengerConfirmed: true,
        passengerConfirmedAt: admin.firestore.FieldValue.serverTimestamp(),
        autoConfirmed: true,
      });
    }

    // ── Fraud check: implausibly short trip ──────────────────────────────────
    // NOTE: skipped while testing — test trips have distanceKm=0 (no real
    // driving) and complete in <1 min, which would always trip this guard.
    // Flip TEST_MODE to false for production to re-enable fraud flagging.
    const TEST_MODE = true;
    if (!TEST_MODE && distanceKm < 0.3 && tripMinutes < 1) {
      console.warn(
        `Trip ${tripId}: suspicious completion — distance=${distanceKm}km time=${tripMinutes}min`,
      );
      await tripRef.update({
        status: "flagged",
        flagReason: "Suspicious completion — insufficient distance and time",
        flaggedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      await db()
        .collection("admin_alerts")
        .add({
          type: "suspicious_trip",
          tripId,
          driverId: after.driverId,
          reason: `Trip completed with only ${distanceKm.toFixed(1)}km in ${tripMinutes.toFixed(1)} minutes`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      return;
    }

    const passengerId = after.passengerId;
    const driverId = after.driverId;
    if (!passengerId || !driverId) {
      console.error(`Trip ${tripId}: missing passengerId or driverId`);
      return;
    }

    try {
      const settings = await getPlatformSettings();
      const feePercent = (settings?.platformFeePercent ?? 15) / 100;
      const serviceType = after.serviceType ?? "taxi";
      const paymentMethod = after.paymentMethod ?? "wallet";

      // Server-authoritative fare
      let actualFare = after.actualFare ?? after.estimatedFare ?? 0;
      if (distanceKm > 0) {
        actualFare =
          Math.round(
            calculateRideFare(
              serviceType,
              distanceKm,
              after.actualDuration ?? after.estimatedDuration ?? 0,
              settings,
            ) * 100,
          ) / 100;
      }
      let platformFee = Math.round(actualFare * feePercent * 100) / 100;
      let driverEarnings = Math.round((actualFare - platformFee) * 100) / 100;

      const escrowId = after.escrowId;

      if (escrowId) {
        // ── WALLET via escrow — the canonical path ──────────────────────────
        // releaseEscrow credits the driver the escrow's driverNet, clears the
        // passenger heldBalance, marks escrow RELEASED, writes CAPTURE ledger.
        // Idempotent. The escrow doc is the source of truth for the amount that
        // actually moved, so record ITS split on the trip (not a recalc), or the
        // trip record will disagree with what the driver was paid.
        const escrowSnap = await db().collection("escrows").doc(escrowId).get();
        if (escrowSnap.exists) {
          const e = escrowSnap.data();
          if (typeof e.platformFee === "number") platformFee = e.platformFee;
          if (typeof e.driverNet === "number") driverEarnings = e.driverNet;
        }
        await releaseEscrow(escrowId, driverId, "trip_completed");
      } else if (paymentMethod === "cash") {
        // ── CASH — driver collected the full fare physically ────────────────
        // Credit driver the FULL fare; record the 15% they now owe the platform.
        // NEVER touch the passenger wallet.
        const commissionDebt = platformFee;
        await db().runTransaction(async (tx) => {
          const driverRef = db().collection("drivers").doc(driverId);
          const summaryRef = driverRef.collection("earnings").doc("summary");

          tx.update(driverRef, {
            totalEarnings: admin.firestore.FieldValue.increment(actualFare),
            todayEarnings: admin.firestore.FieldValue.increment(actualFare),
            commissionOwed:
              admin.firestore.FieldValue.increment(commissionDebt),
            completedTrips: admin.firestore.FieldValue.increment(1),
            isAvailable: true,
            currentTripId: admin.firestore.FieldValue.delete(),
          });
          tx.set(
            summaryRef,
            {
              todayEarnings: admin.firestore.FieldValue.increment(actualFare),
              weekEarnings: admin.firestore.FieldValue.increment(actualFare),
              lifetimeEarnings:
                admin.firestore.FieldValue.increment(actualFare),
              commissionOwed:
                admin.firestore.FieldValue.increment(commissionDebt),
              lastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
          );

          const ledgerRef = db().collection("ledger").doc();
          tx.set(ledgerRef, {
            type: "COMMISSION_DEBT",
            status: "OWED",
            fromUserId: driverId,
            fromType: "driver",
            toType: "platform",
            amount: commissionDebt,
            currency: "GHS",
            grossFare: actualFare,
            platformFee: commissionDebt,
            driverNet: actualFare,
            referenceType: "trip",
            referenceId: tripId,
            paymentMethod: "cash",
            idempotencyKey: `commission_${tripId}`,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        });
      } else {
        // ── WALLET but no escrowId (legacy/safety) — guarded single deduction ─
        console.warn(
          `Trip ${tripId}: wallet payment without escrowId — direct deduction`,
        );
        await db().runTransaction(async (tx) => {
          const walletRef = db().collection("wallets").doc(passengerId);
          const driverRef = db().collection("drivers").doc(driverId);
          const wdoc = await tx.get(walletRef);
          const balance = wdoc.exists ? (wdoc.data()?.balance ?? 0) : 0;
          if (balance >= actualFare) {
            tx.update(walletRef, {
              balance: admin.firestore.FieldValue.increment(-actualFare),
              lastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          } else {
            console.error(
              `Trip ${tripId}: insufficient wallet balance for direct deduction`,
            );
          }
          tx.update(driverRef, {
            totalEarnings: admin.firestore.FieldValue.increment(driverEarnings),
            todayEarnings: admin.firestore.FieldValue.increment(driverEarnings),
            completedTrips: admin.firestore.FieldValue.increment(1),
            isAvailable: true,
            currentTripId: admin.firestore.FieldValue.delete(),
          });
        });
      }

      // ── Mark processed ONCE, all paths ───────────────────────────────────
      await tripRef.update({
        actualFare,
        platformFee,
        driverEarnings,
        walletProcessed: true,
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(
        `✅ Trip ${tripId} completed via ${escrowId ? "escrow" : paymentMethod}: fare=${actualFare} driver=${driverEarnings} fee=${platformFee}`,
      );
    } catch (e) {
      console.error(`Trip ${tripId} completion error:`, e.message);
      await tripRef.update({
        walletProcessError: e.message,
        walletProcessedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  },
);

// REPLACE the existing exports.onDeliveryCompleted in functions/trips.js with this.
//
// Fixes the double-charge: deliveries HOLD escrow at booking (delivery_vehicle_screen
// calls holdBalance + writes escrowId), but the old completion handler did a SECOND
// direct `balance -= fare` deduction and never released the escrow. Wallet deliveries
// were charged twice and the escrow sat stuck until releaseStuckEscrows refunded it.
//
// Now mirrors onTripCompleted: escrow → releaseEscrow; cash → commission debt;
// legacy wallet (no escrow) → guarded single deduction. Records the escrow's actual
// split on the delivery doc. OTP validation is kept as delivery's completion gate
// (no separate passenger-confirm step — a valid OTP means the parcel was delivered).
//
// Requires (already present at top of trips.js): const { releaseEscrow } = require("./escrow");

exports.onDeliveryCompleted = onDocumentUpdated(
  { region: "europe-west2", document: "deliveries/{deliveryId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const deliveryId = event.params.deliveryId;

    if (after.status !== "completed") return;
    if (after.walletProcessed === true) return; // idempotency

    // ── OTP validation (delivery's completion gate) ─────────────────────────
    const storedOtp = after.deliveryOtp;
    const submittedOtp = after.otpSubmitted;

    if (storedOtp && !submittedOtp) {
      console.warn(`Delivery ${deliveryId}: completed without OTP submission`);
      await db().collection("deliveries").doc(deliveryId).update({
        status: "pendingOtp",
        flagReason: "Completed without OTP verification",
        flaggedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    if (storedOtp && submittedOtp && storedOtp !== submittedOtp) {
      console.error(`Delivery ${deliveryId}: OTP mismatch`);
      await db().collection("deliveries").doc(deliveryId).update({
        status: "flagged",
        flagReason: "OTP mismatch — possible fraud",
        flaggedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      await db().collection("admin_alerts").add({
        type: "otp_mismatch",
        deliveryId,
        driverId: after.driverId,
        reason: "Driver submitted wrong OTP for delivery",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    const passengerId = after.passengerId;
    const driverId = after.driverId;
    if (!passengerId || !driverId) {
      console.error(`Delivery ${deliveryId}: missing passengerId or driverId`);
      return;
    }

    try {
      const settings = await getPlatformSettings();
      const feePercent = (settings?.platformFeePercent ?? 15) / 100;

      const distanceKm = after.distanceKm ?? 0;
      const weightTier = after.weightTier ?? "small";
      const isFragile = after.isFragile ?? false;

      let actualFare = after.actualFare ?? after.estimatedFare ?? 0;
      if (distanceKm > 0) {
        actualFare =
          Math.round(
            calculateDeliveryFare(distanceKm, weightTier, isFragile, settings, after.vehicleType, after.requiresHelpers) * 100
          ) / 100;
      }

      let platformFee = Math.round(actualFare * feePercent * 100) / 100;
      let driverEarnings = Math.round((actualFare - platformFee) * 100) / 100;

      const escrowId = after.escrowId;
      const paymentMethod = after.paymentMethod ?? "wallet";

      if (escrowId) {
        // ── WALLET via escrow — the canonical path ──────────────────────────
        // Record the escrow's actual split (what was really held), then release.
        const eSnap = await db().collection("escrows").doc(escrowId).get();
        if (eSnap.exists) {
          const e = eSnap.data();
          if (typeof e.platformFee === "number") platformFee = e.platformFee;
          if (typeof e.driverNet === "number") driverEarnings = e.driverNet;
        }
        await releaseEscrow(escrowId, driverId, "delivery_completed");
      } else if (paymentMethod === "cash") {
        // ── CASH — driver collected the fare physically ─────────────────────
        // Credit driver full fare; record the commission they owe. Never touch wallet.
        const commissionDebt = platformFee;
        await db().runTransaction(async (tx) => {
          const driverRef = db().collection("drivers").doc(driverId);
          const summaryRef = driverRef.collection("earnings").doc("summary");

          tx.update(driverRef, {
            totalEarnings: admin.firestore.FieldValue.increment(actualFare),
            todayEarnings: admin.firestore.FieldValue.increment(actualFare),
            walletBalance: admin.firestore.FieldValue.increment(actualFare),
            commissionOwed:
              admin.firestore.FieldValue.increment(commissionDebt),
            totalDeliveries: admin.firestore.FieldValue.increment(1),
            isAvailable: true,
            currentTripId: admin.firestore.FieldValue.delete(),
          });
          tx.set(
            summaryRef,
            {
              todayEarnings: admin.firestore.FieldValue.increment(actualFare),
              weekEarnings: admin.firestore.FieldValue.increment(actualFare),
              lifetimeEarnings:
                admin.firestore.FieldValue.increment(actualFare),
              commissionOwed:
                admin.firestore.FieldValue.increment(commissionDebt),
              lastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
          );

          const ledgerRef = db().collection("ledger").doc();
          tx.set(ledgerRef, {
            type: "COMMISSION_DEBT",
            status: "OWED",
            fromUserId: driverId,
            fromType: "driver",
            toType: "platform",
            amount: commissionDebt,
            currency: "GHS",
            grossFare: actualFare,
            platformFee: commissionDebt,
            driverNet: actualFare,
            referenceType: "delivery",
            referenceId: deliveryId,
            paymentMethod: "cash",
            idempotencyKey: `commission_${deliveryId}`,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        });
      } else {
        // ── WALLET but no escrowId (legacy/safety) — guarded single deduction ─
        console.warn(
          `Delivery ${deliveryId}: wallet payment without escrowId — direct deduction`,
        );
        await db().runTransaction(async (tx) => {
          const walletRef = db().collection("wallets").doc(passengerId);
          const driverRef = db().collection("drivers").doc(driverId);
          const wdoc = await tx.get(walletRef);
          const balance = wdoc.exists ? (wdoc.data()?.balance ?? 0) : 0;
          if (balance >= actualFare) {
            tx.update(walletRef, {
              balance: admin.firestore.FieldValue.increment(-actualFare),
              lastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          } else {
            console.error(
              `Delivery ${deliveryId}: insufficient wallet balance for direct deduction`,
            );
          }
          tx.update(driverRef, {
            totalEarnings: admin.firestore.FieldValue.increment(driverEarnings),
            todayEarnings: admin.firestore.FieldValue.increment(driverEarnings),
            walletBalance: admin.firestore.FieldValue.increment(driverEarnings),
            totalDeliveries: admin.firestore.FieldValue.increment(1),
            isAvailable: true,
            currentTripId: admin.firestore.FieldValue.delete(),
          });
        });
      }

      // ── Mark processed ONCE, all paths ───────────────────────────────────
      await db().collection("deliveries").doc(deliveryId).update({
        actualFare,
        platformFee,
        driverEarnings,
        walletProcessed: true,
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(
        `✅ Delivery ${deliveryId} completed via ${escrowId ? "escrow" : paymentMethod}: fare=${actualFare} driver=${driverEarnings} fee=${platformFee}`,
      );
    } catch (e) {
      console.error(`Delivery ${deliveryId} completion error:`, e.message);
      await db().collection("deliveries").doc(deliveryId).update({
        walletProcessError: e.message,
        walletProcessedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  },
);

// REPLACE the existing exports.onGasOrderCompleted in functions/trips.js with this.
//
// Same fix as onDeliveryCompleted: gas orders HOLD escrow at booking
// (gas_order_screen calls holdBalance + writes escrowId), but the old handler did a
// SECOND direct wallet deduction and never released the escrow → double-charge.
// Now: escrow → releaseEscrow; cash → commission debt; legacy wallet → guarded.
// Terminal status for gas is "delivered" (not "completed"). OTP is the gate.
//
// NOTE: confirm the fare field. Gas likely uses `totalPrice` (the order total).
// Adjust `actualFare` source below if the gas order stores it under a different key.
//
// Requires (already at top of trips.js): const { releaseEscrow } = require("./escrow");

exports.onGasOrderCompleted = onDocumentUpdated(
  { region: "europe-west2", document: "gas_orders/{orderId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const orderId = event.params.orderId;

    if (after.status !== "delivered") return;
    if (after.walletProcessed === true) return; // idempotency

    // ── OTP validation (gas completion gate) ────────────────────────────────
    const storedOtp = after.deliveryOtp;
    const submittedOtp = after.otpSubmitted;

    if (storedOtp && !submittedOtp) {
      console.warn(`Gas order ${orderId}: delivered without OTP submission`);
      await db().collection("gas_orders").doc(orderId).update({
        status: "pendingOtp",
        flagReason: "Delivered without OTP verification",
        flaggedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    if (storedOtp && submittedOtp && storedOtp !== submittedOtp) {
      console.error(`Gas order ${orderId}: OTP mismatch`);
      await db().collection("gas_orders").doc(orderId).update({
        status: "flagged",
        flagReason: "OTP mismatch — possible fraud",
        flaggedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      await db().collection("admin_alerts").add({
        type: "otp_mismatch",
        orderId,
        driverId: after.driverId,
        reason: "Driver submitted wrong OTP for gas order",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    const passengerId = after.passengerId ?? after.customerId;
    const driverId = after.driverId;
    if (!passengerId || !driverId) {
      console.error(`Gas order ${orderId}: missing passengerId or driverId`);
      return;
    }

    try {
      const settings = await getPlatformSettings();
      const feePercent = (settings?.platformFeePercent ?? 15) / 100;

      // Gas order total. Adjust the field if your order stores it differently.
      let actualFare =
        after.actualFare ??
        after.totalPrice ??
        after.totalAmount ??
        after.estimatedFare ??
        0;

      let platformFee = Math.round(actualFare * feePercent * 100) / 100;
      let driverEarnings = Math.round((actualFare - platformFee) * 100) / 100;

      const escrowId = after.escrowId;
      const paymentMethod = after.paymentMethod ?? "wallet";

      if (escrowId) {
        // ── WALLET via escrow — canonical path ──────────────────────────────
        const eSnap = await db().collection("escrows").doc(escrowId).get();
        if (eSnap.exists) {
          const e = eSnap.data();
          if (typeof e.platformFee === "number") platformFee = e.platformFee;
          if (typeof e.driverNet === "number") driverEarnings = e.driverNet;
        }
        await releaseEscrow(escrowId, driverId, "gas_order_delivered");
      } else if (paymentMethod === "cash") {
        // ── CASH — driver collected payment physically ──────────────────────
        const commissionDebt = platformFee;
        await db().runTransaction(async (tx) => {
          const driverRef = db().collection("drivers").doc(driverId);
          const summaryRef = driverRef.collection("earnings").doc("summary");

          tx.update(driverRef, {
            totalEarnings: admin.firestore.FieldValue.increment(actualFare),
            todayEarnings: admin.firestore.FieldValue.increment(actualFare),
            walletBalance: admin.firestore.FieldValue.increment(actualFare),
            commissionOwed:
              admin.firestore.FieldValue.increment(commissionDebt),
            totalDeliveries: admin.firestore.FieldValue.increment(1),
            isAvailable: true,
            currentTripId: admin.firestore.FieldValue.delete(),
          });
          tx.set(
            summaryRef,
            {
              todayEarnings: admin.firestore.FieldValue.increment(actualFare),
              weekEarnings: admin.firestore.FieldValue.increment(actualFare),
              lifetimeEarnings:
                admin.firestore.FieldValue.increment(actualFare),
              commissionOwed:
                admin.firestore.FieldValue.increment(commissionDebt),
              lastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
          );

          const ledgerRef = db().collection("ledger").doc();
          tx.set(ledgerRef, {
            type: "COMMISSION_DEBT",
            status: "OWED",
            fromUserId: driverId,
            fromType: "driver",
            toType: "platform",
            amount: commissionDebt,
            currency: "GHS",
            grossFare: actualFare,
            platformFee: commissionDebt,
            driverNet: actualFare,
            referenceType: "gas_order",
            referenceId: orderId,
            paymentMethod: "cash",
            idempotencyKey: `commission_${orderId}`,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        });
      } else {
        // ── WALLET but no escrowId (legacy/safety) — guarded single deduction ─
        console.warn(
          `Gas order ${orderId}: wallet payment without escrowId — direct deduction`,
        );
        await db().runTransaction(async (tx) => {
          const walletRef = db().collection("wallets").doc(passengerId);
          const driverRef = db().collection("drivers").doc(driverId);
          const wdoc = await tx.get(walletRef);
          const balance = wdoc.exists ? (wdoc.data()?.balance ?? 0) : 0;
          if (balance >= actualFare) {
            tx.update(walletRef, {
              balance: admin.firestore.FieldValue.increment(-actualFare),
              lastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          } else {
            console.error(
              `Gas order ${orderId}: insufficient wallet balance for direct deduction`,
            );
          }
          tx.update(driverRef, {
            totalEarnings: admin.firestore.FieldValue.increment(driverEarnings),
            todayEarnings: admin.firestore.FieldValue.increment(driverEarnings),
            walletBalance: admin.firestore.FieldValue.increment(driverEarnings),
            totalDeliveries: admin.firestore.FieldValue.increment(1),
            isAvailable: true,
            currentTripId: admin.firestore.FieldValue.delete(),
          });
        });
      }

      // ── Mark processed ONCE, all paths ───────────────────────────────────
      await db().collection("gas_orders").doc(orderId).update({
        actualFare,
        platformFee,
        driverEarnings,
        walletProcessed: true,
        deliveredAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(
        `✅ Gas order ${orderId} delivered via ${escrowId ? "escrow" : paymentMethod}: total=${actualFare} driver=${driverEarnings} fee=${platformFee}`,
      );
    } catch (e) {
      console.error(`Gas order ${orderId} completion error:`, e.message);
      await db().collection("gas_orders").doc(orderId).update({
        walletProcessError: e.message,
        walletProcessedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  },
);

// ── autoConfirmTrips: runs every minute to process unconfirmed completions ────
const { onSchedule } = require("firebase-functions/v2/scheduler");

exports.autoConfirmTrips = onSchedule(
  { schedule: "every 1 minutes", region: "europe-west2", minInstances: 0 },
  async () => {
    const threeMinAgo = new Date(Date.now() - 3 * 60 * 1000);

    // Find completed trips where passenger hasn't confirmed in 3+ minutes
    const snap = await db()
      .collection("trips")
      .where("status", "==", "completed")
      .where("walletProcessed", "==", false)
      .where("passengerConfirmed", "==", false)
      .where("disputed", "==", false)
      .get();

    const promises = [];
    for (const doc of snap.docs) {
      const data = doc.data();
      const completedAt = data.completedAt?.toDate?.();
      if (!completedAt || completedAt > threeMinAgo) continue;

      // Auto-confirm
      promises.push(
        doc.ref.update({
          passengerConfirmed: true,
          passengerConfirmedAt: admin.firestore.FieldValue.serverTimestamp(),
          autoConfirmed: true,
        }),
      );
    }

    await Promise.allSettled(promises);
    console.log(`autoConfirmTrips: processed ${promises.length} trips`);
  },
);

// ── onTripCancelled: refund escrow ───────────────────────────────────────────
exports.onTripCancelled = onDocumentUpdated(
  { region: "europe-west2", document: "trips/{tripId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const tripId = event.params.tripId;

    if (before.status === after.status) return;

    const cancelledStatuses = [
      "cancelled",
      "cancelledByDriver",
      "cancelledByPassenger",
      "noDrivers",
      "noDriversAvailable",
    ];
    if (!cancelledStatuses.includes(after.status)) return;
    if (after.escrowRefunded === true) return; // idempotency

    const escrowId = after.escrowId;
    if (!escrowId) {
      console.log(`Trip ${tripId}: no escrowId — nothing to refund`);
      return;
    }

    try {
      const reason =
        after.status === "cancelledByDriver"
          ? "driver_cancelled"
          : (after.status === "noDrivers" || after.status === "noDriversAvailable")
            ? "no_drivers_found"
            : "passenger_cancelled";

      await refundEscrow(escrowId, reason);

      await db().collection("trips").doc(tripId).update({
        escrowRefunded: true,
        escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(
        `✅ Escrow ${escrowId} refunded for cancelled trip ${tripId}`,
      );

      // Notify passenger
      const passengerId = after.passengerId;
      if (passengerId) {
        const userDoc = await db().collection("users").doc(passengerId).get();
        const fcmToken = userDoc.data()?.fcmToken;
        if (fcmToken) {
          await admin
            .messaging()
            .send({
              token: fcmToken,
              notification: {
                title: "Trip Cancelled — Refund Processed",
                body: `Your GH₵${(after.estimatedFare || 0).toFixed(2)} has been returned to your wallet.`,
              },
              data: { type: "trip_cancelled", route: "/wallet" },
            })
            .catch(console.error);
        }
      }
    } catch (e) {
      console.error(`Failed to refund escrow for trip ${tripId}:`, e.message);
      await db().collection("admin_alerts").add({
        type: "escrow_refund_failed",
        tripId,
        escrowId,
        error: e.message,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  },
);

// ── onDeliveryCancelled: refund escrow ────────────────────────────────────────
exports.onDeliveryCancelled = onDocumentUpdated(
  { region: "europe-west2", document: "deliveries/{deliveryId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const deliveryId = event.params.deliveryId;

    if (before.status === after.status) return;
    if (after.status !== "cancelled") return;
    if (after.escrowRefunded === true) return;

    const escrowId = after.escrowId;
    if (!escrowId) return;

    try {
      await refundEscrow(escrowId, "delivery_cancelled");
      await db().collection("deliveries").doc(deliveryId).update({
        escrowRefunded: true,
        escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log(`✅ Escrow refunded for cancelled delivery ${deliveryId}`);
    } catch (e) {
      console.error(
        `Escrow refund failed for delivery ${deliveryId}:`,
        e.message,
      );
    }
  },
);

// ── onGasOrderCancelled: refund escrow ───────────────────────────────────────
exports.onGasOrderCancelled = onDocumentUpdated(
  { region: "europe-west2", document: "gas_orders/{orderId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const orderId = event.params.orderId;

    if (before.status === after.status) return;
    if (after.status !== "cancelled") return;
    if (after.escrowRefunded === true) return;

    const escrowId = after.escrowId;
    if (!escrowId) return;

    try {
      await refundEscrow(escrowId, "gas_order_cancelled");
      await db().collection("gas_orders").doc(orderId).update({
        escrowRefunded: true,
        escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log(`✅ Escrow refunded for cancelled gas order ${orderId}`);
    } catch (e) {
      console.error(
        `Escrow refund failed for gas order ${orderId}:`,
        e.message,
      );
    }
  },
);
