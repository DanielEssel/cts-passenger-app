const { releaseEscrow, refundEscrow, EscrowMismatchError } = require("./escrow");
const {
  verifyDeliveryEscrow,
  SettlementBlockedError,
  DELIVERY_REFERENCE_TYPE,
  DELIVERY_RELEASE_REASON,
} = require("./delivery_settlement");
const { verifyOrderEscrow } = require("./order_settlement");
const { rideFareFloor, deliveryFareFloor, verifyHeldAmount } = require("./payment_verification");
const { checkCompletionCode, waiverId, WAIVER_COLLECTION } = require("./completion_code");
const { adminAlert } = require("./alert_payload");
const { releaseFieldsIfCurrent } = require("./active_job");
const { storedCompletionCode } = require("./completion_codes");
const { stampedPrice, platformFeePercent } = require("./gas_pricing");
const { stampedDeliveryPrice } = require("./delivery_quotes");
const { PRICING_VERSION: DELIVERY_PRICING_VERSION, pesewas } = require("./delivery_pricing");
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

// Escrow reference types (attachEscrowToOrder) and release reasons.
const TRIP_REFERENCE_TYPE = "trip";
const TRIP_RELEASE_REASON = "trip_completed";
const GAS_REFERENCE_TYPE = "gas_order";
const GAS_RELEASE_REASON = "gas_order_delivered";

// ── RIDE (okada / taxi / pragyia) ────────────────────────────────────────────
// fare = (baseFare + perKmRate*km + perMinRate*min), floored at minimumFare,
//        then × surgeMultiplier if surge enabled. Surge applies AFTER the floor
//        so a surged minimum is still surged (matches rider expectation).
function calculateRideFare(serviceType, distanceKm, durationMin, settings) {
  const raw = serviceType?.toLowerCase() ?? "taxi";
  const type = ["okada", "taxi", "pragyia"].includes(raw) ? raw : "taxi";
  const p = settings?.[type] || {};

  const DEFAULTS = {
    okada: { baseFare: 3.0, perKmRate: 1.5, perMinRate: 0.2, minimumFare: 5.0 },
    pragyia: {
      baseFare: 4.0,
      perKmRate: 2.0,
      perMinRate: 0.25,
      minimumFare: 8.0,
    },
    taxi: { baseFare: 5.0, perKmRate: 2.5, perMinRate: 0.3, minimumFare: 10.0 },
  };
  const def = DEFAULTS[type];

  const base = p.baseFare ?? def.baseFare;
  const perKm = p.perKmRate ?? def.perKmRate;
  const perMin = p.perMinRate ?? def.perMinRate;
  const minFare = p.minimumFare ?? def.minimumFare;

  const km = Math.max(0, Number(distanceKm) || 0);
  const min = Math.max(0, Number(durationMin) || 0);

  const surgeOn = !!p.surgeEnabled;
  const surgeMul = p.surgeMultiplier ?? p.surgeMutiplier ?? 1.0;
  const surge = surgeOn && surgeMul > 1 ? surgeMul : 1.0;

  let fare = (base + perKm * km) * surge; // distance-only; perMin reserved for future
  fare = Math.max(fare, minFare);

  return round2(fare);
}

// ── DELIVERY ─────────────────────────────────────────────────────────────────
function calculateDeliveryFare(
  distanceKm,
  weightTier,
  isFragile,
  settings,
  vehicleType,
  requiresHelpers,
) {
  const d = settings?.delivery || {};

  // Normalise vehicle key: "Mini Truck" -> "minitruck", "Okada" -> "okada"
  const vkeyRaw = String(vehicleType || "okada")
    .toLowerCase()
    .replace(/[^a-z]/g, "");
  const vkey =
    vkeyRaw.includes("mini") || vkeyRaw.includes("truck")
      ? "miniTruck"
      : vkeyRaw.includes("aboboya")
        ? "aboboya"
        : "okada";

  // Default per-vehicle rates (seeded from prior hardcoded client values).
  const VEH_DEFAULTS = {
    okada: { baseFare: 5.0, perKmRate: 2.5, minimumFare: 10.0 },
    aboboya: { baseFare: 15.0, perKmRate: 4.0, minimumFare: 20.0 },
    miniTruck: { baseFare: 40.0, perKmRate: 7.0, minimumFare: 50.0 },
  };

  const veh = d[vkey] || {};
  const def = VEH_DEFAULTS[vkey];

  // Per-vehicle block first, then legacy flat delivery.*, then hard default.
  const base = veh.baseFare ?? d.baseFare ?? def.baseFare;
  const perKm = veh.perKmRate ?? d.perKmRate ?? def.perKmRate;
  const minFare = veh.minimumFare ?? d.minimumFare ?? def.minimumFare;

  const tier = String(weightTier || "small").toLowerCase();
  const weightSurcharge =
    tier === "large"
      ? (d.weightSurchargeLarge ?? 15.0)
      : tier === "medium"
        ? (d.weightSurchargeMedium ?? 5.0)
        : (d.weightSurchargeSmall ?? 0.0);

  const fragile = isFragile ? (d.fragileItemSurcharge ?? 5.0) : 0.0;
  const helpers = requiresHelpers ? (d.helperSurcharge ?? 10.0) : 0.0;
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

// onTripCompleted: one definition only, below. An earlier, never-used
// definition (overridden by the later export of the same name) was removed
// on 2026-10-28; production runs the later one.

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

/**
 * When the completion triggers first saw [orderId] completed, recorded
 * once in settlement_observations (server-only: no rules match it) and
 * returned as a Date. Concurrent first events record a single time.
 */
async function recordCompletionObserved(collection, orderId, now) {
  const ref = db().collection("settlement_observations").doc(`${collection}_${orderId}`);
  return db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const seen = snap.exists ? snap.data().completionObservedAt?.toDate?.() : null;
    if (seen) return seen;
    tx.set(ref, { collection, orderId,
      completionObservedAt: admin.firestore.Timestamp.fromDate(now) }, { merge: true });
    return now;
  });
}

