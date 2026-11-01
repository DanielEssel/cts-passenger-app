"use strict";

/**
 * Gas supplier orders: server-authoritative options, quotes and orders.
 *
 * Supplier records (gas_suppliers, written by the admin dashboard) are
 * staff-only. Passengers reach them only through these callables, which
 * return the minimum needed to choose and price an order:
 *
 *   listGasSupplierOptions   eligible supplier/station/product options near
 *                            a location, with current prices.
 *   quoteGasSupplierOrder    a priced quote for one option, stored
 *                            server-side (gas_quotes) for QUOTE_TTL_MS.
 *   createGasSupplierOrder   turns an unexpired quote into an order with an
 *                            immutable price snapshot. One order per quote:
 *                            a retried or duplicate call returns the same
 *                            order.
 *
 * Nothing the client sends is used as a price, fee or total: requests carry
 * ids, the order type, size, quantity and the customer's location only, and
 * a request with any other field is refused.
 *
 * Integration boundary (deliberate): orders are written to
 * gas_supplier_orders with status "awaiting_payment", not to gas_orders.
 * Nothing dispatches, accepts, pays for or settles them yet:
 *   - onGasOrderCreated offers every gas_orders document to drivers, and
 *     no driver may be offered an LPG job before LPG eligibility exists;
 *   - Gas holds are not price-checked when attached, and completion pays
 *     the driver the whole escrow less the platform fee, which would hand
 *     the supplier's product money to the driver.
 * Payment, dispatch and fulfilment are gas_supplier_fulfilment.js (gated
 * off); the hold must equal priceSnapshot.total (holdMatchesSnapshot).
 *
 * Commission is not part of the price. The customer pays product subtotal
 * + supplier handling fee + delivery fee, and nothing else. Each order is
 * created with its financial allocation (gas_settlement_ledger.js
 * computeAllocation) in the same transaction, at the commission terms then
 * current; without usable approved terms no quote or order is made.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { validPoint, distanceKm } = require("./dispatch_policy");
const { configNumber } = require("./gas_pricing");
const { mulDivHalfUp, pesewas, RoutingError, ROUTE_PROVIDER } = require("./delivery_pricing");
const { measureRoute, ROUTES_API_KEY } = require("./delivery_quotes");
const { TERMS_DOC, termsProblem, computeAllocation, allocationRef } = require("./gas_settlement_ledger");

const db = () => admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const ORDER_TYPES = Object.freeze(["exchangeEmpty", "newCylinder", "pickupAndReturn", "commercialBulk"]);
const CYLINDER_SIZES = Object.freeze(["kg3", "kg6", "kg12_5", "kg14_5", "kg19", "kg45"]);

/** How long a quote may be turned into an order. */
const QUOTE_TTL_MS = 10 * 60 * 1000;
/** Upper bound on cylinders per order (a safety limit, not a business rule). */
const MAX_QUANTITY = 20;
/**
 * Bump when the quote calculation changes; stored on every snapshot.
 * 2: the delivery fee is priced on the server-measured road distance
 * (station → customer, delivery_quotes.js measureRoute) in pesewas; it was
 * the straight-line distance.
 * 3: product, handling and total are summed in whole pesewas (exact).
 */
const PRICING_RULES_VERSION = 3;

// The passenger app's built-in Gas delivery defaults (pricing_service.dart),
// used when settings/platform.gas lacks a value, as the app does.
const GAS_DELIVERY_DEFAULTS = Object.freeze({ baseFare: 8.0, perKm: 2.0, minDeliveryFee: 12.0, roundTripFee: 30.0 });

const round2 = (n) => Math.round(n * 100) / 100;
const isMoney = (v) => typeof v === "number" && Number.isFinite(v) && Math.round(v * 100) / 100 === v;

// ── Pure rules (exported for tests) ──────────────────────────────────────────

