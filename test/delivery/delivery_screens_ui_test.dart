// Delivery redesign: the request form and the vehicle/review screen keep
// their validation gate, show only real data, and fit small phones.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/core/services/pricing_service.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/delivery/presentation/delivery_screen.dart';
import 'package:cts_transport_app/features/delivery/presentation/delivery_vehicle_screen.dart';
import 'package:cts_transport_app/features/home/widgets/service_tile.dart';
import 'package:cts_transport_app/features/ride/services/route_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Route lookup the test controls: completes with [result] when told to.
class _FakeRouteService extends RouteService {
  final completer = Completer<RouteResult?>();
  @override
  Future<RouteResult?> getRoute(LatLng origin, LatLng destination) =>
      completer.future;
}

Future<void> _setView(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _app(Widget home, {double textScale = 1.0, List overrides = const []}) =>
    ProviderScope(
      overrides: [...overrides],
      child: MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: home,
          ),
        ),
      ),
    );

DeliveryVehicleScreen _vehicleScreen({
  String tier = 'Medium',
  List<String> vehicles = const ['Okada', 'Aboboya'],
}) =>
    DeliveryVehicleScreen(
      pickup: 'MCPW+QW7, Bawjiase, Central Region, a fairly long address',
      pickupGeoPoint: const GeoPoint(5.60, -0.20),
      dropoff: 'Accra Mall, Spintex Road, Accra, Greater Accra, Ghana',
      dropoffGeoPoint: const GeoPoint(5.63, -0.15),
      weightTier: tier,
      weightRange: '5–20 kg',
      eligibleVehicles: vehicles,
      parcelType: 'Package',
      isFragile: true,
      requiresHelpers: false,
      hasPhoto: false,
      receiverPhone: '0241234567',
      receiverName: 'Ama',
      notes: '',
    );

void main() {
  group('DeliveryScreen', () {
    testWidgets('next step stays disabled and explains what is missing',
        (tester) async {
      await _setView(tester, const Size(390, 844));
      await tester.pumpWidget(_app(const DeliveryScreen()));
      await tester.pump();

      expect(find.text('Send a parcel'), findsOneWidget);
      final button =
          tester.widget<CtsPrimaryButton>(find.byType(CtsPrimaryButton));
      expect(button.label, 'See vehicles & prices');
      expect(button.onPressed, isNull);
      // A text hint (not colour alone) says what to do next.
      expect(find.byIcon(Icons.info_outline_rounded), findsWidgets);
    });

    testWidgets('helpers are unavailable for an Okada-only weight',
        (tester) async {
      await _setView(tester, const Size(390, 844));
      await tester.pumpWidget(_app(const DeliveryScreen()));
      await tester.pump();

      await tester.scrollUntilVisible(find.text('Small'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Small'));
      await tester.pump();
      await tester.scrollUntilVisible(
          find.text('Not available for this weight'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Not available for this weight'), findsOneWidget);
    });

    testWidgets('extras show the fee PricingService charges', (tester) async {
      await _setView(tester, const Size(390, 844));
      await tester.pumpWidget(_app(const DeliveryScreen()));
      await tester.pump();
      final fee = PricingService.instance.deliveryFragileSurcharge;
      await tester.scrollUntilVisible(
          find.textContaining('+GHS ${fee.toStringAsFixed(2)}'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('+GHS ${fee.toStringAsFixed(2)}'),
          findsOneWidget);
    });

    for (final scale in const [1.0, 1.3]) {
      testWidgets('no overflow at 320dp, text x$scale', (tester) async {
        await _setView(tester, const Size(320, 640));
        await tester.pumpWidget(_app(const DeliveryScreen(), textScale: scale));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.drag(
            find.byType(Scrollable).first, const Offset(0, -4000));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('DeliveryVehicleScreen', () {
    testWidgets('no fare or confirm until the route is measured',
        (tester) async {
      await _setView(tester, const Size(390, 844));
      final route = _FakeRouteService();
      await tester.pumpWidget(_app(_vehicleScreen(),
          overrides: [routeServiceProvider.overrideWithValue(route)]));
      await tester.pump();

      var button =
          tester.widget<CtsPrimaryButton>(find.byType(CtsPrimaryButton));
      expect(button.label, 'Calculating fare…');
      expect(button.onPressed, isNull);
      expect(find.text('Calculating…'), findsNWidgets(2)); // both vehicles

      route.completer.complete(
          const RouteResult(points: [], distanceKm: 7.2, durationMin: 20));
      await tester.pump();
      button = tester.widget<CtsPrimaryButton>(find.byType(CtsPrimaryButton));
      expect(button.label, 'Confirm Okada delivery');
      expect(button.onPressed, isNotNull);
      expect(find.text('Calculating…'), findsNothing);
    });

    testWidgets('only Okada uses a photo; no invented arrival times',
        (tester) async {
      await _setView(tester, const Size(390, 844));
      final route = _FakeRouteService()..completer.complete(null);
      await tester.pumpWidget(_app(
          _vehicleScreen(vehicles: const ['Okada', 'Aboboya', 'Mini Truck']),
          overrides: [routeServiceProvider.overrideWithValue(route)]));
      await tester.pump();
      expect(find.byType(ServiceImage), findsOneWidget);
      expect(find.textContaining('away'), findsNothing);
    });

    for (final scale in const [1.0, 1.3]) {
      testWidgets('no overflow at 320dp, text x$scale', (tester) async {
        await _setView(tester, const Size(320, 640));
        final route = _FakeRouteService()..completer.complete(null);
        await tester.pumpWidget(_app(_vehicleScreen(),
            textScale: scale,
            overrides: [routeServiceProvider.overrideWithValue(route)]));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.drag(
            find.byType(Scrollable).first, const Offset(0, -3000));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
