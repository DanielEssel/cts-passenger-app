// After payment a supplier order is followed in the shared Gas tracking
// experience (GasTrackingBody, also used by the original gas_orders flow).
// gasSupplierTrackingView maps only genuinely equivalent server states
// (gas_supplier_fulfilment.js): searching while the supplier decides and
// delivery is arranged, active only once a driver has accepted (the server
// writes driverId) or the supplier has handed the cylinder to its own rider.
// Nothing suggests a driver before.
import 'dart:async';

import 'package:cts_transport_app/core/utils/cedi_format.dart';
import 'package:cts_transport_app/features/gas_supplier/data/gas_supplier_repository.dart';
import 'package:cts_transport_app/features/gas_supplier/domain/gas_supplier_models.dart';
import 'package:cts_transport_app/features/gas_supplier/domain/gas_supplier_tracking.dart';
import 'package:cts_transport_app/features/tracking/domain/tracking_view.dart';
import 'package:cts_transport_app/features/gas_supplier/presentation/gas_supplier_order_screen.dart';
import 'package:cts_transport_app/features/gas_supplier/presentation/gas_supplier_tracking_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

GasSupplierOrderView order(Map<String, dynamic> fields) => GasSupplierOrderView.fromMap('o1', {
      'priceSnapshot': {'total': 117, 'deliveryFee': 12},
      'deliveryAddress': '12 Palm St',
      'completionCode': '4821',
      ...fields,
    });

const paid = {'payment': {'status': 'held'}};

