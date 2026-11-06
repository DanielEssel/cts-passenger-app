// Live driver position for Gas supplier orders: the order screen combines
// the order (status and progress) with gas_supplier_tracking/{orderId} (the
// position only). A position is shown only from the driver now on the
// order, in a driver stage; a missing or failed tracking read leaves the
// order screen working. Supplier notifications and the active-order banner
// open the supplier tracking screen; the legacy Gas route is unchanged.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/core/routes/app_routes.dart';
import 'package:cts_transport_app/core/routes/deep_link.dart';
import 'package:cts_transport_app/features/bookings/service_request_manager.dart';
import 'package:cts_transport_app/features/gas/presentation/screens/gas_order_tracking_screen.dart';
import 'package:cts_transport_app/features/gas/presentation/widgets/gas_tracking_body.dart';
import 'package:cts_transport_app/features/gas_supplier/domain/gas_supplier_models.dart';
import 'package:cts_transport_app/features/gas_supplier/domain/gas_supplier_tracking.dart';
import 'package:cts_transport_app/features/gas_supplier/presentation/gas_supplier_tracking_screen.dart';
import 'package:cts_transport_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

GasSupplierOrderView order(Map<String, dynamic> fields) => GasSupplierOrderView.fromMap('o1', {
      'priceSnapshot': {'total': 117, 'deliveryFee': 12},
      'deliveryLocation': const GeoPoint(5.60, -0.20),
      'deliveryAddress': '12 Palm St',
      ...fields,
    });

GasSupplierTrackingFix fix({String? driverId = 'd1', String status = 'driverAssigned', GeoPoint? at = const GeoPoint(5.61, -0.19)}) =>
    GasSupplierTrackingFix.fromMap({
      'driverId': driverId, 'status': status, 'driverCurrentLocation': at, 'driverHeading': 45,
      'driverLocationUpdatedAt': Timestamp.fromDate(DateTime(2026, 11, 1, 9, 30)),
    });

