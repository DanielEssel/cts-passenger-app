// PA-01: ride categories must stay selectable without any driver data.
// Availability and counts come from the same driver_map data as the map
// markers, and only fade a category; they never block selecting it.

import 'package:cts_transport_app/features/ride/domain/ride_availability.dart';
import 'package:cts_transport_app/features/ride/domain/ride_fare_estimate.dart';
import 'package:cts_transport_app/features/ride/providers/drivers_nearby_provider.dart';
import 'package:cts_transport_app/features/ride/providers/ride_request_provider.dart';
import 'package:cts_transport_app/features/ride/providers/wallet_provider.dart';
import 'package:cts_transport_app/features/ride/services/ride_options_service.dart';
import 'package:cts_transport_app/features/ride/widgets/ride_option_card.dart';
import 'package:cts_transport_app/features/ride/widgets/ride_options_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  final taxi = RideOptionsService.availableRides.first;

  group('RideOptionCard', () {
    for (final availability in RideAvailability.values) {
      testWidgets('is tappable and labelled when ${availability.name}', (tester) async {
        var taps = 0;
        await tester.pumpWidget(_host(RideOptionCard(
          option: taxi,
          isSelected: false,
          onTap: () => taps++,
          distance: 6.2,
          durationMin: 18,
          availability: availability,
          driverCount: availability == RideAvailability.available ? 1 : 0,
        )));

        expect(
          find.text(availability == RideAvailability.available
              ? '1 driver nearby'
              : availability.label),
          findsOneWidget,
        );
        await tester.tap(find.byType(RideOptionCard));
        expect(taps, 1);
      });
    }

    testWidgets('shows the nearby count when available', (tester) async {
      await tester.pumpWidget(_host(RideOptionCard(
        option: taxi,
        isSelected: false,
        onTap: () {},
        availability: RideAvailability.available,
        driverCount: 3,
      )));
      expect(find.text('3 drivers nearby'), findsOneWidget);
    });

    testWidgets('fades but stays tappable when no driver is nearby', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(RideOptionCard(
        option: taxi,
        isSelected: false,
        onTap: () => taps++,
        availability: RideAvailability.unavailable,
      )));
      await tester.pumpAndSettle();
      final fade = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(fade.opacity, 0.5);
      await tester.tap(find.byType(RideOptionCard));
      expect(taps, 1);
    });

    testWidgets('shows the estimate to the pesewa and labels it an estimate', (tester) async {
      await tester.pumpWidget(_host(RideOptionCard(
        option: taxi,
        isSelected: false,
        onTap: () {},
        distance: 6.2,
        durationMin: 18,
      )));
      final expected = formatGhs(estimateRideFare(
        serviceType: taxi.serviceType.name,
        distanceKm: 6.2,
        durationMin: 18,
      ));
      expect(find.text(expected), findsOneWidget);
      expect(find.textContaining('Estimate'), findsOneWidget);
    });

    testWidgets('does not overflow on a narrow phone', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      for (final option in RideOptionsService.availableRides) {
        await tester.pumpWidget(_host(RideOptionCard(
          option: option,
          isSelected: true,
          onTap: () {},
          distance: 42.5,
          durationMin: 95,
          availability: RideAvailability.notChecked,
        )));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: option.name);
      }
    });
  });

  group('RideOptionsList', () {
    testWidgets('every category can be selected and matches the map drivers', (tester) async {
      final container = ProviderContainer(overrides: [
        walletBalanceProvider.overrideWith((ref) async => 0.0),
        driversNearbyProvider.overrideWith((ref) => Stream.value(const [
              NearbyDriver(
                id: 'd1',
                name: 'Driver',
                location: LatLng(5.6, -0.19),
                serviceType: 'okada',
              ),
            ])),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (context, ref, _) {
          final state = ref.watch(rideRequestProvider);
          return _host(RideOptionsList(
            state: state.copyWith(estimatedDistance: 6.2, estimatedDuration: 18),
            onShowPaymentSheet: () {},
          ));
        }),
      ));
      await tester.pump();

      final cards = find.byType(RideOptionCard);
      expect(cards, findsNWidgets(RideOptionsService.availableRides.length));

      for (var i = 0; i < RideOptionsService.availableRides.length; i++) {
        await tester.ensureVisible(cards.at(i));
        await tester.tap(cards.at(i));
        await tester.pump();
        expect(
          container.read(rideRequestProvider).selectedRide?.serviceType,
          RideOptionsService.availableRides[i].serviceType,
        );
      }

      // Cards agree with the map: one okada marker → okada available,
      // the rest faded but (as tapped above) still selectable.
      expect(find.text('1 driver nearby'), findsOneWidget);
      expect(find.text(RideAvailability.unavailable.label),
          findsNWidgets(RideOptionsService.availableRides.length - 1));
    });
  });
}
