// Delivery pricing (release v5 round 3): the vehicle screen shows only the
// server's quote (functions/delivery_quotes.js quoteDelivery), never lets an
// older quote overwrite a newer one, shows no price when the server cannot
// price the route (no local or straight-line estimate), and books exactly the
// quote: its id and total, refreshing an expiring quote and asking before a
// changed price is used.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/core/services/pricing_service.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/delivery/domain/delivery_quote.dart';
import 'package:cts_transport_app/features/delivery/models/delivery_request.dart';
import 'package:cts_transport_app/features/delivery/presentation/delivery_vehicle_screen.dart';
import 'package:cts_transport_app/features/delivery/providers/delivery_provider.dart';
import 'package:cts_transport_app/features/delivery/repositories/delivery_repositories.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _pickup = GeoPoint(5.60, -0.20);
const _dropoffA = GeoPoint(5.63, -0.15);
const _dropoffB = GeoPoint(5.70, -0.10);

int _ids = 0;

/// A server quote as quoteDelivery returns it (Okada defaults: 5 + 2.5/km, min 10).
ServerDeliveryQuote _q(double km, {double? total, DateTime? expires}) {
  final distanceCharge = 2.5 * km;
  final sub = 5 + distanceCharge;
  return ServerDeliveryQuote(
    quoteId: 'q${++_ids}',
    vehicleType: 'Okada',
    distanceKm: km,
    baseFare: 5,
    distanceCharge: distanceCharge,
    weightSurcharge: 0,
    fragileSurcharge: 0,
    helperSurcharge: 0,
    minimumFare: 10,
    minimumApplied: sub < 10,
    total: total ?? (sub < 10 ? 10 : sub),
    expiresAt: expires ?? DateTime.now().add(const Duration(minutes: 10)),
  );
}

/// One pending quote per destination, answered by the test.
class _Quotes extends DeliveryQuoteService {
  final calls = <GeoPoint, List<Completer<ServerDeliveryQuote>>>{};
  Completer<ServerDeliveryQuote> to(GeoPoint d, [int i = 0]) => calls[d]![i];
  @override
  Future<ServerDeliveryQuote> quote({
    required GeoPoint pickup,
    required GeoPoint dropoff,
    required String vehicleType,
    required String weightTier,
    required bool isFragile,
    required bool requiresHelpers,
  }) {
    final c = Completer<ServerDeliveryQuote>();
    calls.putIfAbsent(dropoff, () => []).add(c);
    return c.future;
  }
}

class _Repo implements DeliveryRepository {
  final created = <DeliveryRequest>[];
  @override
  Future<String> createDelivery(DeliveryRequest request) async {
    created.add(request);
    return 'd${created.length}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DeliveryVehicleScreen _screen({GeoPoint dropoff = _dropoffA}) =>
    DeliveryVehicleScreen(
      pickup: 'Pickup',
      pickupGeoPoint: _pickup,
      dropoff: 'Drop-off',
      dropoffGeoPoint: dropoff,
      weightTier: 'Small',
      weightRange: '0–5 kg',
      eligibleVehicles: const ['Okada'],
      parcelType: 'Package',
      isFragile: false,
      requiresHelpers: false,
      hasPhoto: false,
      receiverPhone: '0241234567',
      receiverName: 'Ama',
      notes: '',
    );

Future<void> _pump(WidgetTester tester, Widget screen,
    {required _Quotes quotes,
    _Repo? repo,
    List<(double, double)>? priceChanges,
    bool acceptChange = false}) async {
  tester.view.physicalSize = const Size(390, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      deliveryQuoteServiceProvider.overrideWithValue(quotes),
      deliveryPricingLoaderProvider.overrideWithValue(() async => true),
      deliveryRepositoryProvider.overrideWithValue(repo ?? _Repo()),
      deliveryCurrentUidProvider.overrideWithValue(() => 'customer-1'),
      deliveryStreamProvider.overrideWith((ref, id) => const Stream.empty()),
      deliveryPriceChangeConfirmProvider.overrideWithValue((_, was, now) async {
        priceChanges?.add((was, now));
        return acceptChange;
      }),
    ],
    child: MaterialApp(home: screen),
  ));
  await tester.pump();
}

/// Re-pumps the same screen (same State) with new inputs.
Future<void> _update(WidgetTester tester, Widget screen) async {
  final scope = tester.widget<ProviderScope>(find.byType(ProviderScope));
  await tester.pumpWidget(ProviderScope(
    overrides: scope.overrides,
    child: MaterialApp(home: screen),
  ));
  await tester.pump();
}

