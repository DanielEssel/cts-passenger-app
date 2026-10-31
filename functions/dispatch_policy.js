"use strict";

/**
 * CTSGo dispatch policy: which drivers may be offered (and, for gas,
 * accept) a Ride, Delivery or Gas request. Pure, no Firestore.
 *
 * Service eligibility (drivers.role, chosen at onboarding, admin-locked once
 * approved):
 *  - Ride:     role 'driver_hailing', drivers.serviceType equal to the trip's
 *              serviceType (okada / taxi / pragyia), and a vehicle that
 *              matches that service.
 *  - Delivery: role 'driver_delivery', the vehicle the passenger booked
 *              (deliveries.vehicleType) and a weight tier that vehicle
 *              carries (DELIVERY_VEHICLE_TIERS).
 *  - Gas:      role 'driver_delivery' (Delivery drivers also serve Gas) and
 *              a vehicle authorised for the refill type (gas_dispatch_policy).
 * Plus, for every service: approved, not suspended, online, available, not
 * on another job (currentTripId), a valid location, and within
 * DISPATCH_RADIUS_KM of the job. The radius applies when a job is offered;
 * claims do not re-check it (rules cannot measure distance, and the
 * driver's position is self-reported).
 *
 * Unknown or missing values fail closed. Mirrored by firestore.rules (ride
 * and delivery claims), the Driver App request list and the Passenger App
 * delivery vehicle choice; keep them in step.
 */

const { normalizeVehicleType, canHandleGasOrder } = require("./gas_dispatch_policy");

/** Offer radius in km, inclusive. The value every dispatcher already used. */
const DISPATCH_RADIUS_KM = 10.0;

/** Ride service → the vehicle (normalised) a driver must have for it. */
const RIDE_SERVICE_VEHICLE = Object.freeze({
  okada: "motorcycle",
  taxi: "taxi",
  pragyia: "pragyia",
});

/**
 * Delivery vehicle (normalised) → the weight tiers it may carry, from the
 * vehicle capacities the Passenger App shows: Okada 0–5 kg (Small),
 * Aboboya 5–100 kg (Medium 5–20, Large 20–100), Mini Truck 100 kg+ (Bulk).
 */
const DELIVERY_VEHICLE_TIERS = Object.freeze({
  motorcycle: Object.freeze(["Small"]),
  tricycle: Object.freeze(["Medium", "Large"]),
  miniTruck: Object.freeze(["Bulk"]),
});

const SERVICE_ROLE = Object.freeze({
  ride: "driver_hailing",
  delivery: "driver_delivery",
  gas: "driver_delivery",
});

/** A usable GeoPoint-like: finite, in range, and not the (0, 0) default. */
function validPoint(p) {
  if (!p || typeof p !== "object") return false;
  const { latitude: lat, longitude: lng } = p;
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return false;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return false;
  return !(lat === 0 && lng === 0);
}

