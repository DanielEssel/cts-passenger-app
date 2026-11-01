// The original gas_orders tracking screen, now drawn by the shared
// GasTrackingBody (also used for Gas supplier orders), keeps its own
// behaviour: gasTrackingView decides what is said, the driver is shown with
// their details and a call action once one has accepted, the refill station
// appears on the Pickup & Return refill leg, and cancel only while waiting.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/gas/presentation/screens/gas_order_tracking_screen.dart';
import 'package:cts_transport_app/features/gas/providers/gas_order_providers.dart';
import 'package:cts_transport_app/features/tracking/data/completion_code_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

GasRefillRequest gasOrder(String status, String type, {bool driver = true, String? otp}) => GasRefillRequest(
      id: 'g1', passengerId: 'p1', driverId: driver ? 'd1' : null, driverName: driver ? 'Kofi' : null,
      driverPhone: driver ? '0241112222' : null, driverVehicle: driver ? 'Motorcycle · GR-1' : null,
      driverLocation: driver ? const GeoPoint(5.61, -0.19) : null, driverRating: driver ? 4.7 : null,
      refillType: GasRefillType.fromFirestore(type), cylinderSize: CylinderSize.kg12_5, quantity: 1,
      status: GasOrderStatus.fromFirestore(status), rawStatus: status,
      pickupLocation: const GeoPoint(5.6, -0.2), deliveryLocation: const GeoPoint(5.6, -0.2),
      pickupAddress: 'Home', deliveryAddress: '12 Palm St', preferredStationAddress: 'Shell Spintex',
      cylinderIsAvailable: true, cylinderInGoodCondition: true, safetyChecklistCompleted: true,
      gasAmount: 12.5, gasPrice: 150, serviceFee: 0, deliveryFee: 20, totalPrice: 170,
      createdAt: DateTime(2026, 11, 1), paymentMethod: 'wallet', requiresReceipt: false,
      deliveryOtp: otp, metadata: const {});

Future<void> pumpOrder(WidgetTester tester, GasRefillRequest order) async {
  await tester.binding.setSurfaceSize(const Size(400, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(overrides: [
    gasOrderStreamProvider('g1').overrideWith((ref) => Stream.value(order)),
    completionCodeProvider(('gas_orders', 'g1')).overrideWith((ref) => Stream.value(null)),
  ], child: const MaterialApp(home: GasOrderTrackingScreen(orderId: 'g1'))));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull);
}

Finder text(String t) => find.text(t, skipOffstage: false);

void main() {
  testWidgets('GT-01 waiting for a driver: searching, cancel offered, no driver', (tester) async {
    await pumpOrder(tester, gasOrder('pendingApproval', 'exchangeEmpty', driver: false));
    expect(text('Finding a driver for your gas'), findsOneWidget);
    expect(text('Cancel order'), findsOneWidget);
    expect(text('Call driver'), findsNothing);
    expect(text('Your driver'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('GT-02 a driver accepted: their details, call and share code', (tester) async {
    await pumpOrder(tester, gasOrder('driverAssigned', 'exchangeEmpty', otp: '4821'));
    expect(text('A driver has accepted your order'), findsOneWidget);
    expect(text('Kofi'), findsOneWidget);
    expect(text('Call driver'), findsOneWidget);
    expect(text('Share code'), findsOneWidget);
    expect(find.byKey(const Key('gas-tracking-code'), skipOffstage: false), findsOneWidget);
    expect(text('Cancel order'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('GT-03 the Pickup & Return refill leg shows the refill station', (tester) async {
    await pumpOrder(tester, gasOrder('refilling', 'pickupAndReturn', otp: '4821'));
    expect(text('Your cylinder is being refilled'), findsOneWidget);
    expect(text('Refill station: Shell Spintex'), findsOneWidget);
    expect(text('Refilling'), findsOneWidget);
    expect(text('Returning'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('GT-04 the order summary keeps its lines', (tester) async {
    await pumpOrder(tester, gasOrder('driverEnRoute', 'newCylinder', otp: '4821'));
    expect(text('12.5 kg × 1'), findsOneWidget);
    expect(text('Gas cost'), findsOneWidget);
    expect(text('GH₵ 150.00'), findsOneWidget);
    expect(text('Delivery fee'), findsOneWidget);
    expect(text('GH₵ 20.00'), findsOneWidget);
    expect(text('GH₵ 170.00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('GT-05 a cancelled order ends on its own screen', (tester) async {
    await pumpOrder(tester, gasOrder('cancelled', 'exchangeEmpty', driver: false));
    expect(text('This order was cancelled'), findsOneWidget);
    expect(text('Back to home'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
