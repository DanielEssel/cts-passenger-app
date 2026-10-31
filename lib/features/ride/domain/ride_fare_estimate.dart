// lib/features/ride/domain/ride_fare_estimate.dart
//
// Client-side ride fare ESTIMATE, shared by the ride option card and the
// confirm button so both show the same amount.
//
// This is not a server quote. The backend re-checks the fare in
// onTripCreated (functions/trips.js) with its own formula, which currently
// differs (no per-minute component, separate pragyia rates). Until a server
// quote exists, label this amount as an estimate.

import '../../../core/services/pricing_service.dart';

/// Estimated fare in GHS for [serviceType] ('taxi' | 'okada' | 'pragyia').
///
/// Same rules the confirm button has always used: base + per-km + per-minute
/// over the route duration, surge if enabled, floored at the minimum fare.
/// Returns 0 when there is no usable distance.
double estimateRideFare({
  required String serviceType,
  required double distanceKm,
  required int durationMin,
  PricingService? pricing,
}) {
  if (distanceKm <= 0) return 0;

  final p = pricing ?? PricingService.instance;
  final fare = p.calculateRideFare(
    serviceType,
    distanceKm,
    waitingMinutes: durationMin.toDouble(),
  );

  final minFare = serviceType == 'okada' ? p.okadaMinFare : p.taxiMinFare;
  return fare > 0 ? (fare >= minFare ? fare : minFare) : minFare;
}

/// Formats a GHS amount the way it is held, to the pesewa (e.g. "GHS 22.70").
String formatGhs(double amount) => 'GHS ${amount.toStringAsFixed(2)}';
