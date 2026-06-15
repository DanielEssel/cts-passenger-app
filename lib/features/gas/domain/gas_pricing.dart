// lib/features/gas/domain/gas_pricing.dart
//
// Single source of truth for gas order pricing.
//
// PURE calculator: given order params + pricing inputs (incl. distance), returns
// a deterministic breakdown. No Firebase, no side effects — fully unit-testable.
//
// Product price (flat, by size):
//   • Exchange Empty   → refill price (gas only)
//   • New Cylinder     → full cylinder price (hardware + first fill)
//   • Pickup & Return  → refill price
//   • Commercial Bulk  → refill price × commercial rate
//
// Delivery charge (distance-based, like rides/delivery):
//   deliveryCharge = max(minDeliveryFee, baseFare + perKm × distanceKm × legs)
//   • Exchange / New / Commercial → 1 leg (driver → customer)
//   • Pickup & Return             → 2 legs + fixed round-trip surcharge
//
// The total is what gets held in escrow and paid out, so it must always match
// what the customer sees at checkout.

import '../models/gas_refill_request.dart';

/// An itemised, immutable price breakdown for a gas order.
class GasPriceBreakdown {
  final double unitPrice;       // per-unit product price (refill or full)
  final double base;            // unitPrice × qty (× commercialRate for bulk)
  final double brandPremium;    // brand uplift on base
  final double deliveryFee;     // distance-based delivery charge (incl. legs + surcharge)
  final String deliveryLabel;   // "Delivery fee" or "Round-trip delivery"
  final double distanceKm;      // one-way distance used for the estimate
  final double total;           // base + brandPremium + deliveryFee
  final String unitLabel;       // "Refill" or "New cylinder"

  const GasPriceBreakdown({
    required this.unitPrice,
    required this.base,
    required this.brandPremium,
    required this.deliveryFee,
    required this.deliveryLabel,
    required this.distanceKm,
    required this.total,
    required this.unitLabel,
  });
}

/// Dependencies passed in explicitly so the calculator stays pure.
class GasPricingInputs {
  final double Function(CylinderSize) refillPriceOf;
  final double Function(CylinderSize) fullCylinderPriceOf;

  final double baseFare;        // gasBaseFare
  final double perKm;           // gasPerKm
  final double minDeliveryFee;  // gasMinDeliveryFee (floor)
  final double roundTripFee;    // P&R surcharge on top of the 2-leg distance
  final double commercialRate;  // bulk multiplier on product price

  const GasPricingInputs({
    required this.refillPriceOf,
    required this.fullCylinderPriceOf,
    required this.baseFare,
    required this.perKm,
    required this.minDeliveryFee,
    required this.roundTripFee,
    required this.commercialRate,
  });
}

class GasPricing {
  /// Computes the price breakdown. Pure — no I/O.
  ///
  /// [distanceKm] is the one-way estimate (customer ↔ nearest driver/station).
  /// For Pickup & Return the calculator doubles it internally (round trip).
  static GasPriceBreakdown compute({
    required GasRefillType type,
    required CylinderSize size,
    required int quantity,
    required GasBrand? brand,
    required double distanceKm,
    required GasPricingInputs inputs,
  }) {
    final qty = quantity < 1 ? 1 : quantity;
    final multiplier = brand?.priceMultiplier ?? 1.0;
    final dist = distanceKm < 0 ? 0.0 : distanceKm;

    double deliveryFor(int legs) {
      final charge = inputs.baseFare + (inputs.perKm * dist * legs);
      return charge < inputs.minDeliveryFee ? inputs.minDeliveryFee : charge;
    }

    switch (type) {
      case GasRefillType.exchangeEmpty:
        final unit = inputs.refillPriceOf(size);
        return _build(
          unit: unit,
          base: unit * qty,
          multiplier: multiplier,
          deliveryFee: deliveryFor(1),
          deliveryLabel: 'Delivery fee',
          distanceKm: dist,
          unitLabel: 'Refill',
        );

      case GasRefillType.newCylinder:
        final unit = inputs.fullCylinderPriceOf(size);
        return _build(
          unit: unit,
          base: unit * qty,
          multiplier: multiplier,
          deliveryFee: deliveryFor(1),
          deliveryLabel: 'Delivery fee',
          distanceKm: dist,
          unitLabel: 'New cylinder',
        );

      case GasRefillType.pickupAndReturn:
        final unit = inputs.refillPriceOf(size);
        final delivery = deliveryFor(2) + inputs.roundTripFee;
        return _build(
          unit: unit,
          base: unit * qty,
          multiplier: multiplier,
          deliveryFee: delivery,
          deliveryLabel: 'Round-trip delivery',
          distanceKm: dist,
          unitLabel: 'Refill',
        );

      case GasRefillType.commercialBulk:
        final unit = inputs.refillPriceOf(size);
        final rate = inputs.commercialRate > 0 ? inputs.commercialRate : 1.0;
        return _build(
          unit: unit,
          base: unit * qty * rate,
          multiplier: multiplier,
          deliveryFee: deliveryFor(1),
          deliveryLabel: 'Delivery fee',
          distanceKm: dist,
          unitLabel: 'Refill',
        );
    }
  }

  static GasPriceBreakdown _build({
    required double unit,
    required double base,
    required double multiplier,
    required double deliveryFee,
    required String deliveryLabel,
    required double distanceKm,
    required String unitLabel,
  }) {
    final premium = multiplier != 1.0 ? base * (multiplier - 1) : 0.0;
    final total = _round2(base + premium + deliveryFee);
    return GasPriceBreakdown(
      unitPrice: _round2(unit),
      base: _round2(base),
      brandPremium: _round2(premium),
      deliveryFee: _round2(deliveryFee),
      deliveryLabel: deliveryLabel,
      distanceKm: distanceKm,
      total: total,
      unitLabel: unitLabel,
    );
  }

  static double _round2(double v) => (v * 100).round() / 100;
}