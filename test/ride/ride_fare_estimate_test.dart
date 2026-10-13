// PA-06: the ride option card and the confirm button must show the same
// amount, and it must be the amount the booking holds (calculatedFare).

import 'package:cts_transport_app/features/ride/domain/ride_availability.dart';
import 'package:cts_transport_app/features/ride/domain/ride_fare_estimate.dart';
import 'package:cts_transport_app/features/ride/providers/ride_request_provider.dart';
import 'package:cts_transport_app/features/ride/services/ride_options_service.dart';
import 'package:cts_transport_app/features/ride/widgets/ride_option_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // PricingService is never fetched here, so it uses its built-in defaults.
  const routes = [
    (km: 0.4, min: 2),
    (km: 6.2, min: 18),
    (km: 23.7, min: 55),
  ];

  for (final ride in RideOptionsService.availableRides) {
    for (final r in routes) {
      test('${ride.serviceType.name} ${r.km} km / ${r.min} min: card equals confirm button', () {
        final state = RideRequestState(
          selectedRide: ride,
          estimatedDistance: r.km,
          estimatedDuration: r.min,
        );
        final card = RideOptionCard(
          option: ride,
          isSelected: true,
          onTap: () {},
          distance: r.km,
          durationMin: r.min,
          availability: RideAvailability.notChecked,
        );

        expect(card.calculatedPrice, state.calculatedFare);
        expect(formatGhs(card.calculatedPrice), formatGhs(state.calculatedFare));
        expect(state.calculatedFare, greaterThan(0));
      });
    }
  }

  test('estimate includes the per-minute component the confirm button charged before', () {
    final withTime = estimateRideFare(serviceType: 'taxi', distanceKm: 10, durationMin: 30);
    final noTime = estimateRideFare(serviceType: 'taxi', distanceKm: 10, durationMin: 0);
    expect(withTime, greaterThan(noTime));
  });

  test('no distance gives no fare', () {
    expect(estimateRideFare(serviceType: 'okada', distanceKm: 0, durationMin: 10), 0);
    expect(const RideRequestState().calculatedFare, 0);
  });

  test('formatGhs shows pesewas', () {
    expect(formatGhs(22.7), 'GHS 22.70');
    expect(formatGhs(10), 'GHS 10.00');
  });
}
