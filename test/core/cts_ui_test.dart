// Shared CTSGo components and the ride booking pieces built on them.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/home/widgets/service_tile.dart';
import 'package:cts_transport_app/features/ride/providers/ride_request_provider.dart';
import 'package:cts_transport_app/features/ride/services/ride_options_service.dart';
import 'package:cts_transport_app/features/ride/widgets/ride_option_card.dart';
import 'package:cts_transport_app/features/ride/widgets/route_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  group('CtsPrimaryButton', () {
    testWidgets('ignores taps while loading and when disabled', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(CtsPrimaryButton(
          label: 'Go', loading: true, onPressed: () => taps++)));
      await tester.tap(find.byType(CtsPrimaryButton));
      expect(taps, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpWidget(
          _host(const CtsPrimaryButton(label: 'Go', onPressed: null)));
      await tester.tap(find.byType(CtsPrimaryButton));
      expect(taps, 0);

      await tester.pumpWidget(
          _host(CtsPrimaryButton(label: 'Go', onPressed: () => taps++)));
      await tester.tap(find.byType(CtsPrimaryButton));
      expect(taps, 1);
    });
  });

  testWidgets('CtsSelectableCard exposes its selected state', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(CtsSelectableCard(
      selected: true,
      onTap: () {},
      semanticLabel: 'Wallet',
      child: const Text('Wallet'),
    )));
    expect(
      tester.getSemantics(find.byType(CtsSelectableCard)),
      matchesSemantics(
        label: 'Wallet',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
        hasEnabledState: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('each ride card shows its own vehicle photo', (tester) async {
    for (final ride in RideOptionsService.availableRides) {
      await tester.pumpWidget(_host(RideOptionCard(
        option: ride,
        isSelected: false,
        onTap: () {},
        distance: 5,
        durationMin: 12,
      )));
      final img = tester.widget<ServiceImage>(find.byType(ServiceImage));
      expect(img.service, ride.serviceType);
    }
  });

  testWidgets('route summary shows only real trip data', (tester) async {
    const state = RideRequestState(
      origin: 'Osu',
      destination: 'Airport',
      dropoffLocation: GeoPoint(5.60, -0.17),
      estimatedDistance: 7.4,
      estimatedDuration: 18,
    );
    await tester.pumpWidget(_host(RouteSummary(
      state: state,
      onDestinationTap: () {},
    )));
    expect(find.text('7.4 km'), findsOneWidget);
    expect(find.text('~18 min'), findsOneWidget);
    expect(find.text('Moderate'), findsNothing);
  });

  group('RouteSummary pickup (never a made-up location)', () {
    testWidgets('shows finding state while GPS runs', (tester) async {
      await tester.pumpWidget(_host(RouteSummary(
        state: const RideRequestState(),
        onDestinationTap: () {},
        locatingPickup: true,
      )));
      expect(find.text('Finding your location…'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('offers a retry when the location is unavailable',
        (tester) async {
      var retries = 0;
      await tester.pumpWidget(_host(RouteSummary(
        state: const RideRequestState(),
        onDestinationTap: () {},
        onRetryPickup: () => retries++,
      )));
      expect(
          find.text('Location unavailable. Tap to try again'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(retries, 1);
    });

    testWidgets('a real pickup shows its address, no retry', (tester) async {
      await tester.pumpWidget(_host(RouteSummary(
        state: const RideRequestState(
          origin: 'Osu',
          pickupLocation: GeoPoint(5.55, -0.18),
        ),
        onDestinationTap: () {},
      )));
      expect(find.text('Osu'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  });

  testWidgets('CtsErrorState offers retry and a way home, no raw error',
      (tester) async {
    var retried = 0, back = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CtsErrorState(
          title: "Can't load your gas order",
          message: 'Check your connection. Your order is not affected.',
          onRetry: () => retried++,
          onBack: () => back++,
        ),
      ),
    ));
    await tester.tap(find.text('Try again'));
    await tester.tap(find.text('Back to home'));
    expect((retried, back), (1, 1));
    expect(find.textContaining('Exception'), findsNothing);
  });

  test('ctsMoney groups thousands and keeps two decimals', () {
    expect(ctsMoney(0), '0.00');
    expect(ctsMoney(42.5), '42.50');
    expect(ctsMoney(1242.5), '1,242.50');
    expect(ctsMoney(1234567.891), '1,234,567.89');
    expect(ctsMoney(-1500), '-1,500.00');
  });
}
