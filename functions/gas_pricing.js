// The one price of a legacy Gas order (gas_orders), computed on the server.
//
// The Passenger App computes the same price (lib/features/gas/domain/
// gas_pricing.dart) for display; this module is the authority. A new order
// is offered to drivers only when its own totalPrice and deliveryFee equal
// this price to the pesewa (onGasOrderCreated); the result is stamped on the
// order as verifiedPrice, and acceptance and settlement use that stamp, never
// the settings as they are later and never a client-written amount.
//
// Formula (GAS_PRICING_VERSION "gas-v2"):
//   unit      = refill<size> (Exchange, Pickup & Return, Commercial) or
//               full<size> (New cylinder), from settings/platform.gas
//   base      = unit × quantity (× commercialRate for Commercial bulk)
//   premium   = base × (brand multiplier − 1)            (0 for no brand)
//   legs      = 2 for Pickup & Return, else 1
//   delivery  = max(minDeliveryFee, baseFare + perKm × STANDARD_DISTANCE_KM × legs)
//               + roundTripFee for Pickup & Return
//   total     = round2(base + premium + delivery)
//   commission = round2(total × platformFeePercent / 100); driverNet = round2(total − commission)
// round2(x) = Math.round(x × 100) / 100 (Dart: (x × 100).round() / 100; equal
// for positive amounts). Only the final amounts are rounded.
//
// The delivery charge uses a fixed standard distance: the server cannot
// substantiate the app's former estimate (distance to the nearest online
// driver), so neither side uses it.
//
// Settings values: a missing key uses the built-in price below (as the app
// does); a number or a numeric string is used; anything else (text, a
// negative or non-finite number, a non-map `gas`) makes Gas unpriceable, and
// the order is cancelled before any driver sees it.
"use strict";

const GAS_PRICING_VERSION = "gas-v2";

/** The delivery distance both the app and the server charge, in km. */
const STANDARD_DISTANCE_KM = 1;

/** Most cylinders in one order (the app's quantity stepper stops here). */
const MAX_GAS_QUANTITY = 20;

/** Built-in prices: PricingService._defaults (lib/core/services/pricing_service.dart). */
const GAS_DEFAULTS = Object.freeze({
  refill3kg: 40, refill6kg: 75, refill12kg: 150, refill14kg: 177, refill19kg: 230, refill45kg: 540,
  full3kg: 180, full6kg: 280, full12kg: 480, full14kg: 520, full19kg: 620, full45kg: 1150,
  baseFare: 8, perKm: 2, minDeliveryFee: 12, roundTripFee: 30, commercialRate: 1,
});
const DEFAULT_PLATFORM_FEE_PERCENT = 15;

/** CylinderSize.name (gas_refill_request.dart) → the settings key suffix. */
const GAS_SIZE_KEY = Object.freeze({
  kg3: "3kg", kg6: "6kg", kg12_5: "12kg", kg14_5: "14kg", kg19: "19kg", kg45: "45kg",
});

const GAS_TYPES = Object.freeze(["exchangeEmpty", "newCylinder", "pickupAndReturn", "commercialBulk"]);

/** GasBrand.priceMultiplier (gas_refill_request.dart); an absent brand is "any" (1.00). */
const GAS_BRAND_MULTIPLIER = Object.freeze({
  goGas: 1.00, totalEnergies: 1.05, goil: 1.00, shell: 1.04, benab: 1.01, blueOcean: 1.01,
  newGas: 1.00, louisGas: 1.00, manbahGas: 1.00, rootsenaf: 1.00, zola: 1.03, radix: 1.02,
  soilGroup: 1.00, any: 1.00,
});

const round2 = (n) => Math.round(n * 100) / 100;
const NUMERIC_TEXT = /^\s*\d+(\.\d+)?\s*$/;

/**
 * A configured amount: the default when absent, a number or numeric string
 * when valid, else undefined (malformed). Pure.
 */
function configNumber(raw, fallback) {
  if (raw === undefined || raw === null) return fallback;
  if (typeof raw === "number") return Number.isFinite(raw) && raw >= 0 ? raw : undefined;
  if (typeof raw === "string" && NUMERIC_TEXT.test(raw)) return Number(raw);
  return undefined;
}

/** The platform fee percentage (0–100) from settings, or undefined when malformed. Pure. */
function platformFeePercent(settings) {
  const pct = configNumber(settings?.platformFeePercent, DEFAULT_PLATFORM_FEE_PERCENT);
  return pct !== undefined && pct <= 100 ? pct : undefined;
}

/** Splits [total] into the platform commission and the driver's net, as settlement does. Pure. */
function commissionFor(total, pct) {
  const commission = round2(total * pct / 100);
  return { commission, driverNet: round2(total - commission) };
}

/**
 * The server price of a Gas order (refillType, cylinderSize, quantity,
 * preferredBrand) under [settings] (settings/platform). Pure.
 * @returns {{ok: true, version, unitPrice, base, brandPremium, deliveryFee,
 *   total, platformFeePercent, commission, driverNet} | {ok: false, reason}}
 */
