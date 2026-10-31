// What an unassigned driver may see of an open Delivery or legacy Gas order.
//
// Order documents (deliveries, gas_orders) are readable only by their
// passenger, their current driver and admins (firestore.rules). Drivers
// browse open requests from a server-written projection instead:
//   delivery_offers/{deliveryId}, gas_order_offers/{orderId}
// readable by active Delivery drivers, written only here. An offer carries
// what a driver needs to decide and to be routed: an area label (never the
// street address), coordinates rounded to OFFER_GRID_DEGREES (about 1 km),
// the job's kind and size, and the verified amount (Delivery and Gas: only
// once the server has verified and stamped the price). Names, phones, notes,
// photos, instructions, scheduled times, receipt e-mails, completion codes
// and the customer's uid are never copied.
//
// Lifecycle: published when the order is dispatched (priced and, for wallet
// orders, paid); removed in the acceptance transaction (accept_job.js), and
// by the status triggers whenever the order is no longer open and
// unassigned. Every write is decided in a transaction on the order as it is
// now, so a stale event or a retry never re-publishes a taken order.
"use strict";

const admin = require("firebase-admin");
const { stampedDeliveryPrice } = require("./delivery_quotes");

const OFFER_COLLECTION = Object.freeze({ deliveries: "delivery_offers", gas_orders: "gas_order_offers" });
const OPEN_STATUS = Object.freeze({ deliveries: "pending", gas_orders: "pendingApproval" });

/** Offer coordinates are rounded to this many degrees (0.01° ≈ 1.1 km). */
const OFFER_GRID_DEGREES = 0.01;
const OFFER_SCHEMA = 1;
const MAX_AREA_LENGTH = 60;

const getDb = () => admin.firestore();
const round2 = (n) => Math.round(n * 100) / 100;

const offerRef = (collection, orderId) => getDb().collection(OFFER_COLLECTION[collection]).doc(orderId);

/** A rounded copy of point [p] ({latitude, longitude}), or null when it is not a usable point. Pure. */
function coarsePoint(p) {
  const lat = p?.latitude;
  const lng = p?.longitude;
  if (typeof lat !== "number" || typeof lng !== "number" || !Number.isFinite(lat) || !Number.isFinite(lng) ||
      Math.abs(lat) > 90 || Math.abs(lng) > 180 || (lat === 0 && lng === 0)) {
    return null;
  }
  const snap = (v) => Number((Math.round(v / OFFER_GRID_DEGREES) * OFFER_GRID_DEGREES).toFixed(2));
  return new admin.firestore.GeoPoint(snap(lat), snap(lng));
}

/**
 * The area part of a free-text address: its first part (house, street or
 * landmark) and any part with a digit (numbers, plus codes) are dropped, and
 * the last two of the rest kept, the most general ones ("12 Oxford St, Osu,
 * Accra" → "Osu, Accra"; "House 7, Ring Rd Central, Adabraka, Accra" →
 * "Adabraka, Accra", never the street). Empty when nothing general is
 * left. Pure.
 */
function areaLabel(address) {
  if (typeof address !== "string") return "";
  const parts = address.split(",").map((s) => s.trim()).filter(Boolean);
  const area = parts.slice(1).filter((s) => !/\d/.test(s)).slice(-2).join(", ");
  return area.length > MAX_AREA_LENGTH ? area.slice(0, MAX_AREA_LENGTH).trim() : area;
}

const text = (v) => (typeof v === "string" ? v : null);
const bool = (v) => v === true;

/**
 * The offer document for an open order, or null when it cannot be offered
 * (no usable location; Gas without a verified price). Pure apart from the
 * GeoPoint type.
 */
