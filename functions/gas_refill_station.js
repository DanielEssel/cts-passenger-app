"use strict";

// Phase 2B: a legacy Gas order (gas_orders, delivered by a CTSGo driver) may
// name the verified refill station it should use:
//
//   refillStationRef: { supplierId, stationId }   (customer, at creation only)
//
// The reference is resolved here, on the server, against the supplier's own
// station and its products, with exactly the checks supplier orders use
// (gas_supplier_orders.js optionProblem): an approved supplier taking orders,
// its verified station with usable coordinates, service area, size and order
// type, and an available verified product for the order. Only then is a
// trusted snapshot written on the order:
//
//   verifiedRefillStation: { supplierId, stationId, productId, name, address,
//                            location, verifiedAt }   (server only; rules)
//
// An order without a reference is unchanged (every existing Phase 1 order).
// An order whose reference cannot be honoured is cancelled before dispatch by
// the caller; it never falls back to another station, a guessed point or a
// different price. The Gas price itself stays gas_pricing.js's (verifiedPrice).

const admin = require("firebase-admin");
const { optionProblem } = require("./gas_supplier_orders");

const db = () => admin.firestore();
const ID = /^[A-Za-z0-9_-]{1,128}$/;

/** The order's station reference: null (none), or {supplierId, stationId}, or {problem}. */
function readStationRef(order) {
  const ref = order?.refillStationRef;
  if (ref == null) return null;
  if (typeof ref !== "object" || Array.isArray(ref)) return { problem: "refill_station_ref_invalid" };
  const keys = Object.keys(ref).sort();
  if (keys.length !== 2 || keys[0] !== "stationId" || keys[1] !== "supplierId") return { problem: "refill_station_ref_invalid" };
  // typeof first: RegExp.test would coerce a number to a matching string.
  const isId = (v) => typeof v === "string" && ID.test(v);
  if (!isId(ref.supplierId) || !isId(ref.stationId)) return { problem: "refill_station_ref_invalid" };
  return { supplierId: ref.supplierId, stationId: ref.stationId };
}

/** The point the station must serve: where the gas is delivered. */
function orderPoint(order) {
  const p = order?.deliveryLocation ?? order?.pickupLocation ?? null;
  return p && typeof p.latitude === "number" && typeof p.longitude === "number"
    ? { latitude: p.latitude, longitude: p.longitude } : null;
}

/**
 * Resolves and stamps the order's refill station, in one transaction on the
 * order, the supplier, the station and its products.
 * @returns {{ok: true, stamped?: boolean, none?: boolean} | {ok: false, reason: string}}
 *   reason "order_not_open" = nothing to do (taken or ended meanwhile).
 */
async function verifyAndStampRefillStation(orderId) {
  const orderRef = db().collection("gas_orders").doc(orderId);
  return db().runTransaction(async (tx) => {
    const snap = await tx.get(orderRef);
    const o = snap.exists ? snap.data() : null;
    if (!o || o.status !== "pendingApproval" || o.driverId != null) return { ok: false, reason: "order_not_open" };

    const ref = readStationRef(o);
    if (ref == null) return { ok: true, none: true };
    if (ref.problem) return { ok: false, reason: ref.problem };

    // A retry of the same creation event finds its own stamp.
    const done = o.verifiedRefillStation;
    if (done && done.supplierId === ref.supplierId && done.stationId === ref.stationId) return { ok: true };

    const supRef = db().collection("gas_suppliers").doc(ref.supplierId);
    const stRef = supRef.collection("stations").doc(ref.stationId);
    const brand = typeof o.preferredBrand === "string" && o.preferredBrand && o.preferredBrand !== "any" ? o.preferredBrand : null;
    const [s, st, products] = await Promise.all([
      tx.get(supRef),
      tx.get(stRef),
      // A named brand is one exact product; "any brand" may use any eligible
      // product of this type and size at the station (lowest id first, so a
      // retry resolves the same one).
      brand
        ? tx.get(stRef.collection("products").doc(`${o.refillType}_${o.cylinderSize}_${brand}`)).then((p) => (p.exists ? [p] : []))
        : tx.get(stRef.collection("products").where("orderType", "==", String(o.refillType ?? ""))
            .where("cylinderSize", "==", String(o.cylinderSize ?? ""))).then((q) => q.docs),
    ]);

    const want = { orderType: o.refillType, cylinderSize: o.cylinderSize, location: orderPoint(o) };
    if (!want.location) return { ok: false, reason: "invalid_location" };
    const base = {
      supplierId: ref.supplierId, supplier: s.exists ? s.data() : null,
      stationId: ref.stationId, station: st.exists ? st.data() : null,
    };
    if (!base.supplier) return { ok: false, reason: "supplier_not_found" };
    if (!base.station) return { ok: false, reason: "station_not_found" };

    const candidates = [...products].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    let reason = "product_not_found";
    for (const p of candidates) {
      const problem = optionProblem({ ...base, productId: p.id, product: p.data() }, want);
      if (!problem) {
        const station = base.station;
        tx.update(orderRef, {
          verifiedRefillStation: {
            supplierId: ref.supplierId, stationId: ref.stationId, productId: p.id,
            name: typeof station.name === "string" ? station.name : null,
            address: station.address,
            location: station.location,
            verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
        });
        return { ok: true, stamped: true };
      }
      // Supplier and station problems are the same for every product.
      reason = problem;
      if (!problem.startsWith("product_")) break;
    }
    if (!candidates.length) {
      // No product: still report a supplier or station problem first.
      const problem = optionProblem({ ...base, productId: null, product: null }, want);
      if (problem && !problem.startsWith("product_")) reason = problem;
    }
    return { ok: false, reason };
  });
}

module.exports = { readStationRef, orderPoint, verifyAndStampRefillStation };