/** Why the request itself is unusable, or null. */
function requestProblem({ orderType, cylinderSize, quantity, location }) {
  if (!ORDER_TYPES.includes(orderType)) return "unsupported_order_type";
  if (!CYLINDER_SIZES.includes(cylinderSize)) return "unsupported_cylinder_size";
  if (quantity !== undefined && !(Number.isInteger(quantity) && quantity >= 1 && quantity <= MAX_QUANTITY)) {
    return "invalid_quantity";
  }
  if (!validPoint(location)) return "invalid_location";
  return null;
}

/**
 * Why this supplier / station / product cannot serve the request, or null.
 * The same conditions as the admin readiness checklist, plus service area.
 */
function optionProblem({ supplierId, supplier, stationId, station, productId, product }, { orderType, cylinderSize, location }) {
  if (!supplier) return "supplier_not_found";
  if (supplier.status !== "approved") return "supplier_not_approved";
  if (supplier.ordersEnabled !== true) return "supplier_orders_disabled";
  if (supplier.fulfillment?.[orderType] !== true) return "supplier_does_not_offer_order_type";
  if (!supplier.riderArrangement || supplier.riderArrangement === "undecided") return "supplier_rider_arrangement_undecided";
  // Dispatch assigns CTSGo drivers only (gas_supplier_fulfilment.js): a
  // supplier relying solely on its own riders would take orders nobody can
  // deliver.
  if (supplier.riderArrangement === "supplier_riders") return "supplier_riders_not_supported";

  if (!station) return "station_not_found";
  if (station.supplierId !== supplierId) return "station_supplier_mismatch";
  if (station.status !== "verified") return "station_not_verified";
  if (!validPoint(station.location)) return "station_location_invalid";
  if (station.fulfillment?.[orderType] !== true) return "station_does_not_offer_order_type";
  if (!Array.isArray(station.supportedSizes) || !station.supportedSizes.includes(cylinderSize)) return "station_does_not_handle_size";
  const radius = station.serviceRadiusKm;
  if (!(typeof radius === "number" && radius > 0)) return "station_service_area_undefined";
  if (!(distanceKm(station.location, location) <= radius)) return "outside_service_area";

  if (!product) return "product_not_found";
  if (product.orderType !== orderType || product.cylinderSize !== cylinderSize) return "product_mismatch";
  if (productId !== `${product.orderType}_${product.cylinderSize}_${product.brand}`) return "product_mismatch";
  if (product.verified !== true) return "product_not_verified";
  if (product.availability !== "available") return "product_unavailable";
  if (!isMoney(product.price) || product.price <= 0) return "product_price_invalid";
  if (!isMoney(product.handlingFee ?? 0) || (product.handlingFee ?? 0) < 0) return "product_price_invalid";
  if (product.currency !== "GHS") return "product_price_invalid";
  if (!Number.isInteger(product.priceVersion) || product.priceVersion < 1) return "product_price_invalid";
  return null;
}

/**
 * The Gas delivery rates (settings/platform.gas), read as gas_pricing.js
 * reads them: a missing value uses the app's built-in rate; a number or
 * numeric string is used; anything else makes the rates unusable (null).
 */
function gasDeliverySettings(settings) {
  const gas = settings?.gas;
  if (gas != null && (typeof gas !== "object" || Array.isArray(gas))) return null;
  const pick = (k) => configNumber(gas?.[k], GAS_DELIVERY_DEFAULTS[k]);
  const d = { baseFare: pick("baseFare"), perKm: pick("perKm"), minDeliveryFee: pick("minDeliveryFee"), roundTripFee: pick("roundTripFee") };
  return Object.values(d).some((v) => v === undefined) ? null : d;
}

