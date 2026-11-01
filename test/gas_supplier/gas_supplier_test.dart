// Gas supplier ordering in the passenger app: the repository's money
// ordering (no hold unless the server says ordering is on; the server's
// total is held; a refused payment returns the hold) and the screens.
import 'dart:async';

import 'package:cts_transport_app/features/gas_supplier/data/gas_supplier_repository.dart';
import 'package:cts_transport_app/features/gas_supplier/domain/gas_supplier_models.dart';
import 'package:cts_transport_app/features/gas_supplier/presentation/gas_entry_screen.dart';
import 'package:cts_transport_app/features/gas_supplier/presentation/gas_supplier_order_screen.dart';
import 'package:cts_transport_app/features/gas_supplier/presentation/gas_supplier_tracking_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeServer {
  bool enabled = true;
  final calls = <String, Map<String, dynamic>>{};
  final order = <String>[];
  final holds = <double>[];
  GasSupplierFailure? payFailure;
  /// Thrown by successive pay calls, before payFailure applies.
  final payFailures = <Object>[];
  Object? refundFailure;
  String? createStatus;
  List<GasSupplierOrderView> active = const [];
  final controller = StreamController<GasSupplierOrderView?>.broadcast();
  final routes = <double, (int, int)>{};
  bool withEta = true;

  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> data) async {
    order.add(name);
    calls[name] = data;
    switch (name) {
      case 'gasSupplierOrderingStatus':
        return {'enabled': enabled};
      case 'listGasSupplierOptions':
        return {'options': [{'supplierId': 's1', 'supplierName': 'Tema Gas', 'stationId': 'st1', 'stationName': 'Tema Station', 'productId': 'p1', 'brand': 'goGas', 'distanceKm': 1.3}]};
      case 'quoteGasSupplierOrder':
        // The road route by destination latitude ([metres, drive minutes]), as the server would measure it.
        final lat = ((data['location'] as Map)['latitude'] as num).toDouble();
        final (metres, drive) = routes[lat] ?? (2900, 9);
        return {'quoteId': 'q1', 'expiresAt': DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch,
          'selection': {'supplierId': 's1', 'supplierName': 'Tema Gas', 'stationId': 'st1', 'stationName': 'Tema Station',
            'productId': 'p1', 'brand': 'goGas', 'orderType': 'exchangeEmpty', 'cylinderSize': 'kg12_5'},
          'pricing': {'unitPrice': 150, 'quantity': data['quantity'], 'productAmount': 150.0 * (data['quantity'] as int), 'handlingFee': 0, 'deliveryFee': 14.5, 'total': 150.0 * (data['quantity'] as int) + 14.5,
            'routeDistanceMeters': metres, if (withEta) 'eta': {'minutes': 25 + drive, 'driveMinutes': drive}}};
      case 'createGasSupplierOrder':
        return {'orderId': 'q1', 'total': 314.5, 'alreadyCreated': createStatus != null, if (createStatus != null) 'status': createStatus};
      case 'payGasSupplierOrder':
        if (payFailures.isNotEmpty) throw payFailures.removeAt(0);
        if (payFailure != null) throw payFailure!;
        return {'orderId': 'q1', 'status': 'pendingApproval'};
      case 'refundEscrowOnError':
        if (refundFailure != null) throw refundFailure!;
        return {'success': true};
      default:
        return {'success': true};
    }
  }

  Future<String> hold(double amount) async {
    holds.add(amount);
    return 'esc1';
  }

  GasSupplierRepository repo() => GasSupplierRepository(call: call, hold: hold, watch: (_) => controller.stream, activeOrders: () async => active);
  int count(String name) => order.where((n) => n == name).length;
}

const DeliveryPoint home = (address: 'Home', latitude: 5.68, longitude: -0.01);
const transport = GasSupplierFailure('deadline-exceeded', null, 'timeout');