void main() {
  group('phase rule', () {
    test('JR-01 each server status maps to its phase', () {
      expect(supplierOrderPhase(order({'status': 'awaiting_payment'})), GasSupplierPhase.payment);
      expect(supplierOrderPhase(order({'status': 'pendingApproval', ...paid})), GasSupplierPhase.processing);
      expect(supplierOrderPhase(order({'status': 'confirmed', 'deliveryMode': 'ctsgo_driver', ...paid})), GasSupplierPhase.processing);
      expect(supplierOrderPhase(order({'status': 'driverAssigned', 'driverId': 'd1', ...paid})), GasSupplierPhase.delivering);
      expect(supplierOrderPhase(order({'status': 'atStation', 'driverId': 'd1', ...paid})), GasSupplierPhase.delivering);
      expect(supplierOrderPhase(order({'status': 'outForDelivery', 'driverId': 'd1', ...paid})), GasSupplierPhase.delivering);
      expect(supplierOrderPhase(order({'status': 'delivered'})), GasSupplierPhase.delivered);
      expect(supplierOrderPhase(order({'status': 'cancelled'})), GasSupplierPhase.cancelled);
    });

    test('JR-02 a driver status without a driver from the server is never tracking', () {
      expect(supplierOrderPhase(order({'status': 'driverAssigned', ...paid})), GasSupplierPhase.processing);
      expect(supplierOrderPhase(order({'status': 'atStation', 'driverId': '', ...paid})), GasSupplierPhase.processing);
    });

    test("JR-03 the supplier's own rider is tracked from hand-over, which has no driverId", () {
      final o = order({'status': 'outForDelivery', 'deliveryMode': 'supplier_rider', ...paid});
      expect(o.hasDriver, isFalse);
      expect(supplierOrderPhase(o), GasSupplierPhase.delivering);
      expect(supplierOrderGuidance(o), "The supplier's rider is bringing your gas.");
    });

    test('JR-04 an admin release returns the order to processing and says so', () {
      final o = order({'status': 'confirmed', 'deliveryMode': 'ctsgo_driver', 'releasedDriverIds': ['d1'], ...paid});
      expect(supplierOrderPhase(o), GasSupplierPhase.processing);
      expect(o.driverReleased, isTrue);
      expect(supplierOrderGuidance(o), startsWith('Your previous driver was taken off this order'));
    });

    test('JR-05 an unknown future status is shown, never as tracking', () {
      expect(supplierOrderPhase(order({'status': 'somethingNew', 'driverId': 'd1'})), GasSupplierPhase.processing);
    });

    test('JR-06 processing wording promises only what the backend does', () {
      expect(supplierOrderGuidance(order({'status': 'pendingApproval', ...paid})),
          contains('If they do not confirm it in time, it is cancelled and your payment is returned to your wallet.'));
      expect(supplierOrderGuidance(order({'status': 'confirmed', 'deliveryMode': 'ctsgo_driver', ...paid})),
          allOf(contains('finding a driver'), contains('Live tracking starts once a driver accepts')));
      expect(supplierOrderGuidance(order({'status': 'confirmed', 'deliveryMode': 'linked_rider', ...paid})),
          contains('assigning one of their riders'));
    });
  });

  group('shared tracking state', () {
    test('JR-30 supplier states map only to equivalent tracking states', () {
      TrackingView v(Map<String, dynamic> f) => gasSupplierTrackingView(order({'deliveryMode': 'ctsgo_driver', ...paid, ...f}));
      expect(v({'status': 'pendingApproval'}).phase, TrackingPhase.searching);
      expect(v({'status': 'pendingApproval'}).headline, 'Payment confirmed');
      expect(v({'status': 'confirmed'}).phase, TrackingPhase.searching);
      expect(v({'status': 'confirmed'}).hasDriver, isFalse);
      expect(v({'status': 'driverAssigned', 'driverId': 'd1'}).phase, TrackingPhase.active);
      expect(v({'status': 'driverAssigned', 'driverId': 'd1'}).hasDriver, isTrue);
      expect(v({'status': 'atStation', 'driverId': 'd1'}).stepIndex, 2);
      expect(v({'status': 'outForDelivery', 'driverId': 'd1'}).heading, TrackingHeading.customer);
      expect(v({'status': 'delivered', 'driverId': 'd1'}).phase, TrackingPhase.completed);
      expect(v({'status': 'cancelled'}).phase, TrackingPhase.ended);
      expect(v({'status': 'somethingNew'}).phase, TrackingPhase.unknown);
    });

    test('JR-31 the refill and return legs stay the original flow\'s own', () {
      for (final steps in [gasSupplierDriverSteps, gasSupplierOwnRiderSteps]) {
        expect(steps, isNot(contains('Refilling')));
        expect(steps, isNot(contains('Returning')));
      }
      expect(gasTrackingView('pendingApproval', refillType: 'pickupAndReturn').steps, contains('Refilling'));
    });

    test('JR-32 a driver status without a driver from the server is still searching, with no driver', () {
      final v = gasSupplierTrackingView(order({'status': 'driverAssigned', 'deliveryMode': 'ctsgo_driver', ...paid}));
      expect(v.phase, TrackingPhase.searching);
      expect(v.hasDriver, isFalse);
      expect(v.headline, 'Finding a driver');
    });

    test("JR-33 the supplier's own rider: its own steps, tracked from hand-over without a driver card", () {
      final o = order({'status': 'outForDelivery', 'deliveryMode': 'supplier_rider', ...paid});
      final v = gasSupplierTrackingView(o, hasCode: true);
      expect(v.steps, gasSupplierOwnRiderSteps);
      expect(v.phase, TrackingPhase.active);
      expect(v.hasDriver, isFalse);
      expect(v.youNeedTo, 'Give the rider your 4-digit code when you receive it.');
      expect(gasSupplierTrackingView(order({'status': 'confirmed', 'deliveryMode': 'supplier_rider', ...paid})).headline,
          'The supplier is preparing your order');
    });

    test('JR-34 cancel is offered exactly where the server allows it', () {
      for (final s in supplierOrderStatusLabels.keys) {
        expect(gasSupplierTrackingView(order({'status': s, 'driverId': 'd1', ...paid})).canCancel, passengerCanCancel(s), reason: s);
      }
    });
  });

  group('shared tracking screen', () {
    late StreamController<GasSupplierOrderView?> c;
    setUp(() => c = StreamController<GasSupplierOrderView?>.broadcast());
    tearDown(() => c.close());

    Future<void> open(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: GasSupplierTrackingScreen(orderId: 'o1', stream: c.stream)));
    }

    Future<void> push(WidgetTester tester, Map<String, dynamic> fields) async {
      c.add(order(fields));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    Finder text(String t) => find.text(t, skipOffstage: false);
    Finder code() => find.byKey(const Key('gas-tracking-code'), skipOffstage: false);

    testWidgets('JR-10 paid → supplier → driver accepted → on the way → delivered', (tester) async {
      await open(tester);

      await push(tester, {'status': 'pendingApproval', ...paid});
      expect(text('Payment confirmed'), findsOneWidget);
      expect(text('Your driver'), findsNothing);
      expect(code(), findsNothing);
      expect(text('Cancel order'), findsOneWidget);

      await push(tester, {'status': 'confirmed', 'deliveryMode': 'ctsgo_driver', ...paid});
      expect(text('Finding a driver'), findsOneWidget);
      expect(text('Your driver'), findsNothing);
      expect(text('Cancel order'), findsOneWidget);

      await push(tester, {'status': 'driverAssigned', 'deliveryMode': 'ctsgo_driver', 'driverId': 'd1', ...paid});
      expect(text('A driver has accepted your order'), findsOneWidget);
      // A driver exists, but no name, phone or position is readable: none is invented.
      expect(text('Driver: Accepted your order'), findsOneWidget);
      expect(text('Your driver'), findsNothing);
      expect(text('Call driver'), findsNothing);
      expect(text('Cancel order'), findsNothing);
      expect(code(), findsOneWidget);

      await push(tester, {'status': 'outForDelivery', 'deliveryMode': 'ctsgo_driver', 'driverId': 'd1', ...paid});
      expect(text('Your gas is on its way'), findsOneWidget);
      expect(text('Share code'), findsOneWidget);

      await push(tester, {'status': 'delivered', 'deliveryMode': 'ctsgo_driver', 'driverId': 'd1', 'payment': {'status': 'captured'}});
      expect(text('Your gas was delivered'), findsOneWidget);
      expect(text('Paid GH₵ 117.00 from your wallet'), findsOneWidget);
      expect(code(), findsNothing);
      expect(text('Back to home'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('JR-11 a driver taken off the order returns the screen to finding a driver', (tester) async {
      await open(tester);
      await push(tester, {'status': 'driverAssigned', 'driverId': 'd1', 'deliveryMode': 'ctsgo_driver', ...paid});
      expect(text('Driver: Accepted your order'), findsOneWidget);
      await push(tester, {'status': 'confirmed', 'deliveryMode': 'ctsgo_driver', 'releasedDriverIds': ['d1'], ...paid});
      expect(text('Finding another driver'), findsOneWidget);
      expect(text('Driver: Accepted your order'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('JR-12 a driver status the server wrote without a driver shows no driver', (tester) async {
      await open(tester);
      await push(tester, {'status': 'driverAssigned', 'deliveryMode': 'ctsgo_driver', ...paid});
      expect(text('Finding a driver'), findsOneWidget);
      expect(text('Driver: Accepted your order'), findsNothing);
      expect(code(), findsOneWidget, reason: 'the code follows the server status (showCompletionCode), as before');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("JR-15 the supplier's own rider: preparing, then on its way with the code and no driver card", (tester) async {
      await open(tester);
      await push(tester, {'status': 'confirmed', 'deliveryMode': 'supplier_rider', ...paid});
      expect(text('The supplier is preparing your order'), findsOneWidget);
      expect(text('Preparing'), findsOneWidget);
      expect(text('At station'), findsNothing);
      await push(tester, {'status': 'outForDelivery', 'deliveryMode': 'supplier_rider', ...paid});
      expect(text('Your gas is on its way'), findsOneWidget);
      // The supplier's own rider has no driverId: no driver line.
      expect(text('Driver: Accepted your order'), findsNothing);
      expect(text('Rider: Accepted your order'), findsNothing);
      expect(code(), findsOneWidget);
      expect(text('What to do: Give the rider your 4-digit code when you receive it.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('JR-13 supplier decline and no response end in a cancelled order with its reason and refund', (tester) async {
      await open(tester);
      await push(tester, {'status': 'cancelled', 'cancelReason': 'Out of stock', 'payment': {'status': 'held'}, 'refundPending': true});
      expect(text('This order was cancelled'), findsOneWidget);
      expect(find.textContaining('Reason: Out of stock'), findsOneWidget);
      expect(find.textContaining('Your refund is being processed.'), findsOneWidget);
      expect(text('Cancel order'), findsNothing);
      await push(tester, {'status': 'cancelled', 'cancelReason': 'supplier_no_response', 'payment': {'status': 'refunded'}});
      expect(find.textContaining('Reason: The supplier did not respond in time.'), findsOneWidget);
      expect(find.textContaining('GH₵ 117.00 has been returned to your wallet.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('JR-14 an order that cannot be loaded says so instead of spinning', (tester) async {
      await open(tester);
      c.addError(Exception('permission-denied'));
      await tester.pump();
      await tester.pump();
      expect(find.text("Can't load your gas order"), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('JR-16 reopening an order from the order screen resumes its live state', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final orders = StreamController<GasSupplierOrderView?>.broadcast();
    addTearDown(orders.close);
    final repo = GasSupplierRepository(
      call: (name, data) async => name == 'gasSupplierOrderingStatus' ? {'enabled': true} : <String, dynamic>{},
      watch: (_) => orders.stream,
      activeOrders: () async => const [GasSupplierOrderView(id: 'o5', status: 'atStation', total: 117)],
    );
    await tester.pumpWidget(MaterialApp(home: GasSupplierOrderScreen(repository: repo, pickDelivery: (_) async => null)));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gs-active-o5')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    orders.add(GasSupplierOrderView.fromMap('o5', {'status': 'atStation', 'driverId': 'd1', 'deliveryMode': 'ctsgo_driver',
      'payment': {'status': 'held'}, 'priceSnapshot': {'total': 117}, 'deliveryAddress': '12 Palm St'}));
    await tester.pump();
    await tester.pump();
    expect(find.text("Your driver is at the supplier's station", skipOffstage: false), findsOneWidget);
    expect(find.text('Driver: Accepted your order', skipOffstage: false), findsOneWidget);
    expect(find.text('Order: o5', skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('paying', () {
    GasSupplierRepository repoFor(StreamController<GasSupplierOrderView?> orders, List<String> calls, {bool refuse = false}) =>
        GasSupplierRepository(
          call: (name, data) async {
            calls.add(name);
            switch (name) {
              case 'gasSupplierOrderingStatus':
                return {'enabled': true};
              case 'listGasSupplierOptions':
                return data.containsKey('orderType')
                    ? {'options': [{'supplierId': 's1', 'supplierName': 'Tema Gas', 'stationId': 'st1', 'stationName': 'Tema Station',
                        'productId': 'p1', 'brand': 'goGas', 'price': 150.0, 'distanceKm': 1.2}]}
                    : <String, dynamic>{};
              case 'quoteGasSupplierOrder':
                return {'quoteId': 'q1', 'expiresAt': DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
                  'pricing': {'unitPrice': 150.0, 'quantity': 1, 'productAmount': 150.0, 'handlingFee': 0, 'deliveryFee': 14.5, 'total': 164.5},
                  'selection': {'supplierName': 'Tema Gas', 'stationName': 'Tema Station', 'orderType': 'exchangeEmpty', 'cylinderSize': 'kg12_5'}};
              case 'createGasSupplierOrder':
                return {'orderId': 'q1', 'total': 164.5, 'status': 'awaiting_payment'};
              case 'payGasSupplierOrder':
                if (refuse) throw const GasSupplierFailure('failed-precondition', 'price_changed', 'The price has changed. Please get a new price.');
                return {'orderId': 'q1', 'status': 'pendingApproval'};
              case 'refundEscrowOnError':
                return {'refunded': true};
            }
            return <String, dynamic>{};
          },
          hold: (amount) async => 'e1',
          watch: (_) => orders.stream,
          activeOrders: () async => const [],
        );

    Future<void> pay(WidgetTester tester, GasSupplierRepository repo) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: GasSupplierOrderScreen(
          initialDelivery: (address: 'Home', latitude: 5.68, longitude: -0.01), repository: repo)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gs-find')));
      await tester.pump();
      await tester.tap(find.text('Tema Gas'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gs-pay')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('JR-20 verified payment enters the shared tracking, processing, with the quoted supplier', (tester) async {
      final orders = StreamController<GasSupplierOrderView?>.broadcast();
      addTearDown(orders.close);
      final calls = <String>[];
      await pay(tester, repoFor(orders, calls));
      // Navigation happened only after the server verified the payment.
      expect(calls, containsAllInOrder(['createGasSupplierOrder', 'payGasSupplierOrder']));
      expect(find.byType(GasSupplierTrackingScreen), findsOneWidget);
      orders.add(GasSupplierOrderView.fromMap('q1', {'status': 'pendingApproval', 'payment': {'status': 'held'},
        'priceSnapshot': {'total': 164.5, 'productAmount': 150, 'deliveryFee': 14.5}, 'deliveryAddress': 'Home'}));
      await tester.pump();
      await tester.pump();
      expect(find.text('Payment confirmed', skipOffstage: false), findsOneWidget);
      expect(find.text('Supplier: Tema Gas · Tema Station', skipOffstage: false), findsOneWidget);
      expect(find.textContaining('Accepted your order', skipOffstage: false), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('JR-21 a refused payment stays on the order screen and never enters tracking', (tester) async {
      final orders = StreamController<GasSupplierOrderView?>.broadcast();
      addTearDown(orders.close);
      final calls = <String>[];
      await pay(tester, repoFor(orders, calls, refuse: true));
      await tester.pump();
      expect(find.byType(GasSupplierTrackingScreen), findsNothing);
      expect(find.byKey(const Key('gs-error')), findsOneWidget);
      expect(calls, contains('refundEscrowOnError'), reason: 'the hold is returned at once');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('supplier name and currency', () {
    const snapshot = {'supplierSnapshot': {'supplierName': 'Tema Gas', 'stationName': 'Tema Station'}};

    test('JR-40 the order carries the server snapshot of who it is with', () {
      final o = order({'status': 'confirmed', ...snapshot});
      expect(o.supplierName, 'Tema Gas');
      expect(o.stationName, 'Tema Station');
      expect(o.supplierLabel, 'Tema Gas · Tema Station');
      expect(order({'status': 'confirmed'}).supplierLabel, isNull, reason: 'an order created before the snapshot');
    });

    Future<void> openWith(WidgetTester tester, GasSupplierOrderView o, {String? supplier}) async {
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = StreamController<GasSupplierOrderView?>.broadcast();
      addTearDown(c.close);
      await tester.pumpWidget(MaterialApp(home: GasSupplierTrackingScreen(orderId: 'o1', stream: c.stream, supplier: supplier)));
      c.add(o);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('JR-41 a reopened order shows its supplier from the snapshot, with no quote to hand', (tester) async {
      await openWith(tester, order({'status': 'driverAssigned', 'driverId': 'd1', ...paid, ...snapshot}));
      expect(find.text('Supplier: Tema Gas · Tema Station', skipOffstage: false), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("JR-42 the order's snapshot wins over the quote; older orders fall back to the quote", (tester) async {
      await openWith(tester, order({'status': 'pendingApproval', ...paid, ...snapshot}), supplier: 'Old Name · Old Station');
      expect(find.text('Supplier: Tema Gas · Tema Station', skipOffstage: false), findsOneWidget);
      expect(find.textContaining('Old Name', skipOffstage: false), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await openWith(tester, order({'status': 'pendingApproval', ...paid}), supplier: 'Tema Gas · Tema Station');
      expect(find.text('Supplier: Tema Gas · Tema Station', skipOffstage: false), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await openWith(tester, order({'status': 'pendingApproval', ...paid}));
      expect(find.textContaining('Supplier:', skipOffstage: false), findsNothing, reason: 'nothing to show, nothing invented');
      await tester.pumpWidget(const SizedBox());
    });

    test('JR-43 money reads GH₵ 12.00 in both Gas flows', () {
      expect(formatCedis(12), 'GH₵ 12.00');
      expect(formatCedis(164.5), 'GH₵ 164.50');
      expect(formatCedis(150, decimals: 0), 'GH₵ 150');
      expect(supplierPaymentNote(order({'status': 'confirmed', ...paid})), 'Total GH₵ 117.00 · paid from your wallet');
    });
  });
}