CtsPrimaryButton _button(WidgetTester tester) =>
    tester.widget<CtsPrimaryButton>(find.byType(CtsPrimaryButton));

final _anyPrice = find.textContaining(RegExp(r'GHS \d'));

Future<void> _answer(WidgetTester tester, Completer<ServerDeliveryQuote> c,
    ServerDeliveryQuote q) async {
  c.complete(q);
  await tester.pump();
  await tester.pump();
}

void main() {
  final pricing = PricingService.instance;
  tearDown(() => pricing.debugSetSettings(null));

  // The app's own calculator remains for display of the extras' labels; the
  // payable amount is the server quote (vehicle screen group below).
  group('pricing model (PricingService defaults)', () {
    // Okada: 5 + 2.5/km, min 10 · Aboboya: 15 + 4/km, min 20 ·
    // Mini Truck: 40 + 7/km, min 50 · medium +5, large +15.
    final cases = [
      (v: 'Okada', tier: 'small', km: 3.0, total: 12.50, min: false),
      (v: 'Okada', tier: 'small', km: 9.0, total: 27.50, min: false),
      (v: 'Okada', tier: 'small', km: 0.8, total: 10.00, min: true),
      (v: 'Okada', tier: 'small', km: 1.6, total: 10.00, min: true),
      (v: 'Aboboya', tier: 'medium', km: 4.0, total: 36.00, min: false),
      (v: 'Mini Truck', tier: 'large', km: 10.0, total: 125.00, min: false),
    ];
    for (final c in cases) {
      test('${c.v} ${c.tier} ${c.km} km = GHS ${c.total}', () {
        final f = pricing.deliveryFareBreakdown(c.km,
            vehicleType: c.v, weightTier: c.tier);
        expect(f.total, c.total);
        expect(f.minimumApplied, c.min);
        expect(
            pricing.calculateDeliveryFare(c.km,
                vehicleType: c.v, weightTier: c.tier),
            f.total);
      });
    }

    test('admin-configured rates replace the defaults', () {
      pricing.debugSetSettings({
        'delivery': {
          'okada': {'baseFare': 6.0, 'perKmRate': 3.0, 'minimumFare': 12.0},
        },
      });
      expect(pricing.calculateDeliveryFare(5, vehicleType: 'Okada'), 21.0);
      expect(pricing.calculateDeliveryFare(1, vehicleType: 'Okada'), 12.0);
    });

  });

  group('server quote model', () {
    test('parses quoteDelivery\'s result and rejects a malformed one', () {
      final q = ServerDeliveryQuote.fromMap({
        'quoteId': 'q1', 'vehicleType': 'Okada', 'distanceKm': 10.0,
        'durationMinutes': 18, 'baseFare': 5, 'distanceCharge': 25,
        'weightSurcharge': 0, 'fragileSurcharge': 0, 'helperSurcharge': 0,
        'minimumFare': 10, 'minimumApplied': false, 'total': 30,
        'expiresAtMillis': 1800000000000,
      });
      expect([q.quoteId, q.total, q.distanceFare], ['q1', 30.0, 30.0]);
      for (final bad in [
        <String, dynamic>{},
        {'quoteId': 'q1', 'vehicleType': 'Okada', 'expiresAtMillis': 1},
        {'quoteId': '', 'vehicleType': 'Okada', 'total': 1, 'expiresAtMillis': 1},
      ]) {
        expect(() => ServerDeliveryQuote.fromMap(bad), throwsFormatException);
      }
    });

    test('a quote expiring within a minute is due for renewal', () {
      final now = DateTime(2026, 10, 27, 12);
      expect(_q(1, expires: now.add(const Duration(seconds: 59))).expiresSoon(now), isTrue);
      expect(_q(1, expires: now.add(const Duration(minutes: 5))).expiresSoon(now), isFalse);
    });
  });

  group('vehicle screen', () {
    testWidgets('different routes show their own server price, same as the button',
        (tester) async {
      for (final (km, price) in [(3.0, 'GHS 12.50'), (9.0, 'GHS 27.50')]) {
        final quotes = _Quotes();
        await _pump(tester, _screen(), quotes: quotes);
        await _answer(tester, quotes.to(_dropoffA), _q(km));
        expect(find.text(price), findsWidgets); // card + total
        expect(_button(tester).trailingText, price);
        expect(find.text('Distance fare (${km.toStringAsFixed(1)} km by road)'),
            findsOneWidget);
        await tester.pumpWidget(const SizedBox()); // fresh State next time
      }
    });

    testWidgets('a short trip says the minimum fare applies', (tester) async {
      final quotes = _Quotes();
      await _pump(tester, _screen(), quotes: quotes);
      await _answer(tester, quotes.to(_dropoffA), _q(0.8));
      expect(_button(tester).trailingText, 'GHS 10.00');
      expect(find.text('GHS 7.00'), findsOneWidget); // 5 + 0.8 × 2.5
      expect(find.text('Minimum fare top-up'), findsOneWidget);
      expect(find.text('+GHS 3.00'), findsOneWidget);
      expect(find.textContaining('minimum fare of GHS 10.00 applies'),
          findsOneWidget);
    });

    testWidgets('no price and no booking until the server has quoted',
        (tester) async {
      final quotes = _Quotes();
      await _pump(tester, _screen(), quotes: quotes);
      expect(_anyPrice, findsNothing);
      expect(_button(tester).label, 'Calculating fare…');
      expect(_button(tester).onPressed, isNull);
    });

    testWidgets('a late quote for an old route never replaces the new one',
        (tester) async {
      final quotes = _Quotes();
      await _pump(tester, _screen(dropoff: _dropoffA), quotes: quotes);
      await _update(tester, _screen(dropoff: _dropoffB));
      await _answer(tester, quotes.to(_dropoffA), _q(2.0));
      expect(_anyPrice, findsNothing);
      expect(_button(tester).onPressed, isNull);
      await _answer(tester, quotes.to(_dropoffB), _q(9.0));
      expect(_button(tester).trailingText, 'GHS 27.50');
    });

    testWidgets('a new route answering before the old one keeps the new price',
        (tester) async {
      final quotes = _Quotes();
      await _pump(tester, _screen(dropoff: _dropoffA), quotes: quotes);
      await _update(tester, _screen(dropoff: _dropoffB));
      await _answer(tester, quotes.to(_dropoffB), _q(9.0));
      await _answer(tester, quotes.to(_dropoffA), _q(2.0));
      expect(_button(tester).trailingText, 'GHS 27.50');
    });

    testWidgets('when the server cannot price the route: no price, its reason, a retry',
        (tester) async {
      final quotes = _Quotes();
      await _pump(tester, _screen(), quotes: quotes);
      quotes.to(_dropoffA).completeError(const DeliveryQuoteException(
          'route_unavailable', 'We couldn\'t measure this route. Please try again.'));
      await tester.pump();
      await tester.pump();
      expect(_anyPrice, findsNothing);
      expect(find.textContaining('couldn\'t measure this route'), findsOneWidget);
      expect(_button(tester).label, 'Try again');
      await tester.tap(find.byType(CtsPrimaryButton));
      await tester.pump();
      await _answer(tester, quotes.to(_dropoffA, 1), _q(3.0));
      expect(_button(tester).trailingText, 'GHS 12.50');
    });

    testWidgets('a cash booking carries the quote id and exactly its total',
        (tester) async {
      final quotes = _Quotes();
      final repo = _Repo();
      await _pump(tester, _screen(), quotes: quotes, repo: repo);
      await _answer(tester, quotes.to(_dropoffA), _q(9.0));
      final quoteId = 'q$_ids';
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await tester.tap(find.byType(CtsPrimaryButton));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final r = repo.created.single;
      expect([r.deliveryQuoteId, r.estimatedFare, r.paymentMethod],
          [quoteId, 27.5, 'cash']);
      expect(r.toFirestore()['deliveryQuoteId'], quoteId);
      await tester.pumpWidget(const SizedBox()); // dispose the matching screen
      await tester.pump(const Duration(seconds: 1)); // its dot timer runs out
    });

    testWidgets('an expiring quote is renewed; a changed price is booked only if accepted',
        (tester) async {
      for (final accept in [false, true]) {
        final quotes = _Quotes();
        final repo = _Repo();
        final changes = <(double, double)>[];
        await _pump(tester, _screen(), quotes: quotes, repo: repo,
            priceChanges: changes, acceptChange: accept);
        await _answer(tester, quotes.to(_dropoffA),
            _q(9.0, expires: DateTime.now().add(const Duration(seconds: 20))));
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await tester.tap(find.byType(CtsPrimaryButton));
        await tester.pump();
        await _answer(tester, quotes.to(_dropoffA, 1), _q(9.0, total: 29.0));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(changes, [(27.5, 29.0)]);
        if (accept) {
          final r = repo.created.single;
          expect([r.deliveryQuoteId, r.estimatedFare], ['q$_ids', 29.0]);
        } else {
          expect(repo.created, isEmpty, reason: 'nothing booked at the new price');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1)); // matching screen's dot timer
      }
    });
  });
}