/** Great-circle distance in km (mean Earth radius 6371 km). */
function distanceKm(a, b) {
  const R = 6371;
  const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(b.latitude - a.latitude);
  const dLng = rad(b.longitude - a.longitude);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(a.latitude)) * Math.cos(rad(b.latitude)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

/** Where the driver must go first: pickup for rides and deliveries, the customer for gas. */
function jobPoint(service, job) {
  if (service === "gas") return job.deliveryLocation ?? job.pickupLocation ?? null;
  return job.pickupLocation ?? null;
}

/** The driver's last reported position (dispatch has always read `location`). */
function driverPoint(driver) {
  return driver.location ?? driver.currentLocation ?? null;
}

/** Normalised booked delivery vehicle ('Okada' / 'Aboboya' / 'Mini Truck'), or null. */
function deliveryVehicle(job) {
  const v = normalizeVehicleType(job.vehicleType);
  return v && DELIVERY_VEHICLE_TIERS[v] ? v : null;
}

/** True when the booked delivery vehicle may carry the booked weight tier. */
function deliveryTierAllowed(vehicle, weightTier) {
  return (DELIVERY_VEHICLE_TIERS[vehicle] ?? []).includes(weightTier);
}

/**
 * Why a request cannot be dispatched at all, or null. A request that fails
 * here is offered to nobody (never to everyone).
 */
function jobRejection(service, job) {
  if (!job || !SERVICE_ROLE[service]) return "unknown_service";
  if (!validPoint(jobPoint(service, job))) return "invalid_job_location";
  if (service === "ride" && !RIDE_SERVICE_VEHICLE[job.serviceType]) return "unknown_ride_service";
  if (service === "delivery") {
    const v = deliveryVehicle(job);
    if (!v) return "unknown_delivery_vehicle";
    if (!deliveryTierAllowed(v, job.weightTier)) return "vehicle_cannot_carry_weight_tier";
  }
  return null;
}

/**
 * Why this driver may not take this job, or null when they may.
 * `checkLocation: false` skips the location and radius checks (acceptance).
 */
function driverRejection(service, job, driver, { checkLocation = true } = {}) {
  if (!driver) return "driver_not_found";
  if (driver.isApproved !== true || driver.signupStep === "suspended") return "driver_not_approved";
  if (driver.isOnline !== true || driver.isAvailable !== true) return "driver_unavailable";
  // Going online again sets isAvailable without clearing the current job.
  if (driver.currentTripId != null) return "driver_on_job";
  if (driver.role !== SERVICE_ROLE[service]) return "wrong_service";

  const vehicle = normalizeVehicleType(driver.vehicleType);
  if (service === "ride") {
    if (driver.serviceType !== job.serviceType) return "wrong_ride_service";
    if (!vehicle || vehicle !== RIDE_SERVICE_VEHICLE[job.serviceType]) return "vehicle_not_eligible";
  } else if (service === "delivery") {
    if (!vehicle || vehicle !== deliveryVehicle(job)) return "vehicle_not_eligible";
    if (!deliveryTierAllowed(vehicle, job.weightTier)) return "vehicle_not_eligible";
  } else if (service === "gas") {
    if (!canHandleGasOrder(driver.vehicleType, job.refillType)) return "vehicle_not_eligible";
  }

  if (!checkLocation) return null;
  const at = driverPoint(driver);
  if (!validPoint(at)) return "driver_location_invalid";
  if (!(distanceKm(at, jobPoint(service, job)) <= DISPATCH_RADIUS_KM)) return "outside_radius";
  return null;
}

/** How old a linked rider's last location may be (R1, 10 minutes). */
const LINKED_RIDER_LOCATION_MAX_AGE_MS = 600000;
/** Allowed clock skew for a location stamped in the future. */
const LOCATION_FUTURE_SKEW_MS = 60000;

/**
 * "driver_location_stale" unless lastLocationUpdate (a Firestore Timestamp)
 * is at most maxAgeMs old. Missing, malformed or future-dated (beyond 60 s)
 * values count as stale. Not part of driverRejection.
 */
function driverLocationStale(driver, nowMs, maxAgeMs) {
  const ts = driver?.lastLocationUpdate;
  const ms = typeof ts?.toMillis === "function" ? ts.toMillis() : NaN;
  if (!Number.isFinite(ms)) return "driver_location_stale";
  if (ms > nowMs + LOCATION_FUTURE_SKEW_MS) return "driver_location_stale";
  return nowMs - ms > maxAgeMs ? "driver_location_stale" : null;
}

/**
 * The drivers to notify for a job, from candidate driver documents
 * ({id, data}). Each FCM token is used once, and a token held by more than
 * one driver document is not used at all (the device's current owner is
 * unknown); those drivers still get their inbox entry.
 * @returns {{recipients: Array<{id: string, token: string|null}>,
 *            rejected: Object<string, number>, jobRejection: string|null}}
 */
function selectRecipients(service, job, drivers) {
  const rejected = {};
  const reason = jobRejection(service, job);
  if (reason) return { recipients: [], rejected, jobRejection: reason };

  const eligible = [];
  for (const d of drivers) {
    const why = driverRejection(service, job, d.data);
    if (why) rejected[why] = (rejected[why] ?? 0) + 1;
    else eligible.push(d);
  }

  const owners = new Map();
  for (const d of drivers) {
    const t = d.data?.fcmToken;
    if (typeof t === "string" && t) owners.set(t, (owners.get(t) ?? new Set()).add(d.id));
  }
  const recipients = eligible.map((d) => {
    const t = d.data.fcmToken;
    const token = typeof t === "string" && t && owners.get(t).size === 1 ? t : null;
    return { id: d.id, token };
  });
  return { recipients, rejected, jobRejection: null };
}

module.exports = {
  DISPATCH_RADIUS_KM,
  RIDE_SERVICE_VEHICLE,
  DELIVERY_VEHICLE_TIERS,
  SERVICE_ROLE,
  validPoint,
  distanceKm,
  jobPoint,
  driverPoint,
  deliveryVehicle,
  deliveryTierAllowed,
  jobRejection,
  driverRejection,
  driverLocationStale,
  LINKED_RIDER_LOCATION_MAX_AGE_MS,
  selectRecipients,
};
