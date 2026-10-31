// Delivery price authority: road-route distance from a trusted routing
// provider, the approved rate card from settings/platform.delivery, integer
// pesewas. Used by quoteDelivery (delivery_quotes.js), the order check in
// onDeliveryCreated, hold linking (escrow.js) and settlement (trips.js).
//
// Formula (PRICING_VERSION "delivery-v2"), all amounts in integer pesewas:
//   distance  = routes[0].distanceMeters from Google Routes API v2
//               (computeRoutes, DRIVE, TRAFFIC_UNAWARE), whole metres as
//               returned — never rounded to km, never a client value
//   distanceCharge = round_half_up(perKm × distanceMeters / 1000)
//   subtotal  = base + distanceCharge + weight(tier) + fragile? + helpers?
//   total     = subtotal < minimum ? minimum : subtotal
//   commission = round_half_up(total × platformFeePercent / 100); driverNet = total − commission
// This is the Passenger App's approved formula (PricingService.
// deliveryFareBreakdown: base + perKm × km + weight + fragile + helpers,
// replaced by the vehicle minimum when below it), computed on the server.
// Rates are converted from GHS to pesewas once (round half up to the pesewa).
//
// Rate card: settings/platform.delivery.{okada|aboboya|miniTruck}.{baseFare,
// perKmRate, minimumFare} and delivery.{weightSurchargeSmall, Medium, Large,
// fragileItemSurcharge, helperSurcharge}. Every value must be present and a
// finite non-negative number (or numeric string); minimumFare and perKmRate
// must be positive. Unlike the app there is NO built-in fallback: missing or
// malformed configuration means no quote. Weight tiers: Small → Okada;
// Medium, Large → Aboboya; Bulk → Mini Truck (dispatch_policy.js); Bulk takes
// the Small weight surcharge, as in the app.
"use strict";

const crypto = require("crypto");
const { configNumber, platformFeePercent } = require("./gas_pricing");

const PRICING_VERSION = "delivery-v2";
const ROUTE_PROVIDER = "google-routes-v2";
const ROUTES_URL = "https://routes.googleapis.com/directions/v2:computeRoutes";
const ROUTE_TIMEOUT_MS = 8000;
/** How long a quote may be used to place an order. */
const QUOTE_TTL_MS = 10 * 60 * 1000;

const VEHICLES = Object.freeze({
  okada: { name: "Okada", tiers: ["Small"] },
  aboboya: { name: "Aboboya", tiers: ["Medium", "Large"] },
  miniTruck: { name: "Mini Truck", tiers: ["Bulk"] },
});
const WEIGHT_TIERS = Object.freeze(["Small", "Medium", "Large", "Bulk"]);
const SURCHARGE_KEYS = Object.freeze(["weightSurchargeSmall", "weightSurchargeMedium",
  "weightSurchargeLarge", "fragileItemSurcharge", "helperSurcharge"]);

/** 'Okada' / 'Aboboya' / 'Mini Truck' (any case/spacing) → key, or null. Pure. */
function vehicleKey(vehicleType) {
  if (typeof vehicleType !== "string") return null;
  switch (vehicleType.toLowerCase().replace(/[\s_]/g, "")) {
    case "okada": return "okada";
    case "aboboya": return "aboboya";
    case "minitruck": return "miniTruck";
    default: return null;
  }
}

/** GHS → integer pesewas, half up. Pure. */
const pesewas = (ghs) => Math.round(ghs * 100 + Number.EPSILON);
/** a × b / d rounded half up, for non-negative integers. Pure. */
const mulDivHalfUp = (a, b, d) => Math.floor((a * b * 2 + d) / (2 * d));

/**
 * The approved rate card in pesewas, or {ok: false, reason}. Pure.
 * reason: delivery_config_missing | delivery_rate_invalid:<path> | platform_fee_invalid
 */
function readRateCard(settings) {
  const d = settings?.delivery;
  if (!d || typeof d !== "object" || Array.isArray(d)) return { ok: false, reason: "delivery_config_missing" };
  const vehicles = {};
  for (const key of Object.keys(VEHICLES)) {
    const v = d[key];
    if (!v || typeof v !== "object") return { ok: false, reason: `delivery_rate_invalid:${key}` };
    const base = configNumber(v.baseFare, undefined);
    const perKm = configNumber(v.perKmRate, undefined);
    const min = configNumber(v.minimumFare, undefined);
    if (base === undefined || !(perKm > 0) || !(min > 0)) {
      return { ok: false, reason: `delivery_rate_invalid:${key}` };
    }
    vehicles[key] = { base: pesewas(base), perKm: pesewas(perKm), minimum: pesewas(min) };
  }
  const surcharges = {};
  for (const k of SURCHARGE_KEYS) {
    const v = configNumber(d[k], undefined);
    if (v === undefined) return { ok: false, reason: `delivery_rate_invalid:${k}` };
    surcharges[k] = pesewas(v);
  }
  const pct = platformFeePercent(settings);
  if (pct === undefined) return { ok: false, reason: "platform_fee_invalid" };
  const card = { vehicles, surcharges, feeBasisPoints: Math.round(pct * 100) };
  const version = crypto.createHash("sha256").update(JSON.stringify(card)).digest("hex").slice(0, 16);
  return { ok: true, card, version };
}