/**
 * The authoritative price. Product amounts come from the verified catalog;
 * delivery uses the existing Gas delivery formula (gas_pricing.dart) on the
 * road distance from the station to the customer measured on the server
 * ([routeMeters], whole metres), in pesewas:
 *   fee = max(minDeliveryFee, baseFare + round_half_up(perKm × metres × legs / 1000)) (+ roundTripFee)
 * Pickup & Return is two legs plus the round-trip fee. Commission belongs to
 * settlement (gas_settlement_ledger.js). Throws when the rates are unusable.
 */
function computeQuote({ product, quantity, orderType, routeMeters, settings }) {
  const d = gasDeliverySettings(settings);
  if (!d) throw new HttpsError("failed-precondition", "Gas delivery prices are unavailable right now.", { reason: "pricing_unavailable" });
  if (!Number.isInteger(routeMeters) || routeMeters < 0) {
    throw new HttpsError("unavailable", "We couldn't measure the delivery route.", { reason: "route_distance_invalid" });
  }
  const legs = orderType === "pickupAndReturn" ? 2 : 1;
  const r = { base: pesewas(d.baseFare), perKm: pesewas(d.perKm), min: pesewas(d.minDeliveryFee), roundTrip: pesewas(d.roundTripFee) };
  let feeP = Math.max(r.min, r.base + mulDivHalfUp(r.perKm, routeMeters * legs, 1000));
  if (orderType === "pickupAndReturn") feeP += r.roundTrip;
  const km = routeMeters / 1000;
  const unitPrice = product.price;
  const unitHandlingFee = product.handlingFee ?? 0;
  // Whole pesewas: the line amounts are exactly unit × quantity and the
  // total is exactly their sum (settlement checks both).
  const productP = pesewas(unitPrice) * quantity;
  const handlingP = pesewas(unitHandlingFee) * quantity;
  return {
    currency: "GHS",
    unitPrice,
    unitHandlingFee,
    quantity,
    productAmount: productP / 100,
    handlingFee: handlingP / 100,
    deliveryFee: feeP / 100,
    distanceKm: km,
    routeDistanceMeters: routeMeters,
    routeProvider: ROUTE_PROVIDER,
    total: (productP + handlingP + feeP) / 100,
    priceVersion: product.priceVersion,
    pricingRulesVersion: PRICING_RULES_VERSION,
    deliveryRates: d,
  };
}

/**
 * Whether a wallet hold pays exactly this order. For the later payment
 * integration: attach must refuse any hold for which this is false.
 */
function holdMatchesSnapshot(order, escrowAmount) {
  const total = order?.priceSnapshot?.total;
  return isMoney(total) && total > 0 && isMoney(escrowAmount) && Math.round(total * 100) === Math.round(escrowAmount * 100);
}

/**
 * The names a passenger sees for a supplier and station: in options and
 * quotes, and snapshotted onto the order so a reopened order still shows
 * them. Public names only, as in publicOption.
 */
function displayNames(supplier, station) {
  return { supplierName: supplier.tradingName || supplier.legalName, stationName: station.name };
}

/** The public view of an option: no contacts, notes, registration or addresses. */
function publicOption({ supplierId, supplier, stationId, station, productId, product }, location) {
  const names = displayNames(supplier, station);
  return {
    supplierId,
    supplierName: names.supplierName,
    stationId,
    stationName: names.stationName,
    productId,
    orderType: product.orderType,
    cylinderSize: product.cylinderSize,
    brand: product.brand,
    unitPrice: product.price,
    unitHandlingFee: product.handlingFee ?? 0,
    priceVersion: product.priceVersion,
    distanceKm: round2(distanceKm(station.location, location)),
  };
}

// ── Request parsing ──────────────────────────────────────────────────────────

function requireAuth(request) {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  return uid;
}

/** Refuses any field outside `allowed`, so a sent price or total is rejected, not ignored. */
function readRequest(data, allowed) {
  if (!data || typeof data !== "object" || Array.isArray(data)) throw new HttpsError("invalid-argument", "Invalid request.");
  const extra = Object.keys(data).filter((k) => !allowed.includes(k));
  if (extra.length) {
    throw new HttpsError("invalid-argument", "Unexpected fields in request.", { reason: "unexpected_fields", fields: extra });
  }
  return data;
}

