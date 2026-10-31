// Server-side check of a wallet hold against the booking it pays for.
//
// holdBalance takes the amount from the passenger app, and settlement pays
// the driver from the held amount, so a modified client could hold a token
// sum for a long ride or delivery. Before a hold is linked to a Ride or
// Delivery order (attachEscrowToOrder, and the ride dispatcher), it must:
//   • belong to an order booked for wallet payment;
//   • equal the fare the order was booked at; and
//   • be at least a conservative minimum price recomputed on the server.
//
// The minimum is a floor, not the expected price: it uses the straight-line
// distance between the stored pickup and drop-off (a road is never shorter),
// leaves out the per-minute and surge parts, and takes the lowest reading of
// the configured rates and of the built-in defaults, in both the passenger
// app's formula and the server's. A legitimate booking is never below it; an
// underpayment smaller than (road - straight-line distance) and the
// time-based parts is not detected. Gas is priced exactly (gas_pricing.js).
"use strict";

const { assessDeliveryFare, straightLineKm } = require("./delivery_fare_validation");
const { gasPriceQuote, verifyGasOrderPrice, GAS_DEFAULTS, GAS_BRAND_MULTIPLIER } = require("./gas_pricing");

const round2 = (n) => Math.round(n * 100) / 100;
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** Geodesic slack, as in delivery_fare_validation.js. */
const DISTANCE_SLACK = 0.01;
/** Rounding slack in GHS between the app's and this calculation. */
const FARE_TOLERANCE = 0.01;

// Built-in ride rates: the passenger app's PricingService._defaults, which
// match trips.js calculateRideFare's defaults.
const RIDE_DEFAULTS = {
  okada: { baseFare: 3.0, perKmRate: 1.5, minimumFare: 5.0 },
  pragyia: { baseFare: 4.0, perKmRate: 2.0, minimumFare: 8.0 },
  taxi: { baseFare: 5.0, perKmRate: 2.5, minimumFare: 10.0 },
};

const isPoint = (p) => p != null && num(p.latitude) != null && num(p.longitude) != null &&
  Math.abs(p.latitude) <= 90 && Math.abs(p.longitude) <= 180 &&
  !(p.latitude === 0 && p.longitude === 0);

/** Rates for [key] from settings/platform, value by value over the defaults. */
function rideRates(settings, key) {
  const s = settings && typeof settings[key] === "object" && settings[key] ? settings[key] : {};
  const def = RIDE_DEFAULTS[key];
  const surge = s.surgeEnabled === true ? num(s.surgeMultiplier) ?? num(s.surgeMutiplier) : null;
  return {
    baseFare: num(s.baseFare) ?? def.baseFare,
    perKmRate: num(s.perKmRate) ?? def.perKmRate,
    minimumFare: num(s.minimumFare) ?? def.minimumFare,
    // A multiplier below 1 lowers a fare; above 1 it only raises it.
    surge: surge != null && surge > 0 && surge < 1 ? surge : 1,
  };
}

function rideFloorFor(rates, km) {
  const fare = (rates.baseFare + rates.perKmRate * km) * rates.surge;
  return fare < rates.minimumFare ? rates.minimumFare : fare;
}

/**
 * The lowest fare a legitimate ride booking can have, or null when it
 * cannot be worked out (unknown service, missing locations). Pure.
 */
function rideFareFloor(trip, settings) {
  const type = typeof trip?.serviceType === "string" ? trip.serviceType.toLowerCase() : null;
  if (!type || !RIDE_DEFAULTS[type]) return null;
  if (!isPoint(trip.pickupLocation) || !isPoint(trip.dropoffLocation)) return null;
  const km = straightLineKm(trip.pickupLocation, trip.dropoffLocation) * (1 - DISTANCE_SLACK);
  // The app prices Okada with Okada rates and every other ride with taxi
  // rates; the server uses each service's own rates.
  const appKey = type === "okada" ? "okada" : "taxi";
  const readings = [settings, {}].flatMap((s) => [
    rideFloorFor(rideRates(s, appKey), km),
    rideFloorFor(rideRates(s, type), km),
  ]);
  return round2(Math.min(...readings));
}

/**
 * The lowest fare a legitimate delivery booking can have, or null when it
 * cannot be worked out. Uses delivery_fare_validation's minimum with the
 * configured rates and with the built-in defaults. Pure.
 */
function deliveryFareFloor(order, settings) {
  const readings = [];
  for (const s of [settings, {}]) {
    if (!s || typeof s !== "object") continue;
    // assessDeliveryFare needs a positive fare to run; the floor itself
    // does not depend on it.
    const a = assessDeliveryFare({ ...order, estimatedFare: 1 }, s);
    if (a.status === "insufficient_data") return null;
    readings.push(a.serverMinimumFare);
  }
  return readings.length ? round2(Math.min(...readings)) : null;
}

// Legacy Gas: the price is gas_pricing.js's (the one server authority).

/**
 * The price a legitimate legacy Gas order has (gas_pricing.js
 * gasPriceQuote's total), or null when it cannot be priced. Holds and order
 * totals must reach it; new orders must equal it (verifyGasOrderPrice). Pure.
 */
function gasFareFloor(order, settings) {
  const quote = gasPriceQuote(order, settings);
  return quote.ok ? quote.total : null;
}

/**
 * Why a new legacy Gas order's own amounts cannot stand, or null: its total
 * and delivery fee must equal the server price (gas_pricing.js). Pure.
 */
function gasOrderPriceProblem(order, settings) {
  const check = verifyGasOrderPrice(order, settings);
  return check.ok ? null : check.reason;
}

/** Services whose holds are checked against the booking's price. */
const PRICE_CHECKED_TYPES = new Set(["trip", "delivery", "gas_order"]);

/**
 * Whether [escrowAmount] may pay [order] ([referenceType] "trip",
 * "delivery" or "gas_order"). Other services are not checked. Pure.
 * @returns {{ok: true, floor?: number} | {ok: false, reason: string, floor?: number}}
 */
function verifyHeldAmount({ referenceType, order, escrowAmount, settings }) {
  if (!PRICE_CHECKED_TYPES.has(referenceType)) return { ok: true };
  if (order?.paymentMethod != null && order.paymentMethod !== "wallet") {
    return { ok: false, reason: "order_not_wallet_payment" };
  }
  const booked = num(referenceType === "trip"
    ? order?.originalClientFare ?? order?.estimatedFare
    : referenceType === "gas_order" ? order?.totalPrice : order?.estimatedFare);
  if (booked == null) return { ok: false, reason: "booked_fare_missing" };
  if (num(escrowAmount) == null || round2(booked) !== round2(escrowAmount)) {
    return { ok: false, reason: "hold_amount_mismatch" };
  }
  const floor = referenceType === "trip"
    ? rideFareFloor(order, settings)
    : referenceType === "gas_order" ? gasFareFloor(order, settings)
    : deliveryFareFloor(order, settings);
  if (floor == null) return { ok: false, reason: "price_unverifiable" };
  if (escrowAmount + FARE_TOLERANCE < floor) {
    return { ok: false, reason: "hold_below_minimum_price", floor };
  }
  return { ok: true, floor };
}

module.exports = { rideFareFloor, deliveryFareFloor, gasFareFloor, gasOrderPriceProblem, verifyHeldAmount,
  RIDE_DEFAULTS, GAS_DEFAULTS, GAS_BRAND_MULTIPLIER, PRICE_CHECKED_TYPES };
