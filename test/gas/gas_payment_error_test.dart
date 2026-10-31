// Gas payment errors are shown in plain words. Internal exception text stays
// in the debug log and never reaches the passenger.

import 'dart:async';
import 'dart:io' show SocketException;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:cts_transport_app/core/theme/cts_theme.dart';
import 'package:cts_transport_app/features/gas/presentation/widgets/gas_payment_sheet.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _raw = 'projects/cts/escrow/abc123 INTERNAL stack frame';

void main() {
  group('gasPaymentErrorMessage', () {
    test('connection problems ask the passenger to check their connection',
        () {
      for (final e in <Object>[
        FirebaseException(
            plugin: 'cloud_firestore', code: 'unavailable', message: _raw),
        FirebaseFunctionsException(code: 'deadline-exceeded', message: _raw),
        const SocketException(_raw),
        TimeoutException(_raw),
      ]) {
        final m = gasPaymentErrorMessage(e);
        expect(m, contains('Check your connection'), reason: '$e');
        expect(m, isNot(contains('INTERNAL')), reason: '$e');
      }
    });

    test('expired sessions ask the passenger to sign in again', () {
      final m = gasPaymentErrorMessage(
          FirebaseAuthException(code: 'user-token-expired', message: _raw));
      expect(m, contains('sign in again'));
      expect(m, isNot(contains(_raw)));
    });

    test('anything else gets a safe message that makes no money claims', () {
      final m = gasPaymentErrorMessage(Exception(_raw));
      expect(m, contains('Check your wallet balance'));
      expect(m, isNot(contains(_raw)));
      expect(m.toLowerCase(), isNot(contains('not been charged')));
    });
  });

  testWidgets('the snack bar shows the plain message, never the raw text',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: CtsTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () => showGasPaymentError(
                c,
                FirebaseException(
                    plugin: 'cloud_firestore',
                    code: 'unavailable',
                    message: _raw)),
            child: const Text('pay'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('pay'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Check your connection'), findsOneWidget);
    expect(find.textContaining('INTERNAL'), findsNothing);
    expect(find.textContaining('cloud_firestore'), findsNothing);
  });
}
