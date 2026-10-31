// Observe-only validation of client-supplied delivery fares.
//
// The passenger app computes the delivery fare and the backend stores it
// as sent (estimatedFare); the wallet escrow holds the same client figure.
// This check recomputes a conservative MINIMUM fare on the server and
// records the result. It never rejects an order, changes a fare or an
// escrow, or refunds anything: it only records and alerts.
//
// Formula: parity with the passenger app's
// PricingService.deliveryFareBreakdown (lib/core/services/pricing_service.dart):
//   fare  = base(vehicle) + perKm(vehicle) × km + weight + fragile + helpers
//   total = fare < minimumFare(vehicle) ? minimumFare : round2(fare)
// Rates come from settings/platform → delivery.{okada|aboboya|miniTruck},
// falling back per value to the app's built-in defaults. The older server
// calculator in trips.js also falls back to flat delivery.baseFare /
// perKmRate / minimumFare keys, which the app never reads; when such a
// legacy flat format is present the lower of the two readings is used.
//
// Distance: the order stores no distance, and a client distance would not
// be trustworthy anyway. The server uses the straight-line (great-circle)
// distance between the stored pickup and drop-off, reduced by
// DISTANCE_SLACK. A road route is never shorter than that, so a legitimate
// fare (road distance, or the app's own straight-line fallback) is never
// below this minimum. It is a floor, not the expected price: a fare well
// under the road price but above the straight-line floor is not detected.

"use strict";

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

const db = () => admin.firestore();

const FORMULA_VERSION = 1;
/** Geodesic slack: the app measures on the WGS84 ellipsoid, this on a sphere. */
const DISTANCE_SLACK = 0.01;
/** Rounding slack in GHS between the app's and this calculation. */
const FARE_TOLERANCE = 0.01;

// The passenger app's built-in defaults (pricing_service.dart `_defaults`).
const VEHICLE_DEFAULTS = {
  okada: { baseFare: 5.0, perKmRate: 2.5, minimumFare: 10.0 },
  aboboya: { baseFare: 15.0, perKmRate: 4.0, minimumFare: 20.0 },
  miniTruck: { baseFare: 40.0, perKmRate: 7.0, minimumFare: 50.0 },
};
const SURCHARGE_DEFAULTS = {
  weightSurchargeSmall: 0.0,
  weightSurchargeMedium: 5.0,
  weightSurchargeLarge: 15.0,
  fragileItemSurcharge: 5.0,
  helperSurcharge: 10.0,
};

const round2 = (n) => Math.round(n * 100) / 100;
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

/**
 * The vehicle key the app uses, or null for a name the app never sends
 * ('Okada' / 'Aboboya' / 'Mini Truck').
 */
function vehicleKey(vehicleType) {
  if (typeof vehicleType !== "string") return null;
  switch (vehicleType.toLowerCase().replace(/ /g, "")) {
    case "okada": return "okada";
    case "aboboya": return "aboboya";
    case "minitruck": return "miniTruck";
    default: return null;
  }
}

/**
 * Rates for [vKey] read the way the app reads them, plus the legacy flat
 * reading when the settings carry flat delivery keys.
 */
function deliveryRates(settings, vKey) {
  const d = settings && typeof settings.delivery === "object" ? settings.delivery : {};
  const veh = d[vKey] && typeof d[vKey] === "object" ? d[vKey] : {};
  const def = VEHICLE_DEFAULTS[vKey];
  const pick = (field) => num(veh[field]) ?? def[field];
  const app = {
    baseFare: pick("baseFare"),
    perKmRate: pick("perKmRate"),
    minimumFare: pick("minimumFare"),
  };
  const surcharge = (field) => num(d[field]) ?? SURCHARGE_DEFAULTS[field];
  const surcharges = Object.fromEntries(
    Object.keys(SURCHARGE_DEFAULTS).map((k) => [k, surcharge(k)]));

  const flatKeys = ["baseFare", "perKmRate", "minimumFare"].filter((k) => num(d[k]) != null);
  const legacy = flatKeys.length > 0
    ? {
      baseFare: num(veh.baseFare) ?? num(d.baseFare) ?? def.baseFare,
      perKmRate: num(veh.perKmRate) ?? num(d.perKmRate) ?? def.perKmRate,
      minimumFare: num(veh.minimumFare) ?? num(d.minimumFare) ?? def.minimumFare,
    }
    : null;
  return { app, legacy, surcharges };
}

/** The app's delivery total for one set of rates. Pure. */
function deliveryTotal({ km, rates, surcharges, weightTier, isFragile, requiresHelpers }) {
  const tier = String(weightTier ?? "").toLowerCase();
  const weight = tier === "medium" ? surcharges.weightSurchargeMedium
    : tier === "large" ? surcharges.weightSurchargeLarge
      : surcharges.weightSurchargeSmall; // small, bulk and anything else
  const fragile = isFragile === true ? surcharges.fragileItemSurcharge : 0;
  const helpers = requiresHelpers === true ? surcharges.helperSurcharge : 0;
  const fare = rates.baseFare + rates.perKmRate * km + weight + fragile + helpers;
  return fare < rates.minimumFare ? rates.minimumFare : round2(fare);
}

