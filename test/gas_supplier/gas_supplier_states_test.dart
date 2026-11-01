// What the passenger is told about payment, refunds and progress comes only
// from the order's server state (gas_supplier_fulfilment.js): payment.status,
// refundPending, refundReview and deliveryMode. Nothing claims a refund or a
// payment the backend has not recorded.
import 'dart:async';

import 'package:cts_transport_app/features/gas_supplier/domain/gas_supplier_models.dart';
import 'package:cts_transport_app/features/gas_supplier/domain/gas_supplier_tracking.dart';
import 'package:cts_transport_app/features/gas_supplier/presentation/gas_supplier_tracking_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

GasSupplierOrderView order(Map<String, dynamic> fields) =>
    GasSupplierOrderView.fromMap('o1', {'priceSnapshot': {'total': 117, 'deliveryFee': 12}, ...fields});

void main() {
  group('payment and refund wording', () {
    test('ST-01 cancelled before payment: nothing was charged', () {
      expect(supplierPaymentNote(order({'status': 'cancelled'})), 'Nothing was charged for this order.');
    });

    test('ST-02 cancelled and refunded by the server: the amount is back in the wallet', () {
      final o = order({'status': 'cancelled', 'payment': {'status': 'refunded'}, 'refundPending': false});
      expect(o.paymentStatus, 'refunded');
      expect(supplierPaymentNote(o), 'GH₵ 117.00 has been returned to your wallet.');
    });

    test('ST-03 a refund still pending is "being processed", never "returned"', () {
      expect(supplierPaymentNote(order({'status': 'cancelled', 'payment': {'status': 'held'}, 'refundPending': true})),
          'Your refund is being processed.');
      // Paid, cancelled, no refund recorded yet: still not claimed as returned.
      expect(supplierPaymentNote(order({'status': 'cancelled', 'payment': {'status': 'held'}})), 'Your refund is being processed.');
    });

    test('ST-04 a refund under review says so', () {
      final o = order({'status': 'cancelled', 'payment': {'status': 'held'}, 'refundPending': true, 'refundReview': 'escrow_captured'});
      expect(o.refundReview, isTrue);
      expect(supplierPaymentNote(o), 'Your refund is being reviewed by CTSGo support. You do not need to do anything.');
    });

    test('ST-05 delivered says paid only once the server captured the payment', () {
      expect(supplierPaymentNote(order({'status': 'delivered', 'payment': {'status': 'captured'}})), 'Paid GH₵ 117.00 from your wallet');
      expect(supplierPaymentNote(order({'status': 'delivered', 'payment': {'status': 'held'}})), 'Total GH₵ 117.00');
    });

    test('ST-06 in progress: the total, and "paid" only once held', () {
      expect(supplierPaymentNote(order({'status': 'confirmed', 'payment': {'status': 'held'}})), 'Total GH₵ 117.00 · paid from your wallet');
      expect(supplierPaymentNote(order({'status': 'awaiting_payment'})), 'Total GH₵ 117.00 · not paid yet');
    });
  });

  test('ST-10 confirmed reads by who delivers', () {
    expect(supplierOrderStatusLabelFor('confirmed', 'supplier_rider'), 'Supplier confirmed · preparing your order');
    expect(supplierOrderStatusLabelFor('confirmed', 'linked_rider'), "Supplier confirmed · assigning the supplier's rider");
    expect(supplierOrderStatusLabelFor('confirmed', 'ctsgo_driver'), 'Supplier confirmed · finding a driver');
    expect(supplierOrderStatusLabelFor('outForDelivery', 'supplier_rider'), 'On the way to you');
  });

  testWidgets('ST-20 every server status renders on the shared tracking screen with its own state, address and payment line', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = StreamController<GasSupplierOrderView?>.broadcast();
    await tester.pumpWidget(MaterialApp(home: GasSupplierTrackingScreen(orderId: 'o1', stream: c.stream)));
    for (final s in [...supplierOrderStatusLabels.keys]) {
      final paid = s != 'awaiting_payment' && s != 'cancelled';
      final o = order({'status': s, 'deliveryAddress': '12 Palm St', 'driverId': 'd1',
        if (paid) 'payment': {'status': s == 'delivered' ? 'captured' : 'held'}});
      c.add(o);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull, reason: s);
      final view = gasSupplierTrackingView(o);
      expect(find.text(view.headline, skipOffstage: false), findsOneWidget, reason: s);
      if (s == 'cancelled') {
        // The ended screen: the payment line is part of its detail.
        expect(find.textContaining(supplierPaymentNote(o), skipOffstage: false), findsOneWidget, reason: s);
      } else {
        expect(find.text('12 Palm St', skipOffstage: false), findsOneWidget, reason: s);
        expect(find.text('Payment: ${supplierPaymentNote(o)}', skipOffstage: false), findsOneWidget, reason: s);
      }
    }
    await c.close();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ST-21 a cancelled, refunded order shows the refund; one under review does not claim it', (tester) async {
    final c = StreamController<GasSupplierOrderView?>.broadcast();
    await tester.pumpWidget(MaterialApp(home: GasSupplierTrackingScreen(orderId: 'o1', stream: c.stream)));
    c.add(order({'status': 'cancelled', 'cancelReason': 'supplier_no_response', 'payment': {'status': 'refunded'}}));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Reason: The supplier did not respond in time.'), findsOneWidget);
    expect(find.textContaining('GH₵ 117.00 has been returned to your wallet.'), findsOneWidget);
    c.add(order({'status': 'cancelled', 'payment': {'status': 'held'}, 'refundPending': true, 'refundReview': 'escrow_captured'}));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('returned to your wallet'), findsNothing);
    expect(find.textContaining('reviewed by CTSGo support'), findsOneWidget);
    await c.close();
    await tester.pumpWidget(const SizedBox());
  });
}
