// Server-owned Delivery quotes (delivery_pricing.js prices them).
//
// quoteDelivery (callable, Passenger 1.0.1+): validates the endpoints and
// package, measures the road route on the server, prices it from the
// approved rate card and stores an immutable quote in delivery_quotes/{id}
// (Admin SDK only; the customer may read their own). It returns the quote id,
// itemised price and expiry. Any failure (no routing key, provider error or
// timeout, no route, missing/malformed rates) returns no price.
//
// An order references its quote (deliveries.deliveryQuoteId). onDeliveryCreated runs
// verifyAndStampDeliveryPrice before anything is offered or paid out: the
// quote must be the customer's, unexpired when the order was created, unused
// by any other order, for exactly the order's endpoints, vehicle and
// package, at exactly the order's estimatedFare, and the current rate card
// must still give the same total for the quote's measured distance (else
// "price_changed": the customer re-quotes and confirms). The quote is then
// marked used by this order and the price stamped on it as verifiedPrice,
// which offers, acceptance, hold linking and settlement use.
//
// Orders without a quote (Passenger 1.0.0) are refused unless the owner has
// explicitly allowed them for the rollout window
// (app_config/pricing.legacyUnquotedDeliveries === true; server-only, absent =
// refused); then only cash ones reaching the straight-line floor are offered,
// stamped "delivery-legacy-floor" (never wallet).
"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const pricing = require("./delivery_pricing");
const { deliveryFareFloor } = require("./payment_verification");

// Google Maps Platform key with the Routes API enabled, server-side only:
//   firebase functions:secrets:set ROUTES_API_KEY --project <projectId>
const ROUTES_API_KEY = defineSecret("ROUTES_API_KEY");

const getDb = () => admin.firestore();
const QUOTES = "delivery_quotes";
const LEGACY_VERSION = "delivery-legacy-floor";

let routeProvider = (pickup, dropoff) =>
  pricing.googleRouteDistance(pickup, dropoff, { apiKey: ROUTES_API_KEY.value() });

/**
 * Road distance between two validated points from the routing provider
 * (Google Routes API v2; the test hook below replaces it). Throws
 * pricing.RoutingError on any failure; never estimates. Shared with
 * supplier Gas quotes (gas_supplier_orders.js).
 */
async function measureRoute(pickup, dropoff) {
  const route = await routeProvider(pickup, dropoff);
  if (!Number.isInteger(route?.distanceMeters) || route.distanceMeters < 0) {
    throw new pricing.RoutingError("route_distance_invalid");
  }
  return route;
}

/** Tests only: replace the routing provider (null restores Google Routes). */
function _setRouteProviderForTests(fn) {
  routeProvider = fn ?? ((p, d) => pricing.googleRouteDistance(p, d, { apiKey: ROUTES_API_KEY.value() }));
}

const toGhs = (p) => p / 100;

/** The quote returned to the app (amounts in GHS, as the app displays them). */
function quoteView(id, q) {
  return {
    quoteId: id,
    pricingVersion: q.pricingVersion,
    vehicleType: q.vehicleType,
    distanceKm: q.distanceMeters / 1000,
    durationMinutes: q.durationSeconds == null ? null : Math.ceil(q.durationSeconds / 60),
    baseFare: toGhs(q.items.base),
    distanceCharge: toGhs(q.items.distance),
    weightSurcharge: toGhs(q.items.weight),
    fragileSurcharge: toGhs(q.items.fragile),
    helperSurcharge: toGhs(q.items.helpers),
    minimumFare: toGhs(q.minimumPesewas),
    minimumApplied: q.minimumApplied,
    total: toGhs(q.totalPesewas),
    expiresAtMillis: q.expiresAt.toMillis(),
  };
}

/**
 * Prices and stores a quote for [uid]. Throws HttpsError on any invalid
 * input or when no verified price can be produced.
 */