function readLocation(loc) {
  if (!loc || typeof loc !== "object") return null;
  return { latitude: Number(loc.latitude), longitude: Number(loc.longitude) };
}

function isId(v) {
  return typeof v === "string" && v.length > 0 && v.length <= 200 && !v.includes("/");
}

function refuse(reason, message = "This option is not available.") {
  return new HttpsError("failed-precondition", message, { reason });
}

async function readSelection(tx, { supplierId, stationId, productId }) {
  const supRef = db().collection("gas_suppliers").doc(supplierId);
  const stRef = supRef.collection("stations").doc(stationId);
  const prRef = stRef.collection("products").doc(productId);
  const [s, st, p] = tx
    ? await Promise.all([tx.get(supRef), tx.get(stRef), tx.get(prRef)])
    : await Promise.all([supRef.get(), stRef.get(), prRef.get()]);
  return {
    supplierId, supplier: s.exists ? s.data() : null,
    stationId, station: st.exists ? st.data() : null,
    productId, product: p.exists ? p.data() : null,
  };
}

/** The current commission terms, or a refusal when none are usable. */
async function requireUsableTerms(tx = null) {
  const ref = db().doc(TERMS_DOC);
  const snap = tx ? await tx.get(ref) : await ref.get();
  const terms = snap.exists ? snap.data() : null;
  const problem = termsProblem(terms);
  if (problem) throw refuse(problem, "Gas supplier orders are not available right now.");
  return terms;
}

/**
 * The supplier-ordering switch (settings/gas_supplier_fulfilment.enabled),
 * read at call time; a missing document or any other value means off. It
 * gates listing, quoting and creating orders here, and payment and
 * fulfilment in gas_supplier_fulfilment.js (which uses this same check).
 */
const ORDERING_FLAG_DOC = "settings/gas_supplier_fulfilment";
async function requireOrderingEnabled() {
  const snap = await db().doc(ORDERING_FLAG_DOC).get();
  if (!(snap.exists && snap.data().enabled === true)) {
    throw new HttpsError("unavailable", "Gas supplier orders are not available yet.", { reason: "gas_supplier_fulfilment_disabled" });
  }
}

async function readSettings() {
  const snap = await db().collection("settings").doc("platform").get();
  return snap.exists ? snap.data() : null;
}

// ── Callables ────────────────────────────────────────────────────────────────

async function listOptions(uid, data) {
  const req = readRequest(data, ["orderType", "cylinderSize", "location"]);
  const location = readLocation(req.location);
  const bad = requestProblem({ orderType: req.orderType, cylinderSize: req.cylinderSize, location });
  if (bad) throw new HttpsError("invalid-argument", "Invalid request.", { reason: bad });

  const suppliers = await db().collection("gas_suppliers")
    .where("status", "==", "approved").where("ordersEnabled", "==", true).get();
  const options = [];
  for (const s of suppliers.docs) {
    const stations = await s.ref.collection("stations").where("status", "==", "verified").get();
    for (const st of stations.docs) {
      const products = await st.ref.collection("products")
        .where("orderType", "==", req.orderType).where("cylinderSize", "==", req.cylinderSize).get();
      for (const p of products.docs) {
        const option = { supplierId: s.id, supplier: s.data(), stationId: st.id, station: st.data(), productId: p.id, product: p.data() };
        if (!optionProblem(option, { orderType: req.orderType, cylinderSize: req.cylinderSize, location })) {
          options.push(publicOption(option, location));
        }
      }
    }
  }
  options.sort((a, b) => a.distanceKm - b.distanceKm || a.unitPrice - b.unitPrice);
  return { options };
}

