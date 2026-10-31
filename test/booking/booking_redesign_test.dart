// Delivery and Gas booking redesign: honest prices, only the fields that
// apply to the chosen gas service, real help, and layouts that hold up on
// small phones with large text or an open keyboard.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/core/widgets/cts_booking.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/delivery/domain/delivery_quote.dart';
import 'package:cts_transport_app/features/delivery/presentation/delivery_screen.dart';
import 'package:cts_transport_app/features/delivery/presentation/delivery_vehicle_screen.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/gas/presentation/screens/gas_order_screen.dart';
import 'package:cts_transport_app/features/ride/services/route_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class _PendingRoute extends RouteService {
  @override
  Future<RouteResult?> getRoute(LatLng origin, LatLng destination) =>
      Completer<RouteResult?>().future;
}

/// The server's Delivery quote, still on its way.
class _PendingQuote extends DeliveryQuoteService {
  @override
  Future<ServerDeliveryQuote> quote({
    required GeoPoint pickup,
    required GeoPoint dropoff,
    required String vehicleType,
    required String weightTier,
    required bool isFragile,
    required bool requiresHelpers,
  }) =>
      Completer<ServerDeliveryQuote>().future;
}

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  Size size = const Size(390, 844),
  double textScale = 1.0,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      routeServiceProvider.overrideWithValue(_PendingRoute()),
      deliveryQuoteServiceProvider.overrideWithValue(_PendingQuote()),
    ],
    child: MaterialApp(
      routes: {
        '/help-support': (_) => const Scaffold(body: Text('HELP SCREEN')),
      },
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            viewInsets: viewInsets,
          ),
          child: screen,
        ),
      ),
    ),
  ));
  await tester.pump();
}

Future<void> _reveal(WidgetTester tester, Finder f, {double dy = -150}) =>
    tester.dragUntilVisible(
        f.hitTestable(), find.byType(CustomScrollView), Offset(0, dy));

const _vehicle = DeliveryVehicleScreen(
  pickup: 'Kwame Nkrumah Circle, Accra — a deliberately long pickup address',
  pickupGeoPoint: GeoPoint(5.57, -0.21),
  dropoff: 'Kotoka International Airport, Terminal 3, Accra, Ghana',
  dropoffGeoPoint: GeoPoint(5.60, -0.17),
  weightTier: 'Medium',
  weightRange: '5–20 kg',
  eligibleVehicles: ['Okada', 'Aboboya'],
  parcelType: 'Package',
  isFragile: true,
  requiresHelpers: false,
  hasPhoto: false,
  receiverPhone: '0241234567',
  receiverName: 'Ama',
  notes: '',
);