async function createQuote(uid, data) {
  const pickup = pricing.validPoint(data?.pickup);
  const dropoff = pricing.validPoint(data?.dropoff);
  if (!pickup || !dropoff) throw new HttpsError("invalid-argument", "Invalid pickup or drop-off.", { reason: "point_invalid" });
  const vKey = pricing.vehicleKey(data?.vehicleType);
  const inputs = { vehicleKey: vKey, weightTier: data?.weightTier, isFragile: data?.isFragile,
    requiresHelpers: data?.requiresHelpers };
  const problem = pricing.inputProblem(inputs);
  if (problem) throw new HttpsError("invalid-argument", "This parcel cannot be priced.", { reason: problem });

  const settingsSnap = await getDb().collection("settings").doc("platform").get();
  const rc = pricing.readRateCard(settingsSnap.exists ? settingsSnap.data() : null);
  if (!rc.ok) {
    console.error(`quoteDelivery: rate card unusable (${rc.reason})`);
    throw new HttpsError("failed-precondition", "Delivery prices are unavailable right now.", { reason: "pricing_unavailable" });
  }

  let route;
  try {
    route = await routeProvider(pickup, dropoff);
  } catch (e) {
    const reason = e instanceof pricing.RoutingError ? e.reason : "routing_failed";
    console.warn(`quoteDelivery: no route (${reason})`); // no coordinates logged
    throw new HttpsError("unavailable", "We couldn't measure this route. Please try again.", { reason });
  }
  if (!Number.isInteger(route?.distanceMeters) || route.distanceMeters < 0) {
    throw new HttpsError("unavailable", "We couldn't measure this route. Please try again.",
      { reason: "route_distance_invalid" });
  }

  const price = pricing.priceDelivery({ ...inputs, distanceMeters: route.distanceMeters }, rc.card);
  if (!price.ok) throw new HttpsError("invalid-argument", "This parcel cannot be priced.", { reason: price.reason });

  const now = admin.firestore.Timestamp.now();
  const q = {
    passengerId: uid,
    pricingVersion: pricing.PRICING_VERSION,
    rateCardVersion: rc.version,
    routeProvider: pricing.ROUTE_PROVIDER,
    pickup: new admin.firestore.GeoPoint(pickup.latitude, pickup.longitude),
    dropoff: new admin.firestore.GeoPoint(dropoff.latitude, dropoff.longitude),
    vehicleKey: vKey,
    vehicleType: pricing.VEHICLES[vKey].name,
    weightTier: inputs.weightTier,
    isFragile: inputs.isFragile,
    requiresHelpers: inputs.requiresHelpers,
    distanceMeters: route.distanceMeters,
    durationSeconds: route.durationSeconds ?? null,
    items: price.items,
    subtotalPesewas: price.subtotal,
    minimumPesewas: price.minimum,
    minimumApplied: price.minimumApplied,
    totalPesewas: price.total,
    commissionPesewas: price.commission,
    driverNetPesewas: price.driverNet,
    feeBasisPoints: rc.card.feeBasisPoints,
    createdAt: now,
    expiresAt: admin.firestore.Timestamp.fromMillis(now.toMillis() + pricing.QUOTE_TTL_MS),
    usedBy: null,
  };
  const ref = getDb().collection(QUOTES).doc();
  await ref.create(q);
  return quoteView(ref.id, q);
}

const quoteDelivery = onCall({ region: "europe-west2", secrets: [ROUTES_API_KEY] }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  return createQuote(uid, request.data);
});

const sameGeo = (a, b) => !!a && !!b && a.latitude === b.latitude && a.longitude === b.longitude;
const toPesewas = (v) => (typeof v === "number" && Number.isFinite(v) ? pricing.pesewas(v) : null);

/**
 * Why [order] may not use [quote] (both as stored), or null. Pure.
 * [rc] is the current rate card (readRateCard result).
 */
function quoteProblem(orderId, order, quote, rc, nowMillis) {
  if (!quote) return "quote_invalid";
  if (quote.pricingVersion !== pricing.PRICING_VERSION || quote.passengerId !== order.passengerId) return "quote_invalid";
  if (quote.usedBy != null && quote.usedBy !== orderId) return "quote_reused";
  const created = order.createdAt?.toMillis?.() ?? nowMillis;
  if (created > quote.expiresAt.toMillis()) return "quote_expired";
  if (pricing.vehicleKey(order.vehicleType) !== quote.vehicleKey || order.weightTier !== quote.weightTier ||
      (order.isFragile ?? false) !== quote.isFragile || (order.requiresHelpers ?? false) !== quote.requiresHelpers ||
      !sameGeo(order.pickupLocation, quote.pickup) || !sameGeo(order.dropoffLocation, quote.dropoff)) {
    return "quote_mismatch";
  }
  if (toPesewas(order.estimatedFare) !== quote.totalPesewas) return "price_mismatch";
  // The approved price must still be what the customer saw.
  if (!rc.ok) return "pricing_unavailable";
  const now = pricing.priceDelivery({ distanceMeters: quote.distanceMeters, vehicleKey: quote.vehicleKey,
    weightTier: quote.weightTier, isFragile: quote.isFragile, requiresHelpers: quote.requiresHelpers }, rc.card);
  if (rc.version !== quote.rateCardVersion || !now.ok || now.total !== quote.totalPesewas) return "price_changed";
  return null;
}