/** Great-circle distance in km (mean Earth radius). */
function straightLineKm(a, b) {
  const R = 6371.0088;
  const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(b.latitude - a.latitude);
  const dLng = rad(b.longitude - a.longitude);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(a.latitude)) * Math.cos(rad(b.latitude)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

const isPoint = (p) => p != null && num(p.latitude) != null && num(p.longitude) != null &&
  Math.abs(p.latitude) <= 90 && Math.abs(p.longitude) <= 180 &&
  !(p.latitude === 0 && p.longitude === 0);

/**
 * Assesses one delivery order. Pure.
 * @returns {{status: "ok"|"below_minimum"|"insufficient_data", reason: string,
 *   formulaVersion: number, clientFare?: number, serverMinimumFare?: number,
 *   straightLineKm?: number, vehicleKey?: string, settingsFormat?: string}}
 */
function assessDeliveryFare(order, settings) {
  const base = { formulaVersion: FORMULA_VERSION, method: "straight_line_minimum" };
  if (!settings || typeof settings !== "object") {
    return { ...base, status: "insufficient_data", reason: "pricing_settings_unavailable" };
  }
  const clientFare = num(order?.estimatedFare);
  if (clientFare == null || clientFare <= 0) {
    return { ...base, status: "insufficient_data", reason: "fare_missing_or_invalid" };
  }
  if (!isPoint(order.pickupLocation) || !isPoint(order.dropoffLocation)) {
    return { ...base, status: "insufficient_data", reason: "locations_missing_or_invalid", clientFare };
  }
  const vKey = vehicleKey(order.vehicleType);
  if (!vKey) {
    return { ...base, status: "insufficient_data", reason: "unknown_vehicle_type", clientFare };
  }

  const km = straightLineKm(order.pickupLocation, order.dropoffLocation);
  const minKm = km * (1 - DISTANCE_SLACK);
  const { app, legacy, surcharges } = deliveryRates(settings, vKey);
  const inputs = {
    km: minKm, surcharges,
    weightTier: order.weightTier,
    isFragile: order.isFragile,
    requiresHelpers: order.requiresHelpers,
  };
  const appMin = deliveryTotal({ ...inputs, rates: app });
  const serverMinimumFare = legacy
    ? Math.min(appMin, deliveryTotal({ ...inputs, rates: legacy }))
    : appMin;

  const result = {
    ...base,
    clientFare,
    serverMinimumFare,
    straightLineKm: round2(km),
    vehicleKey: vKey,
    settingsFormat: legacy ? "legacy_flat_present" : "per_vehicle",
  };
  return clientFare + FARE_TOLERANCE < serverMinimumFare
    ? { ...result, status: "below_minimum", reason: "fare_below_straight_line_minimum" }
    : { ...result, status: "ok", reason: "fare_at_or_above_minimum" };
}

async function readSettings() {
  try {
    const snap = await db().collection("settings").doc("platform").get();
    return snap.exists ? snap.data() : null;
  } catch (_) {
    return null;
  }
}

/**
 * Records the assessment for [deliveryId] once. The check document and any
 * alert are written in one batch with create(), so a retried trigger finds
 * the check already there and writes nothing. Returns the assessment, or
 * null when it had already been recorded.
 */
async function recordDeliveryFareCheck(deliveryId, order) {
  const assessment = assessDeliveryFare(order, await readSettings());
  const batch = db().batch();
  batch.create(db().collection("deliveryFareChecks").doc(deliveryId), {
    deliveryId,
    ...assessment,
    checkedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  if (assessment.status === "below_minimum") {
    // No personal data: ids and amounts only.
    batch.set(db().collection("admin_alerts").doc(), {
      type: "delivery_fare_below_minimum",
      deliveryId,
      clientFare: assessment.clientFare,
      serverMinimumFare: assessment.serverMinimumFare,
      vehicleKey: assessment.vehicleKey,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  try {
    await batch.commit();
  } catch (e) {
    if (e.code === 6 || /already exists/i.test(e.message ?? "")) return null;
    throw e;
  }
  if (assessment.status !== "ok") {
    console.warn(`Delivery ${deliveryId}: fare check ${assessment.status} (${assessment.reason})`);
  }
  return assessment;
}

exports.onDeliveryFareValidation = onDocumentCreated(
  { region: "europe-west2", document: "deliveries/{deliveryId}" },
  async (event) => {
    const order = event.data?.data();
    if (!order) return;
    try {
      await recordDeliveryFareCheck(event.params.deliveryId, order);
    } catch (e) {
      // Observe-only: a failed check never affects the order.
      console.error(`Delivery ${event.params.deliveryId}: fare check failed:`, e.message);
    }
  },
);

exports.assessDeliveryFare = assessDeliveryFare;
exports.deliveryTotal = deliveryTotal;
exports.deliveryRates = deliveryRates;
exports.straightLineKm = straightLineKm;
exports.vehicleKey = vehicleKey;
exports.recordDeliveryFareCheck = recordDeliveryFareCheck;
exports.FORMULA_VERSION = FORMULA_VERSION;