void main() {
  group('gas order', () {
    testWidgets('no delivery fee or total before an address is set',
        (tester) async {
      await _pump(tester, const GasOrderScreen());
      final button =
          tester.widget<CtsPrimaryButton>(find.byType(CtsPrimaryButton));
      expect(button.label, 'Place gas order');
      expect(button.trailingText, isNull);
      expect(button.onPressed, isNull);

      await _reveal(tester, find.text('Set your address'));
      expect(find.text('After address'), findsOneWidget);
      // Release v5: the delivery fee is a flat charge (the server's price).
      expect(find.textContaining('total appears once your address is set'),
          findsOneWidget);
    });

    testWidgets('pickup & return shows only what applies', (tester) async {
      await _pump(tester, const GasOrderScreen());
      await _reveal(tester, find.text('Gas provider'));
      expect(find.text('Gas provider'), findsOneWidget);

      await _reveal(tester, find.text('Pickup & Return'), dy: 150);
      await tester.tap(find.text('Pickup & Return'));
      await tester.pump();

      expect(find.text('Gas provider'), findsNothing);
      await _reveal(tester, find.text('Collection & return address'));
      expect(find.text('Collection & return address'), findsOneWidget);
      await _reveal(tester, find.text('Your cylinder is ready for collection'));
      expect(
          find.text('Valid empty cylinder ready for exchange'), findsNothing);
    });

    testWidgets('a new cylinder does not ask for an empty one', (tester) async {
      await _pump(tester, const GasOrderScreen());
      await _reveal(tester, find.text('New Cylinder'));
      await tester.tap(find.text('New Cylinder'));
      await tester.pump();
      await _reveal(
          tester, find.text('I confirm all safety requirements are met'));
      expect(
          find.text('Valid empty cylinder ready for exchange'), findsNothing);
      expect(find.text('Cylinder in good condition — no leaks or damage'),
          findsNothing);
    });

    testWidgets('quantity only for commercial bulk', (tester) async {
      await _pump(tester, const GasOrderScreen());
      expect(find.text('Number of cylinders'), findsNothing);
      await _reveal(tester, find.text('Commercial Bulk'));
      await tester.tap(find.text('Commercial Bulk'));
      await tester.pump();
      await _reveal(tester, find.text('Number of cylinders'));
      expect(find.text('Number of cylinders'), findsOneWidget);
    });

    testWidgets('providers show the real price effect', (tester) async {
      await _pump(tester, const GasOrderScreen());
      await _reveal(tester, find.text(GasBrand.totalEnergies.displayName));
      final pct = ((GasBrand.totalEnergies.priceMultiplier - 1) * 100).round();
      // Compact chips: a short badge, with the full note in the label.
      expect(find.text('+$pct%'), findsOneWidget);
      expect(
          find.bySemanticsLabel(
              '${GasBrand.totalEnergies.displayName}, +$pct% on gas'),
          findsOneWidget);
      expect(find.text('Optional · standard price unless marked'),
          findsOneWidget);
    });

    testWidgets('help opens the real support screen, no placeholder number',
        (tester) async {
      await _pump(tester, const GasOrderScreen());
      await tester.tap(find.bySemanticsLabel('Help and support'));
      await tester.pumpAndSettle();
      expect(find.text('HELP SCREEN'), findsOneWidget);
      expect(find.textContaining('XX XXX'), findsNothing);
    });
  });

  group('delivery', () {
    testWidgets('step 1 is labelled and has a clear next step', (tester) async {
      await _pump(tester, const DeliveryScreen());
      expect(find.text('STEP 1 OF 2 · ROUTE & PARCEL'), findsOneWidget);
      expect(find.byType(CtsFormSection), findsWidgets);
      expect(find.text('Optional'), findsNothing); // optional section below
    });

    testWidgets('no price before the route is measured', (tester) async {
      await _pump(tester, _vehicle);
      final button =
          tester.widget<CtsPrimaryButton>(find.byType(CtsPrimaryButton));
      expect(button.trailingText, isNull);
      expect(button.onPressed, isNull);
      // In the route summary and in the price panel.
      expect(find.text('Measuring route…'), findsWidgets);
      // No fare amount yet (the fragile chip's surcharge is a set fee).
      expect(find.textContaining(RegExp(r'^GHS ')), findsNothing);
    });
  });

  group('layout', () {
    final screens = <String, Widget>{
      'delivery step 1': const DeliveryScreen(),
      'delivery step 2': _vehicle,
      'gas order': const GasOrderScreen(),
    };

    screens.forEach((name, screen) {
      testWidgets('$name fits 320x568 at 2x text', (tester) async {
        await _pump(tester, screen, size: const Size(320, 568), textScale: 2.0);
        expect(tester.takeException(), isNull);
        await tester.drag(
            find.byType(Scrollable).first, const Offset(0, -4000));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name keeps working with the keyboard open', (tester) async {
        await _pump(tester, screen,
            size: const Size(360, 740),
            viewInsets: const EdgeInsets.only(bottom: 300));
        expect(tester.takeException(), isNull);
        // The action bar stays above the keyboard.
        final bar = tester.getRect(find.byType(CtsBookingBar));
        expect(bar.bottom, lessThanOrEqualTo(740 - 300 + 0.5));
      });
    });
  });
}