void main() {
  group('which position is shown', () {
    test('LT-01 the tracking document is read for its driver, status, position, heading and time only', () {
      final f = GasSupplierTrackingFix.fromMap({
        'orderId': 'o1', 'driverId': 'd1', 'status': 'atStation', 'driverCurrentLocation': const GeoPoint(5.61, -0.19),
        'driverHeading': 90, 'lastLocationUpdate': Timestamp.fromDate(DateTime(2026, 11, 1, 9)),
      });
      expect([f.driverId, f.status, f.latitude, f.longitude, f.heading, f.at], ['d1', 'atStation', 5.61, -0.19, 90.0, DateTime(2026, 11, 1, 9)]);
      expect(GasSupplierTrackingFix.fromMap({'driverId': ''}).driverId, isNull);
      expect(GasSupplierTrackingFix.fromMap({'driverHeading': -1}).heading, 0);
    });

    test('LT-02 only the driver now on the order, in a driver stage, with a real position', () {
      for (final s in ['driverAssigned', 'atStation', 'outForDelivery']) {
        expect(liveDriverFix(order({'status': s, 'driverId': 'd1'}), fix(status: s)), isNotNull, reason: s);
      }
      expect(liveDriverFix(order({'status': 'driverAssigned', 'driverId': 'd1'}), null), isNull, reason: 'no tracking document');
      expect(liveDriverFix(order({'status': 'driverAssigned', 'driverId': 'd1'}), fix(at: null)), isNull, reason: 'no position yet');
      expect(liveDriverFix(order({'status': 'driverAssigned', 'driverId': 'd2'}), fix()), isNull, reason: "another driver's position");
      expect(liveDriverFix(order({'status': 'confirmed'}), fix()), isNull, reason: 'released: no driver on the order');
      for (final s in ['pendingApproval', 'confirmed', 'delivered', 'cancelled']) {
        expect(liveDriverFix(order({'status': s, 'driverId': 'd1'}), fix(status: s)), isNull, reason: s);
      }
    });
  });

  group('the supplier tracking screen', () {
    Future<GasTrackingData> pump(WidgetTester tester, GasSupplierOrderView o, Stream<GasSupplierTrackingFix?> tracking) async {
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: GasSupplierTrackingScreen(orderId: 'o1', stream: Stream.value(o), trackingStream: tracking)));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      return tester.widget<GasTrackingBody>(find.byType(GasTrackingBody)).data;
    }

    testWidgets('LT-10 the order and the tracking streams are combined: the position goes to the map, the status stays the order\'s', (tester) async {
      final orders = StreamController<GasSupplierOrderView?>.broadcast();
      final tracking = StreamController<GasSupplierTrackingFix?>.broadcast();
      final o = order({'status': 'atStation', 'driverId': 'd1'});
      await tester.pumpWidget(MaterialApp(home: GasSupplierTrackingScreen(orderId: 'o1', stream: orders.stream, trackingStream: tracking.stream)));
      orders.add(o);
      await tester.pump();
      tracking.add(fix(status: 'driverAssigned'));
      await tester.pump();
      await tester.pump();
      final d = tester.widget<GasTrackingBody>(find.byType(GasTrackingBody)).data;
      expect([d.driver?.latitude, d.driver?.longitude, d.driverHeading, d.driverLocationAt], [5.61, -0.19, 45.0, DateTime(2026, 11, 1, 9, 30)]);
      expect(d.statusKey, 'atStation', reason: 'the order, not the tracking document, drives the status');
      expect(d.view.headline, gasSupplierTrackingView(o).headline);
      expect(d.showDriverCard, isFalse, reason: 'no driver name or phone is readable for supplier orders');
      await orders.close();
      await tracking.close();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('LT-11 no marker without a valid position: another driver, an ended order, a missing or failed tracking read', (tester) async {
      var d = await pump(tester, order({'status': 'driverAssigned', 'driverId': 'd2'}), Stream.value(fix()));
      expect(d.driver, isNull, reason: "another driver's position");
      await tester.pumpWidget(const SizedBox());

      d = await pump(tester, order({'status': 'delivered', 'driverId': 'd1'}), Stream.value(fix()));
      expect(d.driver, isNull, reason: 'delivered');
      await tester.pumpWidget(const SizedBox());

      d = await pump(tester, order({'status': 'driverAssigned', 'driverId': 'd1'}), Stream.value(null));
      expect(d.driver, isNull, reason: 'no tracking document yet');
      expect(find.text('12 Palm St', skipOffstage: false), findsOneWidget, reason: 'the order still shows');
      await tester.pumpWidget(const SizedBox());

      d = await pump(tester, order({'status': 'driverAssigned', 'driverId': 'd1'}), Stream.error(Exception('permission-denied')));
      expect(d.driver, isNull, reason: 'a failed read');
      expect(find.text('12 Palm St', skipOffstage: false), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('LT-12 a released driver\'s position disappears as soon as the order changes', (tester) async {
      final orders = StreamController<GasSupplierOrderView?>.broadcast();
      final tracking = StreamController<GasSupplierTrackingFix?>.broadcast();
      await tester.pumpWidget(MaterialApp(home: GasSupplierTrackingScreen(orderId: 'o1', stream: orders.stream, trackingStream: tracking.stream)));
      orders.add(order({'status': 'driverAssigned', 'driverId': 'd1'}));
      await tester.pump();
      tracking.add(fix());
      await tester.pump();
      expect(tester.widget<GasTrackingBody>(find.byType(GasTrackingBody)).data.driver, isNotNull);
      orders.add(order({'status': 'confirmed', 'releasedDriverIds': ['d1']}));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<GasTrackingBody>(find.byType(GasTrackingBody)).data.driver, isNull);
      await orders.close();
      await tracking.close();
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('opening a supplier order', () {
    test('LT-20 a supplier notification opens that order\'s supplier tracking screen; the legacy gas route is unchanged', () {
      final link = DeepLink.parse('/gas-supplier-tracking?orderId=o1')!;
      expect([link.path, link.arguments], [AppRoutes.gasSupplierTracking, {'orderId': 'o1'}]);
      final route = RiderApp.generateRoute(RouteSettings(name: link.path, arguments: link.arguments)) as MaterialPageRoute;
      final screen = route.builder(_FakeContext());
      expect(screen, isA<GasSupplierTrackingScreen>());
      expect((screen as GasSupplierTrackingScreen).orderId, 'o1');
      // The in-app inbox stores the id in metadata: same screen.
      final inbox = DeepLink.parse('/gas-supplier-tracking', metadata: {'orderId': 'o2'})!;
      final r2 = RiderApp.generateRoute(RouteSettings(name: inbox.path, arguments: inbox.arguments)) as MaterialPageRoute;
      expect((r2.builder(_FakeContext()) as GasSupplierTrackingScreen).orderId, 'o2');
      // Legacy gas notifications still open the legacy screen.
      final legacy = RiderApp.generateRoute(const RouteSettings(name: AppRoutes.gasTracking, arguments: {'orderId': 'g1'})) as MaterialPageRoute;
      expect(legacy.builder(_FakeContext()), isA<GasOrderTrackingScreen>());
    });

    test('LT-21 a missing or invalid order id opens nothing', () {
      for (final args in [null, <String, dynamic>{}, {'orderId': ''}, {'orderId': '../x'}, {'orderId': 'a b'}, {'orderId': 'x' * 200}]) {
        expect(RiderApp.generateRoute(RouteSettings(name: AppRoutes.gasSupplierTracking, arguments: args)), isNull, reason: '$args');
      }
    });

    test('LT-22 an active supplier order can be reopened from the active-order banner', () {
      final w = ServiceRequestWrapper.gasSupplier(order({'status': 'outForDelivery', 'driverId': 'd1'}));
      expect(w, isA<GasSupplierRequestWrapper>());
      expect([w.id, w.serviceType], ['o1', 'gas_supplier']);
      expect(w.statusDisplayName, gasSupplierTrackingView(order({'status': 'outForDelivery', 'driverId': 'd1'})).headline);
      // Paid, unfinished statuses only: never an unpaid or a delivered order.
      expect(activeSupplierOrderStatuses, ['pendingApproval', 'confirmed', 'driverAssigned', 'atStation', 'outForDelivery']);
    });
  });
}

class _FakeContext extends Fake implements BuildContext {}