function offerFields(collection, order) {
  if (collection === "deliveries") {
    const pickup = coarsePoint(order.pickupLocation);
    const dropoff = coarsePoint(order.dropoffLocation);
    // Only a delivery whose price the server verified (delivery_quotes.js).
    const fare = stampedDeliveryPrice(order)?.total;
    if (!pickup || !dropoff || typeof fare !== "number" || !Number.isFinite(fare) || fare <= 0) return null;
    return {
      schema: OFFER_SCHEMA,
      service: "delivery",
      pickupArea: areaLabel(order.pickupAddress),
      pickupPoint: pickup,
      dropoffArea: areaLabel(order.dropoffAddress),
      dropoffPoint: dropoff,
      fare: round2(fare),
      paymentMethod: order.paymentMethod === "wallet" ? "wallet" : "cash",
      parcelType: text(order.parcelType),
      weightTier: text(order.weightTier),
      vehicleType: text(order.vehicleType),
      isFragile: bool(order.isFragile),
      requiresHelpers: bool(order.requiresHelpers),
      createdAt: order.createdAt ?? null,
    };
  }
  const point = coarsePoint(order.deliveryLocation) ?? coarsePoint(order.pickupLocation);
  const price = order.verifiedPrice;
  if (!point || !price || typeof price.total !== "number") return null;
  return {
    schema: OFFER_SCHEMA,
    service: "gas",
    // Legacy Gas is served at the customer's location (pickup = delivery).
    pickupArea: areaLabel(order.deliveryAddress ?? order.pickupAddress),
    pickupPoint: point,
    dropoffArea: areaLabel(order.deliveryAddress ?? order.pickupAddress),
    dropoffPoint: point,
    fare: price.total,
    totalPrice: price.total,
    deliveryFee: price.deliveryFee,
    paymentMethod: order.paymentMethod === "wallet" ? "wallet" : "cash",
    refillType: text(order.refillType),
    cylinderSize: text(order.cylinderSize),
    quantity: Number.isInteger(order.quantity) ? order.quantity : 1,
    preferredBrand: text(order.preferredBrand),
    createdAt: order.createdAt ?? null,
  };
}

/** True when [order] is open and unassigned in [collection]. Pure. */
function isOpenUnassigned(collection, order) {
  return !!order && order.status === OPEN_STATUS[collection] && order.driverId == null;
}

/**
 * Publishes the offer for an order that is still open and unassigned, and
 * removes it otherwise. Returns "published" when this call created it (the
 * caller then notifies drivers, once), "exists" when it was already there,
 * and null when there is no offer.
 */
async function publishOffer(collection, orderId) {
  const orderRef = getDb().collection(collection).doc(orderId);
  const ref = offerRef(collection, orderId);
  return getDb().runTransaction(async (tx) => {
    const [snap, existing] = await Promise.all([tx.get(orderRef), tx.get(ref)]);
    const order = snap.exists ? snap.data() : null;
    const fields = isOpenUnassigned(collection, order) ? offerFields(collection, order) : null;
    if (!fields) {
      if (existing.exists) tx.delete(ref);
      return null;
    }
    if (existing.exists) return "exists";
    tx.set(ref, { ...fields, publishedAt: admin.firestore.FieldValue.serverTimestamp() });
    return "published";
  });
}

/** Removes the offer unless the order is (still, or again) open and unassigned. */
async function withdrawOfferIfTaken(collection, orderId) {
  const orderRef = getDb().collection(collection).doc(orderId);
  const ref = offerRef(collection, orderId);
  return getDb().runTransaction(async (tx) => {
    const snap = await tx.get(orderRef);
    if (isOpenUnassigned(collection, snap.exists ? snap.data() : null)) return false;
    const existing = await tx.get(ref);
    if (!existing.exists) return false;
    tx.delete(ref);
    return true;
  });
}

module.exports = {
  OFFER_COLLECTION, OPEN_STATUS, OFFER_GRID_DEGREES, OFFER_SCHEMA,
  coarsePoint, areaLabel, offerFields, isOpenUnassigned, offerRef, publishOffer, withdrawOfferIfTaken,
};