/**
 * Why these package inputs cannot be priced, or null. Pure.
 */
function inputProblem({ vehicleKey: vKey, weightTier, isFragile, requiresHelpers }) {
  if (!WEIGHT_TIERS.includes(weightTier)) return "weight_tier_invalid";
  if (!vKey || !VEHICLES[vKey]) return "vehicle_invalid";
  if (!VEHICLES[vKey].tiers.includes(weightTier)) return "vehicle_not_eligible";
  if (typeof isFragile !== "boolean" || typeof requiresHelpers !== "boolean") return "options_invalid";
  return null;
}

/**
 * The itemised price in pesewas for a measured route. Pure.
 * @returns {{ok: true, ...} | {ok: false, reason}}
 */
function priceDelivery({ distanceMeters, vehicleKey: vKey, weightTier, isFragile, requiresHelpers }, card) {
  const problem = inputProblem({ vehicleKey: vKey, weightTier, isFragile, requiresHelpers });
  if (problem) return { ok: false, reason: problem };
  if (!Number.isInteger(distanceMeters) || distanceMeters < 0) return { ok: false, reason: "distance_invalid" };
  const r = card.vehicles[vKey];
  const s = card.surcharges;
  const weight = weightTier === "Medium" ? s.weightSurchargeMedium
    : weightTier === "Large" ? s.weightSurchargeLarge : s.weightSurchargeSmall;
  const items = {
    base: r.base,
    distance: mulDivHalfUp(r.perKm, distanceMeters, 1000),
    weight,
    fragile: isFragile ? s.fragileItemSurcharge : 0,
    helpers: requiresHelpers ? s.helperSurcharge : 0,
  };
  const subtotal = items.base + items.distance + items.weight + items.fragile + items.helpers;
  const minimumApplied = subtotal < r.minimum;
  const total = minimumApplied ? r.minimum : subtotal;
  const commission = mulDivHalfUp(total, card.feeBasisPoints, 10000);
  return { ok: true, items, subtotal, minimum: r.minimum, minimumApplied, total,
    commission, driverNet: total - commission };
}

/** A usable {latitude, longitude} (finite, in range, not 0,0), or null. Pure. */
function validPoint(p) {
  const lat = p?.latitude;
  const lng = p?.longitude;
  if (typeof lat !== "number" || typeof lng !== "number" || !Number.isFinite(lat) || !Number.isFinite(lng) ||
      Math.abs(lat) > 90 || Math.abs(lng) > 180 || (lat === 0 && lng === 0)) {
    return null;
  }
  return { latitude: lat, longitude: lng };
}

class RoutingError extends Error {
  constructor(reason) {
    super(reason);
    this.name = "RoutingError";
    this.reason = reason;
  }
}

/**
 * Road distance from Google Routes API v2. Throws RoutingError with reason
 * routing_not_configured | routing_timeout | routing_http_<status> |
 * routing_failed | route_unavailable | route_distance_invalid. Never returns
 * an estimate.
 */
async function googleRouteDistance(pickup, dropoff, { apiKey, fetchImpl = fetch, timeoutMs = ROUTE_TIMEOUT_MS } = {}) {
  if (typeof apiKey !== "string" || !apiKey) throw new RoutingError("routing_not_configured");
  const point = (p) => ({ location: { latLng: { latitude: p.latitude, longitude: p.longitude } } });
  let res;
  try {
    res = await fetchImpl(ROUTES_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Goog-Api-Key": apiKey,
        "X-Goog-FieldMask": "routes.distanceMeters,routes.duration" },
      body: JSON.stringify({ origin: point(pickup), destination: point(dropoff), travelMode: "DRIVE",
        routingPreference: "TRAFFIC_UNAWARE", units: "METRIC" }),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (e) {
    throw new RoutingError(e?.name === "TimeoutError" || e?.name === "AbortError" ? "routing_timeout" : "routing_failed");
  }
  if (!res.ok) throw new RoutingError(`routing_http_${res.status}`);
  let body;
  try {
    body = await res.json();
  } catch (_) {
    throw new RoutingError("routing_failed");
  }
  const route = Array.isArray(body?.routes) ? body.routes[0] : null;
  if (!route) throw new RoutingError("route_unavailable");
  // Routes API omits distanceMeters when it is 0 (same point).
  const meters = route.distanceMeters ?? (route.duration ? 0 : undefined);
  if (!Number.isInteger(meters) || meters < 0) throw new RoutingError("route_distance_invalid");
  const seconds = typeof route.duration === "string" ? Number.parseInt(route.duration, 10) : null;
  return { distanceMeters: meters, durationSeconds: Number.isFinite(seconds) ? seconds : null };
}

module.exports = {
  PRICING_VERSION, ROUTE_PROVIDER, ROUTES_URL, QUOTE_TTL_MS, VEHICLES, WEIGHT_TIERS, SURCHARGE_KEYS,
  vehicleKey, pesewas, mulDivHalfUp, readRateCard, inputProblem, priceDelivery, validPoint,
  RoutingError, googleRouteDistance,
};