async function quote(uid, data) {
  const req = readRequest(data, ["supplierId", "stationId", "productId", "quantity", "location", "address"]);
  if (![req.supplierId, req.stationId, req.productId].every(isId)) throw new HttpsError("invalid-argument", "Invalid selection.", { reason: "invalid_selection" });
  if (req.address != null && (typeof req.address !== "string" || req.address.length > 500)) {
    throw new HttpsError("invalid-argument", "Invalid address.", { reason: "invalid_address" });
  }
  const location = readLocation(req.location);
  const selection = await readSelection(null, req);
  const orderType = selection.product?.orderType;
  const cylinderSize = selection.product?.cylinderSize;
  // Quantity is required here (null fails the integer check).
  const bad = requestProblem({ orderType, cylinderSize, quantity: req.quantity ?? null, location });
  if (bad === "invalid_quantity" || bad === "invalid_location") throw new HttpsError("invalid-argument", "Invalid request.", { reason: bad });
  // Same precedence as optionProblem: a missing supplier or station (a
  // station is read under its own supplier) is reported as such, not as a
  // missing product.
  if (!selection.supplier) throw refuse("supplier_not_found");
  if (!selection.station) throw refuse("station_not_found");
  if (!selection.product) throw refuse("product_not_found");
  const problem = optionProblem(selection, { orderType, cylinderSize, location });
  if (problem) throw refuse(problem);

  // Approved commission terms and rates first (no routing request when an
  // order could not be made), then the road distance from the station; no
  // straight-line or estimated fallback.
  await requireUsableTerms();
  const settings = await readSettings();
  if (!gasDeliverySettings(settings)) {
    throw new HttpsError("failed-precondition", "Gas delivery prices are unavailable right now.", { reason: "pricing_unavailable" });
  }
  let route;
  try {
    route = await measureRoute(pointOf(selection.station.location), location);
  } catch (e) {
    const reason = e instanceof RoutingError ? e.reason : "routing_failed";
    console.warn(`quoteGasSupplierOrder: no route (${reason})`); // no coordinates logged
    throw new HttpsError("unavailable", "We couldn't measure the delivery route. Please try again.", { reason });
  }
  const pricing = computeQuote({
    product: selection.product, quantity: req.quantity, orderType, routeMeters: route.distanceMeters, settings,
  });
  const ref = db().collection("gas_quotes").doc();
  const expiresAt = admin.firestore.Timestamp.fromMillis(Date.now() + QUOTE_TTL_MS);
  await ref.set({
    userId: uid,
    supplierId: req.supplierId, stationId: req.stationId, productId: req.productId,
    orderType, cylinderSize, brand: selection.product.brand,
    location: new admin.firestore.GeoPoint(location.latitude, location.longitude),
    address: req.address ?? null,
    pricing,
    status: "open",
    orderId: null,
    createdAt: FieldValue.serverTimestamp(),
    expiresAt,
  });
  return { quoteId: ref.id, expiresAt: expiresAt.toMillis(), pricing: publicPricing(pricing) };
}

function pointOf(p) {
  return { latitude: p.latitude, longitude: p.longitude };
}

function publicPricing(p) {
  const { deliveryRates, pricingRulesVersion, ...rest } = p;
  void deliveryRates; void pricingRulesVersion;
  return rest;
}

