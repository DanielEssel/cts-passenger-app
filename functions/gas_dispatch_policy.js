'use strict';

/**
 * CTSGo Gas Dispatch Policy
 *
 * This module is the single source of truth for gas vehicle eligibility.
 *
 * IMPORTANT:
 * - Values here match drivers.vehicleType in Firestore.
 * - Unknown/missing vehicle types fail closed.
 * - Do not add capacity limits until the business rules explicitly define them.
 */

const GAS_CAPABILITIES = Object.freeze({
  motorcycle: new Set([
    'exchangeEmpty',
    'newCylinder',
    'pickupAndReturn',
  ]),

  tricycle: new Set([
    'exchangeEmpty',
    'newCylinder',
    'commercialBulk',
  ]),

  miniTruck: new Set([
    'exchangeEmpty',
    'newCylinder',
    'commercialBulk',
  ]),

  pragyia: new Set(),

  taxi: new Set(),

  quadricycle: new Set(),
});

/**
 * Normalize only known historical aliases.
 *
 * Unknown values intentionally return null.
 */
function normalizeVehicleType(value) {
  if (typeof value !== 'string') return null;

  const normalized = value.trim().toLowerCase();

  switch (normalized) {
    case 'motorcycle':
    case 'motorbike':
    case 'okada':
      return 'motorcycle';

    case 'tricycle':
    case 'aboboyaa':
    case 'aboboya':
      return 'tricycle';

    case 'minitruck':
    case 'mini_truck':
    case 'mini truck':
      return 'miniTruck';

    case 'pragyia':
      return 'pragyia';

    case 'taxi':
      return 'taxi';

    case 'quadricycle':
      return 'quadricycle';

    default:
      return null;
  }
}

/**
 * Normalize the active GasRefillType Firestore values.
 */
function normalizeRefillType(value) {
  if (typeof value !== 'string') return null;

  const normalized = value.trim();

  switch (normalized) {
    case 'exchangeEmpty':
    case 'newCylinder':
    case 'pickupAndReturn':
    case 'commercialBulk':
      return normalized;

    default:
      return null;
  }
}

/**
 * Returns true only when the driver's registered vehicle is
 * explicitly authorized for the gas refill type.
 */
function canHandleGasOrder(vehicleType, refillType) {
  const vehicle = normalizeVehicleType(vehicleType);
  const refill = normalizeRefillType(refillType);

  if (!vehicle || !refill) return false;

  return GAS_CAPABILITIES[vehicle]?.has(refill) === true;
}

module.exports = {
  GAS_CAPABILITIES,
  normalizeVehicleType,
  normalizeRefillType,
  canHandleGasOrder,
};