exports.onTripCompleted = onDocumentUpdated(
  {
    region: "europe-west2",
    document: "trips/{tripId}",
  },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const tripId = event.params.tripId;

    if (!after) return;

    // Only completed trips enter settlement.
    if (after.status !== "completed") return;

    // Already successfully settled.
    if (after.walletProcessed === true) return;

    // A failed settlement waits for operations (as for deliveries). Without
    // this, the failure write itself re-fired this trigger, without end.
    // Operations retry by clearing settlementStatus once the cause is fixed.
    if (after.settlementStatus === "failed") return;

    const tripRef = db().collection("trips").doc(tripId);

    const now = new Date();

    // ─────────────────────────────────────────────
    // PASSENGER CONFIRMATION
    // ─────────────────────────────────────────────

    if (!after.passengerConfirmed) {
      // A passenger dispute stops auto-confirmation, as autoConfirmTrips
      // already does; operations resolve it. Without this, any later write
      // to the trip (e.g. a location update) re-fired this trigger and
      // auto-confirmed it anyway.
      if (after.disputed === true) {
        console.log(`Trip ${tripId}: disputed — not auto-confirming`);
        return;
      }

      // The window runs from server-trusted time: when this trigger first
      // saw the trip completed (recorded once, in a document no client can
      // write), or the trip's own completedAt if that is later. completedAt
      // alone is written by the driver's app, so a backdated value could
      // otherwise skip the passenger's chance to confirm or dispute.
      const observedAt = await recordCompletionObserved("trips", tripId, now);
      const completedAt = after.completedAt?.toDate?.() ?? null;
      const windowStart = completedAt && completedAt > observedAt ? completedAt : observedAt;

      const waitMinutes = (now - windowStart) / 60000;

      if (waitMinutes < 3) {
        console.log(
          `Trip ${tripId}: waiting for passenger confirmation ` +
            `(${waitMinutes.toFixed(1)} min)`,
        );

        return;
      }

      console.log(`Trip ${tripId}: auto-confirming after 3 minutes`);

      await tripRef.update({
        passengerConfirmed: true,
        passengerConfirmedAt: admin.firestore.FieldValue.serverTimestamp(),
        autoConfirmed: true,
      });

      // The update above triggers this function again.
      // Do not continue processing in this invocation.
      return;
    }

    // ─────────────────────────────────────────────
    // ACQUIRE SETTLEMENT LOCK
    // ─────────────────────────────────────────────

    const lockAcquired = await db().runTransaction(async (tx) => {
      const snap = await tx.get(tripRef);

      if (!snap.exists) {
        return false;
      }

      const trip = snap.data();

      // Another invocation already completed settlement.
      if (trip.walletProcessed === true) {
        return false;
      }

      const settlementStatus = trip.settlementStatus ?? "pending";

      // Another invocation is currently processing.
      if (settlementStatus === "processing") {
        console.log(`Trip ${tripId}: settlement already processing`);

        return false;
      }

      // Failed: waits for operations.
      if (settlementStatus === "failed") return false;

      tx.update(tripRef, {
        settlementStatus: "processing",
        settlementStartedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return true;
    });

    if (!lockAcquired) {
      return;
    }

    console.log(`🔒 Trip ${tripId}: settlement lock acquired`);

    // ─────────────────────────────────────────────
    // VALIDATE REQUIRED IDS
    // ─────────────────────────────────────────────

    const passengerId = after.passengerId;
    const driverId = after.driverId;

    if (!passengerId || !driverId) {
      console.error(`Trip ${tripId}: missing passengerId or driverId`);

      await tripRef.update({
        settlementStatus: "failed",
        walletProcessError: "Missing passengerId or driverId",
        walletProcessedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return;
    }

    try {
      // ───────────────────────────────────────────
      // DISTANCE / DURATION
      // ───────────────────────────────────────────

      const distanceKm = after.actualDistanceKm ?? after.distanceKm ?? 0;

      const startedAt = after.startedAt?.toDate?.() ?? null;

      const tripMinutes = startedAt ? (now - startedAt) / 60000 : 999;

      // ───────────────────────────────────────────
      // FRAUD CHECK
      // ───────────────────────────────────────────

      const TEST_MODE = true;

      if (!TEST_MODE && distanceKm < 0.3 && tripMinutes < 1) {
        console.warn(
          `Trip ${tripId}: suspicious completion — ` +
            `distance=${distanceKm}km ` +
            `time=${tripMinutes}min`,
        );

        await tripRef.update({
          status: "flagged",
          flagReason: "Suspicious completion — insufficient distance and time",
          flaggedAt: admin.firestore.FieldValue.serverTimestamp(),
          settlementStatus: "failed",
        });

        await db()
          .collection("admin_alerts")
          .add(adminAlert("suspicious_trip",
            `Trip ${tripId} was flagged: completed with only ${distanceKm.toFixed(1)} km in ` +
              `${tripMinutes.toFixed(1)} minutes.`,
            {
              tripId,
              driverId,
              reason:
                `Trip completed with only ` +
                `${distanceKm.toFixed(1)}km in ` +
                `${tripMinutes.toFixed(1)} minutes`,
            }));

        return;
      }

      // ───────────────────────────────────────────
      // SETTINGS
      // ───────────────────────────────────────────

      const settings = await getPlatformSettings();

      const feePercent = (settings?.platformFeePercent ?? 15) / 100;

      const serviceType = after.serviceType ?? "taxi";

      const paymentMethod = after.paymentMethod ?? "wallet";

      // ───────────────────────────────────────────
      // SERVER-AUTHORITATIVE FARE
      // ───────────────────────────────────────────

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

      // ───────────────────────────────────────────
      // WALLET / ESCROW
      // ───────────────────────────────────────────

      if (escrowId) {
        console.log(`💳 Trip ${tripId}: releasing escrow ${escrowId}`);

        const escrowSnap = await db().collection("escrows").doc(escrowId).get();
        const escrow = escrowSnap.exists ? escrowSnap.data() : null;

        // The escrow must be this trip's own payment: same passenger,
        // attached to exactly this trip, still HELD (or already released
        // for it by an earlier attempt). Its id on the trip document alone
        // proves nothing.
        const check = verifyOrderEscrow({
          orderId: tripId, passengerId, escrow,
          referenceType: TRIP_REFERENCE_TYPE, releaseReason: TRIP_RELEASE_REASON,
          expectedFare: after.estimatedFare,
        });
        if (!check.ok) throw new SettlementBlockedError(check.reason, escrowId);
        // The hold's amount was chosen by the app: before anything moves, it
        // must equal the booked fare and reach the server's minimum price for
        // the route (payment_verification.js), else nothing is released.
        if (check.mode === "release") {
          const priced = verifyHeldAmount({
            referenceType: TRIP_REFERENCE_TYPE, order: after, escrowAmount: escrow.amount, settings,
          });
          if (!priced.ok) throw new SettlementBlockedError(priced.reason, escrowId);
        }

        // The held amount and its split are authoritative.
        actualFare = escrow.amount;
        if (typeof escrow.platformFee === "number") platformFee = escrow.platformFee;
        if (typeof escrow.driverNet === "number") driverEarnings = escrow.driverNet;

        if (check.mode === "release") {
          let released;
          try {
            released = await releaseEscrow(escrowId, driverId, TRIP_RELEASE_REASON, {
              userId: passengerId, referenceId: tripId, referenceType: TRIP_REFERENCE_TYPE,
            });
          } catch (e) {
            if (e instanceof EscrowMismatchError) {
              throw new SettlementBlockedError(e.reason, escrowId);
            }
            throw e;
          }
          // Not HELD by the time the transaction ran: a refund got there
          // first. Never record this as settled.
          if (!released) {
            throw new SettlementBlockedError("escrow_not_held_at_release", escrowId);
          }
        }
      }

      // ───────────────────────────────────────────
      // CASH
      // ───────────────────────────────────────────
      else if (paymentMethod === "cash") {
        console.log(`💵 Trip ${tripId}: processing cash settlement`);

        const commissionDebt = platformFee;

        const ledgerRef = db().collection("ledger").doc(`commission_${tripId}`);

        await db().runTransaction(async (tx) => {
          const existingLedger = await tx.get(ledgerRef);

          const driverRef = db().collection("drivers").doc(driverId);

          const summaryRef = driverRef.collection("earnings").doc("summary");

          // Idempotent recovery:
          // if this ledger already exists, the cash settlement
          // was already applied.
          if (existingLedger.exists) {
            return;
          }

          // Freed only while the driver still holds this trip (active_job.js).
          const driverNow = await tx.get(driverRef);

          tx.update(driverRef, {
            totalEarnings: admin.firestore.FieldValue.increment(actualFare),

            todayEarnings: admin.firestore.FieldValue.increment(actualFare),

            commissionOwed:
              admin.firestore.FieldValue.increment(commissionDebt),

            completedTrips: admin.firestore.FieldValue.increment(1),

            ...releaseFieldsIfCurrent(driverNow.exists ? driverNow.data() : null, tripId),
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
      }

      // ───────────────────────────────────────────
      // LEGACY WALLET WITHOUT ESCROW
      // ───────────────────────────────────────────
      else {
        console.warn(
          `Trip ${tripId}: wallet payment without escrowId — ` +
            `using guarded legacy deduction`,
        );

        // Charged at the booked fare only. actualFare and the completion
        // distance are written by the driver, so they never set what the
        // passenger pays; the booked fare must also reach the server's
        // minimum price for the route, as a held amount must.
        const booked = Number(after.estimatedFare);
        const floor = rideFareFloor(after, settings);
        if (!(booked > 0) || floor == null || booked + 0.01 < floor) {
          throw new SettlementBlockedError("legacy_wallet_fare_unverified", tripId);
        }
        actualFare = Math.round(booked * 100) / 100;
        platformFee = Math.round(actualFare * feePercent * 100) / 100;
        driverEarnings = Math.round((actualFare - platformFee) * 100) / 100;

        const ledgerRef = db()
          .collection("ledger")
          .doc(`wallet_trip_${tripId}`);

        await db().runTransaction(async (tx) => {
          const existingLedger = await tx.get(ledgerRef);

          if (existingLedger.exists) {
            return;
          }

          const walletRef = db().collection("wallets").doc(passengerId);

          const driverRef = db().collection("drivers").doc(driverId);

          const walletSnap = await tx.get(walletRef);
          const driverNow = await tx.get(driverRef);

          const balance = walletSnap.exists
            ? (walletSnap.data()?.balance ?? 0)
            : 0;

          if (balance < actualFare) {
            throw new Error(
              `Insufficient wallet balance: ` + `${balance} < ${actualFare}`,
            );
          }

          tx.update(walletRef, {
            balance: admin.firestore.FieldValue.increment(-actualFare),

            lastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          tx.update(driverRef, {
            totalEarnings: admin.firestore.FieldValue.increment(driverEarnings),

            todayEarnings: admin.firestore.FieldValue.increment(driverEarnings),

            // Wallet-paid, so withdrawable, as for escrow, delivery and gas.
            walletBalance: admin.firestore.FieldValue.increment(driverEarnings),

            completedTrips: admin.firestore.FieldValue.increment(1),

            ...releaseFieldsIfCurrent(driverNow.exists ? driverNow.data() : null, tripId),
          });

          tx.set(ledgerRef, {
            type: "TRIP_WALLET_PAYMENT",
            status: "COMPLETED",

            fromUserId: passengerId,
            fromType: "passenger",

            toUserId: driverId,
            toType: "driver",

            amount: actualFare,
            currency: "GHS",

            grossFare: actualFare,
            platformFee,
            driverNet: driverEarnings,

            referenceType: "trip",
            referenceId: tripId,

            paymentMethod: "wallet",

            idempotencyKey: `wallet_trip_${tripId}`,

            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        });
      }

      // ───────────────────────────────────────────
      // FINAL SUCCESS STATE
      // ───────────────────────────────────────────

      await tripRef.update({
        actualFare,
        platformFee,
        driverEarnings,

        walletProcessed: true,

        settlementStatus: "completed",

        walletProcessedAt: admin.firestore.FieldValue.serverTimestamp(),

        settlementCompletedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(
        `✅ Trip ${tripId} settled successfully: ` +
          `payment=${escrowId ? "escrow" : paymentMethod}, ` +
          `fare=${actualFare}, ` +
          `driver=${driverEarnings}, ` +
          `fee=${platformFee}`,
      );
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);

      console.error(`❌ Trip ${tripId} settlement error:`, message);

      const reason =
        e instanceof SettlementBlockedError ? e.reason : "settlement_error";

      await tripRef.update({
        settlementStatus: "failed",

        settlementFailureReason: reason,

        walletProcessError: message,

        walletProcessedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      // Operations investigate every failed settlement (ids only).
      await db().collection("admin_alerts").add(adminAlert("trip_settlement_failed",
        `Trip ${tripId}: settlement did not complete (${reason}). Needs review.`,
        { tripId, escrowId: after.escrowId ?? null, reason }));
    }
  },
);

// ── Delivery completion settlement ───────────────────────────────────────────
// Deliveries hold wallet funds in escrow at booking. Completion therefore
// releases the existing escrow instead of charging the passenger again.
exports.onDeliveryCompleted = onDocumentUpdated(
  { region: "europe-west2", document: "deliveries/{deliveryId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const deliveryId = event.params.deliveryId;

    if (!after) return;
    if (before.status === after.status && after.status !== "completed") return;
    if (after.status !== "completed") return;
    if (after.walletProcessed === true) return;
    // A failed settlement waits for operations. Without this, the failure
    // write itself (an update to a completed delivery) re-fired this
    // trigger, which failed and wrote again, without end. Operations retry
    // by clearing settlementStatus once the cause is fixed.
    if (after.settlementStatus === "failed") return;

    const deliveryRef = db().collection("deliveries").doc(deliveryId);

    // ── SERVER-SIDE OTP VALIDATION ──────────────────────────────────────────
    // The stored code is the server-held one (completion_codes.js); orders
    // from before it existed fall back to their own deliveryOtp.
    const storedOtp = await storedCompletionCode("deliveries", deliveryId, after);
    const submittedOtp = after.otpSubmitted;

    if (!storedOtp || !submittedOtp) {
      console.warn(`Delivery ${deliveryId}: completion without valid OTP`);

      await deliveryRef.update({
        status: "flagged",
        flagReason: "Delivery completed without OTP verification",
        flaggedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      await db().collection("admin_alerts").add(adminAlert("delivery_otp_missing",
        `Delivery ${deliveryId} was flagged: marked completed without a verified completion code.`,
        {
          deliveryId,
          driverId: after.driverId ?? null,
          reason: "Delivery was marked completed without OTP verification",
        }));

      return;
    }

    if (String(storedOtp) !== String(submittedOtp)) {
      console.error(`Delivery ${deliveryId}: OTP mismatch`);

      await deliveryRef.update({
        status: "flagged",
        flagReason: "OTP mismatch — possible fraud",
        flaggedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      await db().collection("admin_alerts").add(adminAlert("delivery_otp_mismatch",
        `Delivery ${deliveryId} was flagged: the submitted completion code did not match.`,
        {
          deliveryId,
          driverId: after.driverId ?? null,
          reason: "Driver submitted wrong OTP for delivery",
        }));

      return;
    }

    const passengerId = after.passengerId;
    const driverId = after.driverId;

    if (!passengerId || !driverId) {
      console.error(`Delivery ${deliveryId}: missing passengerId or driverId`);

      await deliveryRef.update({
        settlementStatus: "failed",
        walletProcessError: "Missing passengerId or driverId",
        walletProcessedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return;
    }

    // ── SETTLEMENT LOCK ─────────────────────────────────────────────────────
    const lockAcquired = await db().runTransaction(async (tx) => {
      const snap = await tx.get(deliveryRef);

      if (!snap.exists) return false;

      const delivery = snap.data();

      if (delivery.walletProcessed === true) return false;
      if (delivery.settlementStatus === "processing") return false;
      if (delivery.settlementStatus === "failed") return false;

      tx.update(deliveryRef, {
        settlementStatus: "processing",
        settlementStartedAt:
          admin.firestore.FieldValue.serverTimestamp(),
      });

      return true;
    });

    if (!lockAcquired) return;

    try {
      const settings = await getPlatformSettings();
      // A malformed fee (text, negative, over 100) would settle NaN amounts.
      const feePct = platformFeePercent(settings);
      if (feePct === undefined) throw new SettlementBlockedError("platform_fee_invalid", deliveryId);
      const feePercent = feePct / 100;
      const paymentMethod = after.paymentMethod ?? "wallet";

      // For escrow-backed deliveries, escrow.amount is authoritative.
      // For cash/legacy deliveries, estimatedFare is the current stored fare.
      // A delivery priced by a server quote (delivery_quotes.js, a
      // server-only stamp) settles on that quote's total and commission.
      const dStamp = stampedDeliveryPrice(after);
      const quoted = dStamp?.version === DELIVERY_PRICING_VERSION ? dStamp : null;
      let actualFare = quoted ? quoted.total : Number(after.estimatedFare ?? 0);

      let platformFee = quoted ? quoted.commission
        : Math.round(actualFare * feePercent * 100) / 100;

      let driverEarnings = quoted ? quoted.driverNet
        : Math.round((actualFare - platformFee) * 100) / 100;

      const escrowId = after.escrowId;

      // ── WALLET / ESCROW ───────────────────────────────────────────────────
      if (escrowId) {
        console.log(
          `💳 Delivery ${deliveryId}: releasing escrow ${escrowId}`,
        );

        const escrowSnap = await db()
          .collection("escrows")
          .doc(escrowId)
          .get();
        const escrow = escrowSnap.exists ? escrowSnap.data() : null;

        // The escrow must be this delivery's own payment: same passenger,
        // attached to exactly this delivery, still HELD (or already
        // released for it by an earlier attempt).
        const check = verifyDeliveryEscrow({
          deliveryId,
          passengerId,
          estimatedFare: after.estimatedFare,
          escrow,
        });
        if (!check.ok) throw new SettlementBlockedError(check.reason, escrowId);
        // The hold's amount was chosen by the app: before anything moves, it
        // must equal the booked fare and reach the server's minimum price
        // (payment_verification.js), else nothing is released.
        if (check.mode === "release") {
          if (quoted) {
            if (pesewas(escrow.amount) !== quoted.totalPesewas) {
              throw new SettlementBlockedError("hold_amount_mismatch", escrowId);
            }
          } else {
            const priced = verifyHeldAmount({
              referenceType: "delivery", order: after, escrowAmount: escrow.amount, settings,
            });
            if (!priced.ok) throw new SettlementBlockedError(priced.reason, escrowId);
          }
        }

        // escrow.amount is authoritative for escrow-backed deliveries.
        actualFare = escrow.amount;
        if (typeof escrow.platformFee === "number") {
          platformFee = escrow.platformFee;
        }
        if (typeof escrow.driverNet === "number") {
          driverEarnings = escrow.driverNet;
        }

        if (check.mode === "release") {
          let released;
          try {
            released = await releaseEscrow(
              escrowId,
              driverId,
              DELIVERY_RELEASE_REASON,
              {
                userId: passengerId,
                referenceId: deliveryId,
                referenceType: DELIVERY_REFERENCE_TYPE,
              },
            );
          } catch (e) {
            if (e instanceof EscrowMismatchError) {
              throw new SettlementBlockedError(e.reason, escrowId);
            }
            throw e;
          }
          // Not HELD by the time the transaction ran: a refund (or another
          // settlement) got there first. Never record this as settled.
          if (!released) {
            throw new SettlementBlockedError(
              "escrow_not_held_at_release",
              escrowId,
            );
          }
        }
      }

      // ── CASH ──────────────────────────────────────────────────────────────
      else if (paymentMethod === "cash") {
        console.log(
          `💵 Delivery ${deliveryId}: processing cash settlement`,
        );

        const commissionDebt = platformFee;

        const ledgerRef = db()
          .collection("ledger")
          .doc(`commission_delivery_${deliveryId}`);

        await db().runTransaction(async (tx) => {
          const existingLedger = await tx.get(ledgerRef);

          if (existingLedger.exists) return;

          const driverRef = db()
            .collection("drivers")
            .doc(driverId);

          const summaryRef = driverRef
            .collection("earnings")
            .doc("summary");

          // Freed only while the driver still holds this delivery (active_job.js).
          const driverNow = await tx.get(driverRef);

          tx.update(driverRef, {
            totalEarnings:
              admin.firestore.FieldValue.increment(actualFare),

            todayEarnings:
              admin.firestore.FieldValue.increment(actualFare),

            commissionOwed:
              admin.firestore.FieldValue.increment(commissionDebt),

            totalDeliveries:
              admin.firestore.FieldValue.increment(1),

            ...releaseFieldsIfCurrent(driverNow.exists ? driverNow.data() : null, deliveryId),
          });

          tx.set(
            summaryRef,
            {
              todayEarnings:
                admin.firestore.FieldValue.increment(actualFare),

              weekEarnings:
                admin.firestore.FieldValue.increment(actualFare),

              lifetimeEarnings:
                admin.firestore.FieldValue.increment(actualFare),

              totalEarnings:
                admin.firestore.FieldValue.increment(actualFare),

              commissionOwed:
                admin.firestore.FieldValue.increment(commissionDebt),

              lastUpdatedAt:
                admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
          );

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
            idempotencyKey:
              `commission_delivery_${deliveryId}`,
            createdAt:
              admin.firestore.FieldValue.serverTimestamp(),
          });
        });
      }

      // ── LEGACY WALLET WITHOUT ESCROW ──────────────────────────────────────
      else {
        console.warn(
          `Delivery ${deliveryId}: wallet payment without escrowId — ` +
          `using guarded legacy deduction`,
        );

        // Charged at the booked fare only, and only when it reaches the
        // server's minimum price for the route, as a held amount must.
        const floor = deliveryFareFloor(after, settings);
        if (!(actualFare > 0) || floor == null || actualFare + 0.01 < floor) {
          throw new SettlementBlockedError("legacy_wallet_fare_unverified", deliveryId);
        }

        const ledgerRef = db()
          .collection("ledger")
          .doc(`wallet_delivery_${deliveryId}`);

        await db().runTransaction(async (tx) => {
          const existingLedger = await tx.get(ledgerRef);

          if (existingLedger.exists) return;

          const walletRef = db()
            .collection("wallets")
            .doc(passengerId);

          const driverRef = db()
            .collection("drivers")
            .doc(driverId);

          const walletSnap = await tx.get(walletRef);
          const driverNow = await tx.get(driverRef);

          const balance = walletSnap.exists
            ? (walletSnap.data()?.balance ?? 0)
            : 0;

          if (balance < actualFare) {
            throw new Error(
              `Insufficient wallet balance: ${balance} < ${actualFare}`,
            );
          }

          tx.update(walletRef, {
            balance:
              admin.firestore.FieldValue.increment(-actualFare),

            lastUpdatedAt:
              admin.firestore.FieldValue.serverTimestamp(),
          });

          tx.update(driverRef, {
            totalEarnings:
              admin.firestore.FieldValue.increment(driverEarnings),

            todayEarnings:
              admin.firestore.FieldValue.increment(driverEarnings),

            walletBalance:
              admin.firestore.FieldValue.increment(driverEarnings),

            totalDeliveries:
              admin.firestore.FieldValue.increment(1),

            ...releaseFieldsIfCurrent(driverNow.exists ? driverNow.data() : null, deliveryId),
          });

          tx.set(ledgerRef, {
            type: "DELIVERY_WALLET_PAYMENT",
            status: "COMPLETED",
            fromUserId: passengerId,
            fromType: "passenger",
            toUserId: driverId,
            toType: "driver",
            amount: actualFare,
            currency: "GHS",
            grossFare: actualFare,
            platformFee,
            driverNet: driverEarnings,
            referenceType: "delivery",
            referenceId: deliveryId,
            paymentMethod: "wallet",
            idempotencyKey:
              `wallet_delivery_${deliveryId}`,
            createdAt:
              admin.firestore.FieldValue.serverTimestamp(),
          });
        });
      }

      // ── FINAL SUCCESS STATE ───────────────────────────────────────────────
      await deliveryRef.update({
        actualFare,
        platformFee,
        driverEarnings,
        walletProcessed: true,
        settlementStatus: "completed",
        walletProcessedAt:
          admin.firestore.FieldValue.serverTimestamp(),
        settlementCompletedAt:
          admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(
        `✅ Delivery ${deliveryId} settled: ` +
        `payment=${escrowId ? "escrow" : paymentMethod}, ` +
        `fare=${actualFare}, ` +
        `driver=${driverEarnings}, ` +
        `fee=${platformFee}`,
      );
    } catch (e) {
      const message =
        e instanceof Error ? e.message : String(e);

      console.error(
        `❌ Delivery ${deliveryId} settlement error:`,
        message,
      );

      const reason =
        e instanceof SettlementBlockedError ? e.reason : "settlement_error";

      await deliveryRef.update({
        settlementStatus: "failed",
        settlementFailureReason: reason,
        walletProcessError: message,
        walletProcessedAt:
          admin.firestore.FieldValue.serverTimestamp(),
      });

      // Operations investigate every failed settlement (ids only).
      await db().collection("admin_alerts").add(adminAlert("delivery_settlement_failed",
        `Delivery ${deliveryId}: settlement did not complete (${reason}). Needs review.`,
        { deliveryId, escrowId: after.escrowId ?? null, reason }));
    }
  },
);



exports.onGasOrderCompleted = onDocumentUpdated(
  { region: "europe-west2", document: "gas_orders/{orderId}" },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const orderId = event.params.orderId;

    if (after.status !== "delivered") return;
    if (after.walletProcessed === true) return; // idempotency
    // A failed settlement waits for operations (as for deliveries); the
    // failure write must not re-fire it. Retry by clearing settlementStatus.
    if (after.settlementStatus === "failed") return;

    // ── Completion-code gate (completion_code.js) ───────────────────────────
    // No usable stored code → held for review unless operations recorded a
    // waiver; no submitted code → pendingOtp (the driver can resubmit);
    // malformed or wrong code → flagged. Decided and written in one
    // transaction on the current order, so duplicate events act once.
    // Code values are never logged.
    {
      const orderDocRef = db().collection("gas_orders").doc(orderId);
      const waiverRef = db().collection(WAIVER_COLLECTION).doc(waiverId("gas_orders", orderId));
      const gate = await db().runTransaction(async (tx) => {
        const [snap, waiverSnap] = await Promise.all([tx.get(orderDocRef), tx.get(waiverRef)]);
        if (!snap.exists) return { stop: true };
        const order = snap.data();
        if (order.status !== "delivered" || order.walletProcessed === true) return { stop: true };
        // An order delivered by its own customer's account earns nothing
        // (as the live handler of 2026-10-23 already decided): held for review.
        const customer = order.passengerId ?? order.customerId;
        if (customer && customer === order.driverId) {
          tx.update(orderDocRef, { status: "flagged",
            flagReason: "Delivered by the customer's own account — not settled",
            flaggedAt: admin.firestore.FieldValue.serverTimestamp() });
          tx.set(db().collection("admin_alerts").doc(), adminAlert("gas_self_order",
            `Gas order ${orderId} was delivered by the customer's own account; it was not settled.`,
            { orderId, driverId: order.driverId ?? null }));
          return { stop: true, blocked: "self_order" };
        }
        // The server-held code (completion_codes.js), else the order's own.
        const stored = await storedCompletionCode("gas_orders", orderId, order, tx);
        const check = checkCompletionCode({
          stored, submitted: order.otpSubmitted,
          waiver: waiverSnap.exists ? waiverSnap.data() : null,
          collection: "gas_orders", orderId,
        });
        if (check.ok) return { stop: false, via: check.via };
        const now = admin.firestore.FieldValue.serverTimestamp();
        if (check.outcome === "pending") {
          tx.update(orderDocRef, { status: "pendingOtp",
            flagReason: "Delivered without OTP verification", flaggedAt: now });
        } else if (check.outcome === "mismatch") {
          tx.update(orderDocRef, { status: "flagged",
            flagReason: "OTP mismatch — possible fraud", flaggedAt: now });
          tx.set(db().collection("admin_alerts").doc(), adminAlert("otp_mismatch",
            `Gas order ${orderId} was flagged: the submitted completion code did not match (${check.reason}).`,
            { orderId, driverId: order.driverId ?? null, reason: check.reason }));
        } else {
          tx.update(orderDocRef, { status: "flagged",
            flagReason: "Delivered without a stored completion code — needs review", flaggedAt: now });
          tx.set(db().collection("admin_alerts").doc(), adminAlert("gas_code_missing",
            `Gas order ${orderId} was flagged: delivered without a stored completion code. ` +
              "Review it, or record a waiver before settling.",
            { orderId, driverId: order.driverId ?? null, reason: check.reason }));
        }
        return { stop: true, blocked: check.reason };
      });
      if (gate.blocked) console.warn(`Gas order ${orderId}: completion held (${gate.blocked})`);
      if (gate.stop) return;
      if (gate.via === "waiver") console.log(`Gas order ${orderId}: settling under a recorded code waiver`);
    }

    const passengerId = after.passengerId ?? after.customerId;
    const driverId = after.driverId;
    if (!passengerId || !driverId) {
      console.error(`Gas order ${orderId}: missing passengerId or driverId`);
      return;
    }

    const orderRef = db().collection("gas_orders").doc(orderId);

    // ── SETTLEMENT LOCK ─────────────────────────────────────────────────────
    // Every later write to a delivered order (a rating, the failure write)
    // re-fires this trigger; only one invocation may settle.
    const lockAcquired = await db().runTransaction(async (tx) => {
      const snap = await tx.get(orderRef);
      if (!snap.exists) return false;
      const order = snap.data();
      if (order.status !== "delivered") return false;
      if (order.walletProcessed === true) return false;
      if (order.settlementStatus === "processing") return false;
      if (order.settlementStatus === "failed") return false;
      tx.update(orderRef, {
        settlementStatus: "processing",
        settlementStartedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return true;
    });
    if (!lockAcquired) return;

    const escrowId = after.escrowId;
    try {
      const settings = await getPlatformSettings();
      // The price verified when the order was placed (gas_pricing.js; a
      // server-only field), with the commission worked out then. Orders
      // placed before verifiedPrice existed use the stored total and the
      // current fee, as before.
      const stamp = stampedPrice(after);
      const feePct = stamp ? stamp.platformFeePercent : platformFeePercent(settings);
      if (feePct === undefined) throw new SettlementBlockedError("platform_fee_invalid", orderId);

      // The order total stored at booking. actualFare is written by the
      // Driver app (a copy of totalPrice) and is not trusted here.
      let actualFare = Number(
        stamp ? stamp.total : after.totalPrice ?? after.totalAmount ?? after.estimatedFare ?? 0,
      );
      if (!Number.isFinite(actualFare) || actualFare < 0) {
        throw new SettlementBlockedError("order_total_invalid", orderId);
      }

      let platformFee = stamp ? stamp.commission : Math.round(actualFare * (feePct / 100) * 100) / 100;
      let driverEarnings = stamp ? stamp.driverNet : Math.round((actualFare - platformFee) * 100) / 100;

      const paymentMethod = after.paymentMethod ?? "wallet";

      if (escrowId) {
        // ── WALLET via escrow — canonical path ──────────────────────────────
        const eSnap = await db().collection("escrows").doc(escrowId).get();
        const escrow = eSnap.exists ? eSnap.data() : null;

        // The escrow must be this order's own payment (see order_settlement.js).
        const check = verifyOrderEscrow({
          orderId, passengerId, escrow,
          referenceType: GAS_REFERENCE_TYPE, releaseReason: GAS_RELEASE_REASON,
          expectedFare: after.totalPrice,
        });
        if (!check.ok) throw new SettlementBlockedError(check.reason, escrowId);
        // The hold's amount was chosen by the app: before anything moves, it
        // must equal the verified price (stamped at creation), or for an
        // order without one, the booked total reaching the server's Gas
        // price now (payment_verification.js); else nothing is released.
        if (check.mode === "release") {
          if (stamp) {
            if (Math.round(escrow.amount * 100) !== Math.round(stamp.total * 100)) {
              throw new SettlementBlockedError("hold_amount_mismatch", escrowId);
            }
          } else {
            const priced = verifyHeldAmount({
              referenceType: GAS_REFERENCE_TYPE, order: after, escrowAmount: escrow.amount, settings,
            });
            if (!priced.ok) throw new SettlementBlockedError(priced.reason, escrowId);
          }
        }

        actualFare = escrow.amount;
        if (typeof escrow.platformFee === "number") platformFee = escrow.platformFee;
        if (typeof escrow.driverNet === "number") driverEarnings = escrow.driverNet;

        if (check.mode === "release") {
          let released;
          try {
            released = await releaseEscrow(escrowId, driverId, GAS_RELEASE_REASON, {
              userId: passengerId, referenceId: orderId, referenceType: GAS_REFERENCE_TYPE,
            });
          } catch (e) {
            if (e instanceof EscrowMismatchError) {
              throw new SettlementBlockedError(e.reason, escrowId);
            }
            throw e;
          }
          if (!released) {
            throw new SettlementBlockedError("escrow_not_held_at_release", escrowId);
          }
        }
      } else if (paymentMethod === "cash") {
        // ── CASH — driver collected payment physically ──────────────────────
        // One ledger document per order makes a retry a no-op.
        const commissionDebt = platformFee;
        const ledgerRef = db().collection("ledger").doc(`commission_gas_${orderId}`);
        await db().runTransaction(async (tx) => {
          if ((await tx.get(ledgerRef)).exists) return;
          const driverRef = db().collection("drivers").doc(driverId);
          const summaryRef = driverRef.collection("earnings").doc("summary");
          // Freed only while the driver still holds this order (active_job.js).
          const driverNow = await tx.get(driverRef);

          tx.update(driverRef, {
            totalEarnings: admin.firestore.FieldValue.increment(actualFare),
            todayEarnings: admin.firestore.FieldValue.increment(actualFare),
            commissionOwed:
              admin.firestore.FieldValue.increment(commissionDebt),
            totalDeliveries: admin.firestore.FieldValue.increment(1),
            ...releaseFieldsIfCurrent(driverNow.exists ? driverNow.data() : null, orderId),
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
        // ── WALLET but no escrow — nothing verified to pay from ─────────────
        // A legacy Gas order has no server price: its total is what the app
        // wrote. Without a hold taken for it at booking, nothing is charged
        // or credited (as the live handler of 2026-10-23 already decided).
        throw new SettlementBlockedError("wallet_order_without_escrow", orderId);
      }

      // ── Mark processed ONCE, all paths ───────────────────────────────────
      await orderRef.update({
        actualFare,
        platformFee,
        driverEarnings,
        walletProcessed: true,
        settlementStatus: "completed",
        walletProcessedAt: admin.firestore.FieldValue.serverTimestamp(),
        settlementCompletedAt: admin.firestore.FieldValue.serverTimestamp(),
        deliveredAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(
        `✅ Gas order ${orderId} delivered via ${escrowId ? "escrow" : paymentMethod}: total=${actualFare} driver=${driverEarnings} fee=${platformFee}`,
      );
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      console.error(`Gas order ${orderId} completion error:`, message);
      const reason =
        e instanceof SettlementBlockedError ? e.reason : "settlement_error";
      await orderRef.update({
        settlementStatus: "failed",
        settlementFailureReason: reason,
        walletProcessError: message,
        walletProcessedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      await db().collection("admin_alerts").add(adminAlert("gas_settlement_failed",
        `Gas order ${orderId}: settlement did not complete (${reason}). Needs review.`,
        { orderId, escrowId: escrowId ?? null, reason }));
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

// ── Cancellation refunds (Ride, Delivery, Gas) ──────────────────────────────
// refundEscrow re-checks HELD inside its transaction and returns true only
// when THIS call returned the money. escrowRefunded is recorded only then: a
// duplicate or concurrent cancel event, or an escrow that was already
// released (e.g. the order had completed), must not be marked as refunded.
// Returns true when this call refunded. Never throws.
// A cancellation of an order whose service was already performed must not
// refund: its escrow may still be HELD for the driver (settlement pending,
// flagged for review or awaiting the OTP). Firestore rules stop the parties
// making this transition; this guards server-side and admin writes too.
// The completion timestamp is written only by the driver's completion step
// (and by settlement), so it marks a performed service even when the
// previous status is not known.
const DELIVERY_CANCELLED_STATUSES = ["cancelled", "cancelledByDriver", "cancelledByPassenger"];
const GAS_CANCELLED_STATUSES = ["cancelled", "failed"];

const POST_COMPLETION_STATUSES = {
  trips: ["completed", "flagged"],
  deliveries: ["completed", "flagged"],
  gas_orders: ["delivered", "pendingOtp", "flagged"],
};
const COMPLETION_MARKER = { trips: "completedAt", deliveries: "completedAt", gas_orders: "deliveredAt" };

function cancelledAfterCompletion(collection, before, after) {
  return POST_COMPLETION_STATUSES[collection].includes(before?.status) ||
    after?.[COMPLETION_MARKER[collection]] != null;
}

async function alertCancelAfterCompletion({ collection, orderId, idField, escrowId, alertPrefix, before }) {
  console.warn(`${collection}/${orderId}: cancelled after completion — not refunding`);
  await db().collection("admin_alerts").add(adminAlert(`${alertPrefix}_cancel_after_completion`,
    `${collection}/${orderId} was cancelled after completion; its escrow was not refunded. Needs review.`,
    { [idField]: orderId, escrowId: escrowId ?? null, previousStatus: before?.status ?? null }));
}

async function refundCancelledOrder({ collection, orderId, idField, escrowId, reason, alertPrefix,
  failedAlertType, passengerId, referenceType }) {
  let refunded = false;
  try {
    // Only the escrow that belongs to this order and its passenger.
    refunded = await refundEscrow(escrowId, reason,
      { userId: passengerId ?? null, referenceId: orderId, referenceType });
    if (refunded) {
      await db().collection(collection).doc(orderId).update({
        escrowRefunded: true,
        escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log(`✅ Escrow ${escrowId} refunded for cancelled ${collection}/${orderId}`);
      return true;
    }
    const escrowSnap = await db().collection("escrows").doc(escrowId).get();
    const escrowStatus = escrowSnap.exists ? escrowSnap.data().status : "missing";
    console.warn(
      `${collection}/${orderId}: cancel did not refund escrow ${escrowId} (${escrowStatus})`,
    );
    // Already refunded is the expected result of a duplicate event; any
    // other state (e.g. RELEASED to a driver) needs a person to look.
    if (escrowStatus !== "REFUNDED") {
      await db().collection("admin_alerts").add(adminAlert(`${alertPrefix}_cancel_refund_skipped`,
        `${collection}/${orderId} was cancelled but escrow ${escrowId} is ${escrowStatus}; ` +
          "it was not refunded. Needs review.",
        { [idField]: orderId, escrowId, escrowStatus }));
    }
    return false;
  } catch (e) {
    console.error(`Escrow refund failed for ${collection}/${orderId}:`, e.message);
    await db().collection("admin_alerts").add(adminAlert(
      failedAlertType || `${alertPrefix}_cancel_refund_failed`,
      refunded
        ? `${collection}/${orderId}: the escrow was refunded but the order could not be marked. Needs review.`
        : `${collection}/${orderId}: the cancellation refund failed. Needs review.`,
      {
        [idField]: orderId,
        escrowId,
        // true: the money was returned but escrowRefunded could not be written.
        refundCompleted: refunded,
        error: e.message,
      }));
    return refunded;
  }
}

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
      // Written by the retired acceptTrip callable when a driver tried to
      // accept an expired request; kept so such trips still refund here
      // rather than by the 2-hour recovery sweep.
      "expired",
    ];
    if (!cancelledStatuses.includes(after.status)) return;
    if (after.escrowRefunded === true) return; // idempotency

    const escrowId = after.escrowId;
    if (!escrowId) {
      console.log(`Trip ${tripId}: no escrowId — nothing to refund`);
      return;
    }
    if (cancelledAfterCompletion("trips", before, after)) {
      await alertCancelAfterCompletion({ collection: "trips", orderId: tripId,
        idField: "tripId", escrowId, alertPrefix: "trip", before });
      return;
    }

    const reason =
      after.status === "cancelledByDriver"
        ? "driver_cancelled"
        : after.status === "noDrivers" || after.status === "noDriversAvailable" ||
            after.status === "expired"
          ? "no_drivers_found"
          : "passenger_cancelled";

    const refunded = await refundCancelledOrder({
      collection: "trips", orderId: tripId, idField: "tripId", escrowId, reason,
      alertPrefix: "trip", failedAlertType: "escrow_refund_failed",
      passengerId: after.passengerId, referenceType: "trip",
    });
    if (!refunded) return;

    // Tell the passenger only about a refund that actually happened.
    const passengerId = after.passengerId;
    if (passengerId) {
      try {
        const userDoc = await db().collection("users").doc(passengerId).get();
        const fcmToken = userDoc.data()?.fcmToken;
        if (fcmToken) {
          await admin.messaging().send({
            token: fcmToken,
            notification: {
              title: "Trip Cancelled — Refund Processed",
              body: `Your GH₵${(after.estimatedFare || 0).toFixed(2)} has been returned to your wallet.`,
            },
            data: { type: "trip_cancelled", route: "/wallet" },
          });
        }
      } catch (e) {
        console.error(`Trip ${tripId}: refund notification failed:`, e.message);
      }
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
    // The Driver and Passenger apps write "cancelled" (the driver adds
    // statusReason); the by-party statuses exist in the delivery model and
    // are treated the same, as the recovery sweep already does.
    if (!DELIVERY_CANCELLED_STATUSES.includes(after.status)) return;
    if (after.escrowRefunded === true) return;

    const escrowId = after.escrowId;
    if (!escrowId) return;
    if (cancelledAfterCompletion("deliveries", before, after)) {
      await alertCancelAfterCompletion({ collection: "deliveries", orderId: deliveryId,
        idField: "deliveryId", escrowId, alertPrefix: "delivery", before });
      return;
    }

    await refundCancelledOrder({
      collection: "deliveries", orderId: deliveryId, idField: "deliveryId",
      escrowId, reason: "delivery_cancelled", alertPrefix: "delivery",
      passengerId: after.passengerId, referenceType: "delivery",
    });
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
    // "failed" (service not performed) refunds like "cancelled", as the
    // recovery sweep already does.
    if (!GAS_CANCELLED_STATUSES.includes(after.status)) return;
    if (after.escrowRefunded === true) return;

    const escrowId = after.escrowId;
    if (!escrowId) return;
    if (cancelledAfterCompletion("gas_orders", before, after)) {
      await alertCancelAfterCompletion({ collection: "gas_orders", orderId,
        idField: "orderId", escrowId, alertPrefix: "gas", before });
      return;
    }

    await refundCancelledOrder({
      collection: "gas_orders", orderId, idField: "orderId",
      escrowId, reason: after.status === "failed" ? "gas_order_failed" : "gas_order_cancelled",
      alertPrefix: "gas",
      passengerId: after.passengerId, referenceType: "gas_order",
    });
  },
);