async function createOrder(uid, data) {
  const req = readRequest(data, ["quoteId"]);
  if (!isId(req.quoteId)) throw new HttpsError("invalid-argument", "Invalid quote.", { reason: "invalid_quote" });
  const quoteRef = db().collection("gas_quotes").doc(req.quoteId);
  // One order per quote: the quote id is the order id and the idempotency key.
  const orderRef = db().collection("gas_supplier_orders").doc(req.quoteId);

  return db().runTransaction(async (tx) => {
    const [q, existing] = await Promise.all([tx.get(quoteRef), tx.get(orderRef)]);
    if (!q.exists || q.data().userId !== uid) throw new HttpsError("not-found", "Quote not found.", { reason: "quote_not_found" });
    const quoteData = q.data();
    if (existing.exists) {
      // A retried or duplicate submission: the order already exists. Its
      // status tells the client whether it still needs paying, so a retry
      // after a lost response never holds wallet funds a second time.
      return { orderId: orderRef.id, total: existing.data().priceSnapshot.total, status: existing.data().status, alreadyCreated: true };
    }
    if (quoteData.status !== "open") throw refuse("quote_not_open", "This quote can no longer be used.");
    if (quoteData.expiresAt.toMillis() <= Date.now()) throw refuse("quote_expired", "This quote has expired. Please get a new price.");

    // Re-check everything at order time: the catalog or terms may have changed.
    const terms = await requireUsableTerms(tx);
    const selection = await readSelection(tx, quoteData);
    const location = { latitude: quoteData.location.latitude, longitude: quoteData.location.longitude };
    const problem = optionProblem(selection, { orderType: quoteData.orderType, cylinderSize: quoteData.cylinderSize, location });
    if (problem) throw refuse(problem);
    if (selection.product.priceVersion !== quoteData.pricing.priceVersion) {
      throw refuse("quote_stale", "The price has changed. Please get a new price.");
    }

    const snapshot = {
      ...quoteData.pricing,
      supplierId: quoteData.supplierId,
      stationId: quoteData.stationId,
      productId: quoteData.productId,
      brand: quoteData.brand,
      quoteId: q.id,
      quotedAt: quoteData.createdAt,
      snapshotAt: FieldValue.serverTimestamp(),
    };
    const allocation = computeAllocation(snapshot, terms);
    if (allocation.problem) throw refuse(allocation.problem, "This order cannot be priced right now.");
    tx.create(orderRef, {
      passengerId: uid,
      supplierId: quoteData.supplierId,
      stationId: quoteData.stationId,
      productId: quoteData.productId,
      orderType: quoteData.orderType,
      cylinderSize: quoteData.cylinderSize,
      quantity: quoteData.pricing.quantity,
      deliveryLocation: quoteData.location,
      deliveryAddress: quoteData.address,
      priceSnapshot: snapshot,
      // Who the order is with, as the passenger was shown it, read in this
      // transaction (the order holds only ids otherwise).
      supplierSnapshot: displayNames(selection.supplier, selection.station),
      status: "awaiting_payment",
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.create(allocationRef(orderRef.id), {
      orderId: orderRef.id, supplierId: quoteData.supplierId, ...allocation,
      settlement: { status: "not_posted", reconciliation: null },
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.update(quoteRef, { status: "used", orderId: orderRef.id, usedAt: FieldValue.serverTimestamp() });
    return { orderId: orderRef.id, total: snapshot.total, status: "awaiting_payment", alreadyCreated: false };
  });
}

const OPTS = { region: "europe-west2", minInstances: 0 };

// Each refuses while supplier ordering is off: no options, no quote (and so
// no routing request), no new order.
const gated = (fn) => async (request) => {
  const uid = requireAuth(request);
  await requireOrderingEnabled();
  return fn(uid, request.data);
};
exports.listGasSupplierOptions = onCall(OPTS, gated(listOptions));
// The routing key is a server secret (delivery_quotes.js).
exports.quoteGasSupplierOrder = onCall({ ...OPTS, secrets: [ROUTES_API_KEY] }, gated(quote));
exports.createGasSupplierOrder = onCall(OPTS, gated(createOrder));

Object.assign(exports, {
  ORDERING_FLAG_DOC, requireOrderingEnabled,
  ORDER_TYPES, CYLINDER_SIZES, QUOTE_TTL_MS, MAX_QUANTITY, PRICING_RULES_VERSION, GAS_DELIVERY_DEFAULTS,
  requestProblem, optionProblem, computeQuote, holdMatchesSnapshot, publicOption,
});
