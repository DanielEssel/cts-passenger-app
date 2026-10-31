// The receiver's completion code is held server-side, where the assigned
// driver cannot read it (functions/completion_codes.js). New orders no
// longer carry it; tracking shows the order's own code for older orders,
// else the server-held one.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/features/delivery/models/delivery_request.dart';
import 'package:cts_transport_app/features/tracking/data/completion_code_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DeliveryRequest _delivery({String? otp}) => DeliveryRequest(
      id: 'd1',
      passengerId: 'p1',
      status: DeliveryStatus.pending,
      pickupLocation: const GeoPoint(5.6, -0.18),
      dropoffLocation: const GeoPoint(5.61, -0.19),
      pickupAddress: 'A',
      dropoffAddress: 'B',
      parcelType: 'Package',
      weightTier: 'Small',
      weightRange: '0–5 kg',
      isFragile: false,
      requiresHelpers: false,
      vehicleType: 'Okada',
      estimatedFare: 20,
      createdAt: DateTime(2026, 10, 28),
      paymentMethod: 'cash',
      deliveryOtp: otp,
    );

void main() {
  test('a new delivery is written without a completion code', () {
    expect(_delivery().toFirestore().containsKey('deliveryOtp'), isFalse);
    // An order that already has one (older flows) keeps it.
    expect(_delivery(otp: '4821').toFirestore()['deliveryOtp'], '4821');
  });

  group('pickCompletionCode', () {
    test("the order's own code first", () {
      expect(pickCompletionCode('1111', const AsyncValue.data('4821')), '1111');
    });
    test('else the loaded server-held code', () {
      expect(pickCompletionCode(null, const AsyncValue.data('4821')), '4821');
      expect(pickCompletionCode('', const AsyncValue.data('4821')), '4821');
    });
    test('nothing while loading, on error, or when none exists', () {
      expect(pickCompletionCode(null, const AsyncValue.loading()), isNull);
      expect(pickCompletionCode(null, AsyncValue.error('denied', StackTrace.empty)), isNull);
      expect(pickCompletionCode(null, const AsyncValue.data(null)), isNull);
    });
  });

  testWidgets('tracking reads the server-held code for the order', (t) async {
    await t.pumpWidget(ProviderScope(
      overrides: [
        completionCodeProvider(('deliveries', 'd1'))
            .overrideWith((ref) => Stream.value('4821')),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Text(
              completionCodeFor(ref, 'deliveries', 'd1', null) ?? 'none'),
        ),
      ),
    ));
    expect(find.text('none'), findsOneWidget);
    await t.pump();
    expect(find.text('4821'), findsOneWidget);
  });

  group('watchCompletionCode', () {
    const delays = [Duration(milliseconds: 1), Duration(milliseconds: 1)];
    FirebaseException denied() => FirebaseException(
        plugin: 'cloud_firestore', code: 'permission-denied');

    test('listens again while the record is not created yet', () async {
      var listens = 0;
      final codes = await watchCompletionCode(() {
        listens++;
        return listens < 3
            ? Stream<String?>.error(denied())
            : Stream.value('4821');
      }, retryDelays: delays).toList();
      expect(codes, ['4821']);
      expect(listens, 3);
    });

    test('gives up after the last retry, so denials are not endless',
        () async {
      var listens = 0;
      await expectLater(
        watchCompletionCode(() {
          listens++;
          return Stream<String?>.error(denied());
        }, retryDelays: delays),
        emitsError(isA<FirebaseException>()),
      );
      expect(listens, delays.length + 1);
    });

    test('other errors are not retried', () async {
      var listens = 0;
      await expectLater(
        watchCompletionCode(() {
          listens++;
          return Stream<String?>.error(FirebaseException(
              plugin: 'cloud_firestore', code: 'unavailable'));
        }, retryDelays: delays),
        emitsError(isA<FirebaseException>()),
      );
      expect(listens, 1);
    });
  });
}