/** The verifiedPrice stamp for a delivery priced by [quoteId]. Pure. */
function quoteStamp(quoteId, q) {
  return {
    version: pricing.PRICING_VERSION, quoteId, rateCardVersion: q.rateCardVersion,
    distanceMeters: q.distanceMeters, totalPesewas: q.totalPesewas, total: q.totalPesewas / 100,
    commissionPesewas: q.commissionPesewas, commission: q.commissionPesewas / 100,
    driverNetPesewas: q.driverNetPesewas, driverNet: q.driverNetPesewas / 100,
  };
}

/** The order's delivery stamp when it still describes the order, else null. Pure. */
function stampedDeliveryPrice(order) {
  const v = order?.verifiedPrice;
  if (!v || typeof v !== "object") return null;
  if (v.version !== pricing.PRICING_VERSION && v.version !== LEGACY_VERSION) return null;
  if (toPesewas(order.estimatedFare) !== v.totalPesewas) return null;
  return v;
}

/**
 * Verifies a new delivery's price and stamps it, in one transaction on the
 * order, its quote and the settings as they are now (a retry finds its own
 * stamp and agrees; two orders naming one quote: the first wins).
 * @returns {{ok: true} | {ok: false, reason}} reason "order_not_open" = nothing to do.
 */
async function verifyAndStampDeliveryPrice(deliveryId) {
  const db = getDb();
  const ref = db.collection("deliveries").doc(deliveryId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const o = snap.exists ? snap.data() : null;
    if (!o || o.status !== "pending" || o.driverId != null) return { ok: false, reason: "order_not_open" };
    if (stampedDeliveryPrice(o)) return { ok: true };

    if (typeof o.deliveryQuoteId !== "string" || !o.deliveryQuoteId || o.deliveryQuoteId.includes("/")) {
      if (o.deliveryQuoteId != null) return { ok: false, reason: "quote_invalid" };
      const cfg = await tx.get(db.collection("app_config").doc("pricing"));
      if (cfg.data()?.legacyUnquotedDeliveries !== true) return { ok: false, reason: "quote_required" };
      if (o.paymentMethod === "wallet") return { ok: false, reason: "quote_required" };
      const settings = await tx.get(db.collection("settings").doc("platform"));
      const floor = deliveryFareFloor(o, settings.exists ? settings.data() : null);
      const fare = toPesewas(o.estimatedFare);
      if (floor == null || fare == null || fare < pricing.pesewas(floor)) return { ok: false, reason: "price_below_minimum" };
      tx.update(ref, { verifiedPrice: { version: LEGACY_VERSION, totalPesewas: fare, total: fare / 100,
        verifiedAt: admin.firestore.FieldValue.serverTimestamp() } });
      return { ok: true };
    }

    const quoteRef = db.collection(QUOTES).doc(o.deliveryQuoteId);
    const [quoteSnap, settings] = await Promise.all([tx.get(quoteRef), tx.get(db.collection("settings").doc("platform"))]);
    const q = quoteSnap.exists ? quoteSnap.data() : null;
    const rc = pricing.readRateCard(settings.exists ? settings.data() : null);
    const problem = quoteProblem(deliveryId, o, q, rc, Date.now());
    if (problem) return { ok: false, reason: problem };
    tx.update(quoteRef, { usedBy: deliveryId, usedAt: admin.firestore.FieldValue.serverTimestamp() });
    tx.update(ref, { verifiedPrice: { ...quoteStamp(o.deliveryQuoteId, q), verifiedAt: admin.firestore.FieldValue.serverTimestamp() } });
    return { ok: true };
  });
}

/**
 * Whether a wallet hold of [escrowAmount] may pay [order] given its [quote]
 * (read by the caller in its transaction). Pure.
 */
function quotedHoldProblem(order, quote, escrowAmount, orderId) {
  if (typeof order?.deliveryQuoteId !== "string" || !quote) return "quote_required";
  if (quote.pricingVersion !== pricing.PRICING_VERSION || quote.passengerId !== order.passengerId) return "quote_invalid";
  if (quote.usedBy != null && quote.usedBy !== orderId) return "quote_reused";
  if (toPesewas(order.estimatedFare) !== quote.totalPesewas) return "price_mismatch";
  if (toPesewas(escrowAmount) !== quote.totalPesewas) return "hold_amount_mismatch";
  return null;
}

module.exports = {
  ROUTES_API_KEY, QUOTES, LEGACY_VERSION, quoteDelivery, createQuote, measureRoute, quoteView, quoteProblem, quoteStamp,
  stampedDeliveryPrice, verifyAndStampDeliveryPrice, quotedHoldProblem, _setRouteProviderForTests,
};