function gasPriceQuote(order, settings) {
  const sizeKey = GAS_SIZE_KEY[order?.cylinderSize];
  const type = order?.refillType;
  const qty = order?.quantity;
  if (!sizeKey || !GAS_TYPES.includes(type)) return { ok: false, reason: "order_unpriceable" };
  if (!Number.isInteger(qty) || qty < 1 || qty > MAX_GAS_QUANTITY) {
    return { ok: false, reason: "quantity_invalid" };
  }
  const brandKey = order.preferredBrand ?? "any";
  if (typeof brandKey !== "string" || !Object.prototype.hasOwnProperty.call(GAS_BRAND_MULTIPLIER, brandKey)) {
    return { ok: false, reason: "brand_unknown" };
  }

  const gasCfg = settings?.gas;
  if (gasCfg !== undefined && gasCfg !== null && (typeof gasCfg !== "object" || Array.isArray(gasCfg))) {
    return { ok: false, reason: "gas_config_invalid" };
  }
  const g = gasCfg || {};
  const rate = (k) => configNumber(g[k], GAS_DEFAULTS[k]);
  const unitKey = `${type === "newCylinder" ? "full" : "refill"}${sizeKey}`;
  const r = {
    unit: rate(unitKey), baseFare: rate("baseFare"), perKm: rate("perKm"),
    minDeliveryFee: rate("minDeliveryFee"), roundTripFee: rate("roundTripFee"),
    commercialRate: rate("commercialRate"),
  };
  if (Object.values(r).some((v) => v === undefined) || !(r.unit > 0) || !(r.commercialRate > 0)) {
    return { ok: false, reason: "gas_config_invalid" };
  }
  const pct = platformFeePercent(settings);
  if (pct === undefined) return { ok: false, reason: "platform_fee_invalid" };

  const legs = type === "pickupAndReturn" ? 2 : 1;
  const base = r.unit * qty * (type === "commercialBulk" ? r.commercialRate : 1);
  const multiplier = GAS_BRAND_MULTIPLIER[brandKey];
  const premium = multiplier !== 1 ? base * (multiplier - 1) : 0;
  const charge = r.baseFare + r.perKm * STANDARD_DISTANCE_KM * legs;
  const delivery = (charge < r.minDeliveryFee ? r.minDeliveryFee : charge) +
    (type === "pickupAndReturn" ? r.roundTripFee : 0);
  const total = round2(base + premium + delivery);
  return {
    ok: true,
    version: GAS_PRICING_VERSION,
    unitPrice: round2(r.unit),
    base: round2(base),
    brandPremium: round2(premium),
    deliveryFee: round2(delivery),
    total,
    platformFeePercent: pct,
    ...commissionFor(total, pct),
  };
}

const sameAmount = (a, b) => typeof a === "number" && Number.isFinite(a) && round2(a) === round2(b);

/**
 * Checks a new order's own amounts against the server price. Pure.
 * @returns {{ok: true, quote} | {ok: false, reason, quote?}}
 *   reasons: price_missing, price_unverifiable (with the quote's reason in
 *   `detail`), price_changed (the order's total or delivery fee is not the
 *   server price: a stale quote, an older app's distance-based fee, or a
 *   modified client).
 */
function verifyGasOrderPrice(order, settings) {
  const total = order?.totalPrice;
  if (typeof total !== "number" || !Number.isFinite(total) || total <= 0) {
    return { ok: false, reason: "price_missing" };
  }
  const quote = gasPriceQuote(order, settings);
  if (!quote.ok) return { ok: false, reason: "price_unverifiable", detail: quote.reason };
  if (!sameAmount(total, quote.total) || !sameAmount(order.deliveryFee, quote.deliveryFee)) {
    return { ok: false, reason: "price_changed", quote };
  }
  return { ok: true, quote };
}

/** The verifiedPrice stamp written on an order (without its timestamp). Pure. */
function verifiedPriceStamp(quote) {
  const { version, unitPrice, base, brandPremium, deliveryFee, total, platformFeePercent: pct,
    commission, driverNet } = quote;
  return { version, unitPrice, base, brandPremium, deliveryFee, total, platformFeePercent: pct,
    commission, driverNet };
}

/**
 * The order's stamped price when it still describes the order (same total),
 * else null. Pure.
 */
function stampedPrice(order) {
  const v = order?.verifiedPrice;
  if (!v || typeof v !== "object" || v.version !== GAS_PRICING_VERSION) return null;
  if (!sameAmount(order.totalPrice, v.total) || !sameAmount(v.commission, v.commission)) return null;
  return v;
}

module.exports = {
  GAS_PRICING_VERSION, STANDARD_DISTANCE_KM, MAX_GAS_QUANTITY, GAS_DEFAULTS, GAS_SIZE_KEY,
  GAS_TYPES, GAS_BRAND_MULTIPLIER, DEFAULT_PLATFORM_FEE_PERCENT,
  configNumber, platformFeePercent, commissionFor, gasPriceQuote, verifyGasOrderPrice,
  verifiedPriceStamp, stampedPrice, round2,
};