GasSupplierQuote quoteWithTotal(double total) => GasSupplierQuote(quoteId: 'q1', expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    unitPrice: 1, quantity: 1, productAmount: 1, handlingFee: 0, deliveryFee: 0, total: total);

void main() {
  group('repository', () {
    test('holds nothing when supplier ordering is off', () async {
      final s = FakeServer()..enabled = false;
      await expectLater(s.repo().placeAndPay(quoteWithTotal(100)), throwsA(isA<GasSupplierFailure>().having((e) => e.reason, 'reason', 'gas_supplier_fulfilment_disabled')));
      expect(s.holds, isEmpty);
      expect(s.order, ['gasSupplierOrderingStatus']);
    });

    test('a status callable that fails or is missing counts as off', () async {
      final repo = GasSupplierRepository(call: (n, d) async => throw const GasSupplierFailure('not-found', null, 'x'), hold: (_) async => 'e');
      expect(await repo.orderingAvailable(), isFalse);
    });

    test('holds exactly the total the server returned when creating the order, then has the server verify it', () async {
      final s = FakeServer();
      // The quote shown says 999; the hold uses the created order's server total.
      expect(await s.repo().placeAndPay(quoteWithTotal(999)), 'q1');
      expect(s.holds, [314.5]);
      expect(s.order, ['gasSupplierOrderingStatus', 'createGasSupplierOrder', 'payGasSupplierOrder']);
      expect(s.calls['payGasSupplierOrder'], {'orderId': 'q1', 'escrowId': 'esc1'});
      expect(s.calls['createGasSupplierOrder'], {'quoteId': 'q1'});
    });

    test('a refused payment returns the hold at once', () async {
      final s = FakeServer()..payFailure = const GasSupplierFailure('failed-precondition', 'product_unavailable', 'This product is no longer available. Please choose another.');
      await expectLater(s.repo().placeAndPay(quoteWithTotal(1)), throwsA(isA<GasSupplierFailure>()));
      expect(s.order.last, 'refundEscrowOnError');
      expect(s.calls['refundEscrowOnError'], {'escrowId': 'esc1', 'reason': 'gas_supplier_payment_refused'});
    });

    test('sends only ids, choices and location: never a price', () async {
      final s = FakeServer();
      final repo = s.repo();
      final o = (await repo.options(orderType: 'exchangeEmpty', cylinderSize: 'kg12_5', latitude: 5.68, longitude: -0.01)).single;
      await repo.quote(o, quantity: 2, latitude: 5.68, longitude: -0.01, address: 'Home');
      expect(s.calls['quoteGasSupplierOrder']!.keys.toSet(), {'supplierId', 'stationId', 'productId', 'quantity', 'location', 'address'});
    });

    test('a repeat for an order the server reports as paid holds nothing and returns the order', () async {
      final s = FakeServer()..createStatus = 'pendingApproval';
      expect(await s.repo().placeAndPay(quoteWithTotal(1)), 'q1');
      expect(s.holds, isEmpty);
      expect(s.count('payGasSupplierOrder'), 0);
    });

    test('a lost pay response is retried with the same hold; nothing is refunded', () async {
      final s = FakeServer()..payFailures.add(transport);
      expect(await s.repo().placeAndPay(quoteWithTotal(1)), 'q1');
      expect(s.holds, [314.5]);
      expect(s.count('payGasSupplierOrder'), 2);
      expect(s.calls['payGasSupplierOrder'], {'orderId': 'q1', 'escrowId': 'esc1'});
      expect(s.count('refundEscrowOnError'), 0);
    });

    test('non-Firebase errors (no connection) are retried the same way', () async {
      final s = FakeServer()..payFailures.add(Exception('socket closed'));
      expect(await s.repo().placeAndPay(quoteWithTotal(1)), 'q1');
      expect(s.count('payGasSupplierOrder'), 2);
    });

    test('when pay keeps failing but the server already bound the hold, the order counts as paid', () async {
      final s = FakeServer()
        ..payFailures.addAll([transport, transport])
        ..refundFailure = const GasSupplierFailure('failed-precondition', null, 'Escrow already attached to an order');
      expect(await s.repo().placeAndPay(quoteWithTotal(1)), 'q1');
      expect(s.count('refundEscrowOnError'), 1);
    });

    test('when pay keeps failing and the hold was not bound, it is returned and the error shown', () async {
      final s = FakeServer()..payFailures.addAll([transport, transport]);
      await expectLater(s.repo().placeAndPay(quoteWithTotal(1)), throwsA(isA<GasSupplierFailure>()));
      expect(s.count('refundEscrowOnError'), 1);
    });

    test('a duplicate pay for an order paid meanwhile returns the extra hold and shows the order', () async {
      final s = FakeServer()..payFailure = const GasSupplierFailure('failed-precondition', 'order_not_awaiting_payment', 'x');
      expect(await s.repo().placeAndPay(quoteWithTotal(1)), 'q1');
      expect(s.count('payGasSupplierOrder'), 1, reason: 'a server refusal is not retried');
      expect(s.calls['refundEscrowOnError'], {'escrowId': 'esc1', 'reason': 'gas_supplier_payment_refused'});
    });

    test('a failed hold (insufficient balance) never calls pay', () async {
      final s = FakeServer();
      final repo = GasSupplierRepository(call: s.call, hold: (_) async => throw const GasSupplierFailure('failed-precondition', 'hold_failed', 'Insufficient balance'));
      await expectLater(repo.placeAndPay(quoteWithTotal(1)), throwsA(isA<GasSupplierFailure>().having((e) => e.reason, 'reason', 'hold_failed')));
      expect(s.count('payGasSupplierOrder'), 0);
      expect(s.count('refundEscrowOnError'), 0);
    });
  });

  group('models', () {
    test('passengers may cancel only before a driver is assigned; the code shows once a driver is involved', () {
      expect(['awaiting_payment', 'pendingApproval', 'confirmed'].every(passengerCanCancel), isTrue);
      expect(['driverAssigned', 'atStation', 'outForDelivery', 'delivered', 'cancelled'].any(passengerCanCancel), isFalse);
      expect(showCompletionCode('outForDelivery'), isTrue);
      expect(showCompletionCode('pendingApproval'), isFalse);
      expect(supplierOrderTypes.contains('pickupAndReturn'), isFalse);
    });

    test('server refusal reasons become plain messages', () {
      expect(gasSupplierMessage('quote_expired', 'x'), contains('expired'));
      expect(gasSupplierMessage('something_new', 'Server text'), 'Server text');
      // Server-priced road route: no route or no usable rates means no price.
      for (final r in ['routing_timeout', 'routing_failed', 'route_distance_invalid']) {
        expect(gasSupplierMessage(r, 'x'), contains('measure the delivery route'));
      }
      expect(gasSupplierMessage('route_unavailable', 'x'), contains('road route'));
      expect(gasSupplierMessage('pricing_unavailable', 'x'), contains('unavailable'));
      expect(gasSupplierMessage('routing_not_configured', 'x'), contains('unavailable'));
      expect(gasSupplierMessage('supplier_riders_not_supported', 'x'), contains('not taking orders'));
      // Phase 2A: a missing station or one without usable coordinates reads
      // like any other unavailable station, never as a server error.
      for (final r in ['station_not_found', 'station_location_invalid', 'station_not_verified']) {
        expect(gasSupplierMessage(r, 'x'), 'This station is not available right now.', reason: r);
      }
      // No route time or no usable timing: no price, never a guessed ETA.
      expect(gasSupplierMessage('route_duration_invalid', 'x'), contains('measure the delivery route'));
      expect(gasSupplierMessage('eta_config_invalid', 'x'), contains('unavailable'));
      expect(gasSupplierMessage('invalid_location', 'x'), contains('valid delivery address'));
      for (final r in ['commission_terms_missing', 'commission_terms_inactive', 'commission_terms_unapproved']) {
        expect(gasSupplierMessage(r, 'x'), 'Gas supplier orders are not available right now.', reason: r);
      }
    });

    test("the quote and the order carry the server's route and estimate, and nothing is guessed without one", () {
      final q = GasSupplierQuote.fromMap({'quoteId': 'q', 'expiresAt': 0,
        'selection': {'supplierName': 'Goil', 'stationName': 'Kaneshi', 'brand': 'goil', 'orderType': 'exchangeEmpty', 'cylinderSize': 'kg6'},
        'pricing': {'unitPrice': 100, 'quantity': 1, 'productAmount': 100, 'handlingFee': 5, 'deliveryFee': 12, 'total': 117,
          'routeDistanceMeters': 7900, 'eta': {'minutes': 46, 'driveMinutes': 21}}});
      expect([q.routeDistanceKm, q.eta!.minutes, q.eta!.driveMinutes, q.supplierName, q.stationName, q.cylinderSize], [7.9, 46, 21, 'Goil', 'Kaneshi', 'kg6']);
      final old = GasSupplierQuote.fromMap({'quoteId': 'q', 'expiresAt': 0, 'pricing': {'deliveryFee': 12, 'total': 117}});
      expect([old.eta, old.routeDistanceKm, old.supplierName], [null, null, null]);
      final at = DateTime(2026, 10, 30, 14, 5);
      final o = GasSupplierOrderView.fromMap('o1', {'status': 'pendingApproval', 'orderType': 'exchangeEmpty', 'cylinderSize': 'kg6', 'quantity': 1,
        'estimatedDeliveryAt': at, 'priceSnapshot': {'total': 117, 'deliveryFee': 12, 'routeDistanceMeters': 7900, 'brand': 'goil'}});
      expect([o.estimatedDeliveryAt, o.deliveryFee, o.routeDistanceKm, o.brand, o.quantity], [at, 12, 7.9, 'goil', 1]);
      expect(gasDurationLabel(46), '46 min');
      expect(gasDurationLabel(65), '1 h 05 min');
    });
  });

  group('screens', () {
    testWidgets('shows only an unavailable message when ordering is off', (tester) async {
      final s = FakeServer()..enabled = false;
      await tester.pumpWidget(MaterialApp(home: GasSupplierOrderScreen(initialDelivery: home, repository: s.repo())));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gs-unavailable')), findsOneWidget);
      expect(find.byKey(const Key('gs-find')), findsNothing);
    });

    testWidgets('find, price, pay, then track with the completion code and no cancel once a driver is assigned', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final s = FakeServer();
      await tester.pumpWidget(MaterialApp(home: GasSupplierOrderScreen(initialDelivery: home, repository: s.repo())));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gs-find')));
      await tester.pump();
      await tester.tap(find.text('Tema Gas'));
      await tester.pump();
      expect(find.textContaining('Confirm and pay GH₵ 164.50'), findsOneWidget);
      await tester.tap(find.byKey(const Key('gs-pay')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(GasSupplierTrackingScreen), findsOneWidget);
      s.controller.add(const GasSupplierOrderView(id: 'q1', status: 'pendingApproval', total: 164.5, completionCode: '4821'));
      await tester.pump();
      // The shared Gas tracking: cancel while waiting, no code before a driver.
      expect(find.text('Cancel order', skipOffstage: false), findsOneWidget);
      expect(find.byKey(const Key('gas-tracking-code'), skipOffstage: false), findsNothing);
      s.controller.add(const GasSupplierOrderView(id: 'q1', status: 'outForDelivery', total: 164.5, completionCode: '4821'));
      await tester.pump();
      expect(find.byKey(const Key('gas-tracking-code'), skipOffstage: false), findsOneWidget);
      for (final digit in '4821'.split('')) {
        expect(find.descendant(of: find.byKey(const Key('gas-tracking-code'), skipOffstage: false),
            matching: find.text(digit, skipOffstage: false)), findsOneWidget);
      }
      expect(find.text('Cancel order', skipOffstage: false), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a refused payment shows the reason and stays on the order screen', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final s = FakeServer()..payFailure = const GasSupplierFailure('failed-precondition', 'price_changed', 'The price has changed. Please get a new price.');
      await tester.pumpWidget(MaterialApp(home: GasSupplierOrderScreen(initialDelivery: home, repository: s.repo())));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gs-find')));
      await tester.pump();
      await tester.tap(find.text('Tema Gas'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gs-pay')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('gs-error')), findsOneWidget);
      expect(find.text('The price has changed. Please get a new price.'), findsOneWidget);
      expect(find.byType(GasSupplierTrackingScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('the address comes first; changing it clears the options and the price', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final s = FakeServer();
      final picks = <DeliveryPoint>[home, (address: 'Office', latitude: 5.70, longitude: -0.02)];
      await tester.pumpWidget(MaterialApp(home: GasSupplierOrderScreen(repository: s.repo(), pickDelivery: (_) async => picks.removeAt(0))));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(const Key('gs-find'))).onPressed, isNull);
      expect(find.text('Choose an address first'), findsOneWidget);
      await tester.tap(find.byKey(const Key('gs-address')));
      await tester.pump();
      expect(find.text('Home'), findsOneWidget);
      await tester.tap(find.byKey(const Key('gs-find')));
      await tester.pump();
      expect(s.calls['listGasSupplierOptions']!['location'], {'latitude': 5.68, 'longitude': -0.01});
      await tester.tap(find.text('Tema Gas'));
      await tester.pump();
      expect(find.byKey(const Key('gs-pay')), findsOneWidget);
      await tester.tap(find.byKey(const Key('gs-address')));
      await tester.pump();
      expect(find.text('Office'), findsOneWidget);
      expect(find.byKey(const Key('gs-pay')), findsNothing);
      expect(find.text('Tema Gas'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an expired price asks for a new one instead of paying', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var quotes = 0;
      final s = FakeServer();
      final repo = GasSupplierRepository(
        call: (name, data) async {
          if (name != 'quoteGasSupplierOrder') return s.call(name, data);
          quotes++;
          final r = await s.call(name, data);
          // The first quote is already expired.
          return {...r, if (quotes == 1) 'expiresAt': DateTime.now().subtract(const Duration(seconds: 1)).millisecondsSinceEpoch};
        },
        hold: s.hold,
        activeOrders: () async => const [],
      );
      await tester.pumpWidget(MaterialApp(home: GasSupplierOrderScreen(initialDelivery: home, repository: repo)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gs-find')));
      await tester.pump();
      await tester.tap(find.text('Tema Gas'));
      await tester.pump();
      expect(find.text('Get a new price'), findsOneWidget);
      await tester.tap(find.byKey(const Key('gs-pay')));
      await tester.pump();
      expect(quotes, 2);
      expect(s.holds, isEmpty);
      expect(find.textContaining('Confirm and pay'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("the price shows what the server priced, its road distance and ETA; a new address gets its own", (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final s = FakeServer();
      s.routes[5.68] = (1800, 5);
      s.routes[5.70] = (7900, 21);
      final picks = <DeliveryPoint>[(address: 'Office', latitude: 5.70, longitude: -0.05)];
      await tester.pumpWidget(MaterialApp(home: GasSupplierOrderScreen(initialDelivery: home, repository: s.repo(), pickDelivery: (_) async => picks.removeAt(0))));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gs-find')));
      await tester.pump();
      expect(find.textContaining('km away (straight line)'), findsOneWidget, reason: 'the list distance is not presented as the road route');
      await tester.tap(find.text('Tema Gas'));
      await tester.pump();
      expect(find.text('Tema Gas · Tema Station'), findsOneWidget);
      expect(find.text('12.5 kg · Exchange empty cylinder · goGas'), findsOneWidget);
      expect(find.text('Delivery · 1.8 km by road'), findsOneWidget);
      expect(find.byKey(const Key('gs-eta')), findsOneWidget);
      expect(find.textContaining('about 30 min after payment (5 min on the road'), findsOneWidget);
      // A new address clears the price; its own quote has its own route and ETA.
      await tester.tap(find.byKey(const Key('gs-address')));
      await tester.pump();
      expect(find.byKey(const Key('gs-eta')), findsNothing);
      await tester.tap(find.byKey(const Key('gs-find')));
      await tester.pump();
      await tester.tap(find.text('Tema Gas'));
      await tester.pump();
      expect(s.calls['quoteGasSupplierOrder']!['location'], {'latitude': 5.70, 'longitude': -0.05});
      expect(find.text('Delivery · 7.9 km by road'), findsOneWidget);
      expect(find.textContaining('about 46 min after payment (21 min on the road'), findsOneWidget);
      // Changing the quantity clears the price too.
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.byKey(const Key('gs-pay')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without an estimate from the server, none is shown', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final s = FakeServer()..withEta = false;
      await tester.pumpWidget(MaterialApp(home: GasSupplierOrderScreen(initialDelivery: home, repository: s.repo())));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gs-find')));
      await tester.pump();
      await tester.tap(find.text('Tema Gas'));
      await tester.pump();
      expect(find.byKey(const Key('gs-pay')), findsOneWidget);
      expect(find.byKey(const Key('gs-eta')), findsNothing);
      expect(find.textContaining('min after payment'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tracking shows the order, its delivery fee and the estimate until it is delivered, then the receipt', (tester) async {
      final s = FakeServer();
      final at = DateTime(2026, 10, 30, 14, 5);
      GasSupplierOrderView view(String status) => GasSupplierOrderView(id: 'o1', status: status, total: 117, deliveryFee: 12, routeDistanceKm: 7.9,
          orderType: 'exchangeEmpty', cylinderSize: 'kg6', brand: 'goil', quantity: 1, estimatedDeliveryAt: at,
          // As the server records it: held while in progress, captured on delivery.
          paymentStatus: status == 'delivered' ? 'captured' : 'held');
      await tester.pumpWidget(MaterialApp(home: GasSupplierTrackingScreen(orderId: 'o1', repository: s.repo())));
      s.controller.add(view('outForDelivery'));
      await tester.pump();
      // In the shared order summary and info lines.
      expect(find.text('1 × 6 kg', skipOffstage: false), findsOneWidget);
      expect(find.text('Exchange empty cylinder · goil', skipOffstage: false), findsOneWidget);
      expect(find.text('Delivery fee · 7.9 km by road', skipOffstage: false), findsOneWidget);
      expect(find.text('GH₵ 12.00', skipOffstage: false), findsOneWidget);
      expect(find.text('Estimated delivery: by 2:05 PM', skipOffstage: false), findsOneWidget);
      s.controller.add(view('delivered'));
      await tester.pump();
      expect(find.textContaining('Estimated delivery', skipOffstage: false), findsNothing);
      expect(find.text('Paid GH₵ 117.00 from your wallet', skipOffstage: false), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a paid order in progress can be tracked again from the order screen', (tester) async {
      final s = FakeServer()..active = const [GasSupplierOrderView(id: 'o9', status: 'confirmed', total: 164.5)];
      await tester.pumpWidget(MaterialApp(home: GasSupplierOrderScreen(initialDelivery: home, repository: s.repo())));
      await tester.pump();
      expect(find.byKey(const Key('gs-active-o9')), findsOneWidget);
      await tester.tap(find.byKey(const Key('gs-active-o9')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(GasSupplierTrackingScreen), findsOneWidget);
      s.controller.add(const GasSupplierOrderView(id: 'o9', status: 'confirmed', total: 164.5));
      await tester.pump();
      expect(find.text('Order: o9', skipOffstage: false), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test("an own-rider order skips the CTSGo driver's steps", () {
    expect(supplierOrderStepsFor('supplier_rider'), ['pendingApproval', 'confirmed', 'outForDelivery', 'delivered']);
    expect(supplierOrderStepsFor('ctsgo_driver'), supplierOrderSteps);
    expect(supplierOrderStepsFor(null), supplierOrderSteps);
    expect(GasSupplierOrderView.fromMap('o', {'status': 'confirmed', 'deliveryMode': 'supplier_rider'}).deliveryMode, 'supplier_rider');
  });

  test('an order the supplier never answered says so in words', () {
    expect(supplierCancelReasonLabel('supplier_no_response'), 'The supplier did not respond in time.');
    expect(supplierCancelReasonLabel('Out of stock today'), 'Out of stock today');
  });

  group('Gas entry', () {
    Widget entry(FakeServer s) => MaterialApp(home: GasEntryScreen(
          repository: s.repo(),
          legacyBuilder: (_) => const Text('legacy gas'),
          supplierBuilder: (_) => const Text('supplier gas'),
        ));

    testWidgets('opens supplier ordering when the server reports it is on', (tester) async {
      await tester.pumpWidget(entry(FakeServer()));
      expect(find.byKey(const Key('gas-entry-checking')), findsOneWidget);
      await tester.pump();
      expect(find.text('supplier gas'), findsOneWidget);
    });

    testWidgets('keeps the existing Gas screen when it is off or the check fails', (tester) async {
      await tester.pumpWidget(entry(FakeServer()..enabled = false));
      await tester.pump();
      expect(find.text('legacy gas'), findsOneWidget);
      await tester.pumpWidget(MaterialApp(home: GasEntryScreen(
        repository: GasSupplierRepository(call: (n, d) async => throw const GasSupplierFailure('not-found', null, 'x'), hold: (_) async => 'e'),
        legacyBuilder: (_) => const Text('legacy gas'),
        supplierBuilder: (_) => const Text('supplier gas'),
      )));
      await tester.pump();
      expect(find.text('legacy gas'), findsOneWidget);
    });

    testWidgets('while off, supplier orders in progress stay reachable and can still be cancelled', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final s = FakeServer()
        ..enabled = false
        ..active = const [GasSupplierOrderView(id: 'o7', status: 'pendingApproval', total: 164.5)];
      await tester.pumpWidget(entry(s));
      await tester.pump();
      expect(find.text('legacy gas'), findsNothing);
      expect(find.byKey(const Key('gs-active-o7')), findsOneWidget);
      await tester.tap(find.byKey(const Key('gs-active-o7')));
      // The tracking screen spins until its stream answers: pump, never settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      s.controller.add(const GasSupplierOrderView(id: 'o7', status: 'pendingApproval', total: 164.5));
      await tester.pump();
      await tester.ensureVisible(find.text('Cancel order'));
      await tester.pump();
      await tester.tap(find.text('Cancel order'));
      // The shared tracking animates while searching: pump, never settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // The shared confirmation's own "Cancel order" button.
      await tester.tap(find.text('Cancel order').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(s.calls['cancelGasSupplierOrder'], {'orderId': 'o7'});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('while off, the existing Gas screen is one tap from the in-progress list', (tester) async {
      final s = FakeServer()
        ..enabled = false
        ..active = const [GasSupplierOrderView(id: 'o7', status: 'confirmed', total: 164.5)];
      await tester.pumpWidget(entry(s));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gas-entry-order-gas')));
      await tester.pumpAndSettle();
      expect(find.text('legacy gas'), findsOneWidget);
    });

    testWidgets('by default routes to the real screens', (tester) async {
      await tester.pumpWidget(MaterialApp(home: GasEntryScreen(repository: FakeServer().repo())));
      await tester.pump();
      expect(find.byType(GasSupplierOrderScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
