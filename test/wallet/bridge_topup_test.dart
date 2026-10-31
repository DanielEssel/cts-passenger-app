// Bridge Mobile Money top-up: a payment whose result is not confirmed is
// never shown as a failure to retry (a retry could charge the customer
// twice); the sheet says it is awaiting confirmation and offers only Close.
// The controller is faked: no Firebase, no network.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cts_transport_app/features/wallet/domain/entities/bridge_payment_status.dart';
import 'package:cts_transport_app/features/wallet/presentation/providers/wallet_controller.dart';
import 'package:cts_transport_app/features/wallet/presentation/widgets/bridge_momo_sheet.dart';

class _FakeWalletController extends WalletController {
  _FakeWalletController(super.ref, this.statuses);

  /// Returned by successive status checks; the last one repeats.
  final List<BridgePaymentStatus> statuses;
  int initiated = 0;
  int checks = 0;
  bool refreshed = false;

  @override
  Future<String> initiateBridgeTopUp({
    required double amount,
    required String phone,
    required String network,
  }) async {
    initiated++;
    return 'CTS-TOPUP-TEST';
  }

  @override
  Future<BridgePaymentStatus> checkBridgeTopUpStatus(String transactionId) async {
    final s = statuses[checks < statuses.length ? checks : statuses.length - 1];
    checks++;
    return s;
  }

  @override
  Future<void> onTopUpSuccess() async => refreshed = true;
}

const _pending = BridgePaymentStatus(localStatus: BridgeLocalStatus.pending);

Future<_FakeWalletController> _openAndPay(
    WidgetTester tester, List<BridgePaymentStatus> statuses) async {
  late _FakeWalletController fake;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      walletControllerProvider.overrideWith((ref) {
        fake = _FakeWalletController(ref, statuses);
        return fake;
      }),
    ],
    child: const MaterialApp(home: Scaffold(body: BridgeMomoSheet(amount: 50))),
  ));
  await tester.enterText(find.byType(TextField), '0241234567');
  await tester.pump();
  await tester.tap(find.text('Send Payment Prompt  →'));
  await tester.pump();
  return fake;
}

void main() {
  group('BridgePaymentStatus', () {
    test('reads awaitingVerification from the status check', () {
      final s = BridgePaymentStatus.fromMap(
          {'localStatus': 'pending', 'awaitingVerification': true});
      expect(s.isPending, isTrue);
      expect(s.awaitingVerification, isTrue);
      expect(s.isSuccess, isFalse);
    });

    test('older responses without the field are not awaiting verification', () {
      final s = BridgePaymentStatus.fromMap({'localStatus': 'pending'});
      expect(s.awaitingVerification, isFalse);
    });
  });

  group('BridgeMomoSheet', () {
    testWidgets('an unverified result shows awaiting confirmation, never Try Again',
        (tester) async {
      final fake = await _openAndPay(tester, const [
        _pending,
        BridgePaymentStatus(
            localStatus: BridgeLocalStatus.pending, awaitingVerification: true),
      ]);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();

      expect(find.text('Awaiting confirmation'), findsOneWidget);
      expect(find.textContaining('Please do not pay again'), findsOneWidget);
      expect(find.textContaining('CTS-TOPUP-TEST'), findsOneWidget);
      expect(find.text('Try Again'), findsNothing);
      expect(find.text('Payment Failed'), findsNothing);
      expect(fake.initiated, 1);
      expect(fake.refreshed, isFalse, reason: 'nothing was credited');

      // Polling has stopped.
      final checks = fake.checks;
      await tester.pump(const Duration(seconds: 20));
      expect(fake.checks, checks);
    });

    testWidgets('a timeout after the prompt was sent is awaiting confirmation, not a failure',
        (tester) async {
      final fake = await _openAndPay(tester, const [_pending]);
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      await tester.pump();

      expect(find.text('Awaiting confirmation'), findsOneWidget);
      expect(find.text('Try Again'), findsNothing);
      expect(find.textContaining('timed out'), findsNothing);
      expect(fake.initiated, 1, reason: 'no second payment prompt');
    });

    testWidgets('a confirmed success is still shown as success', (tester) async {
      final fake = await _openAndPay(tester, const [
        BridgePaymentStatus(localStatus: BridgeLocalStatus.success),
      ]);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(fake.refreshed, isTrue);
      expect(find.text('Awaiting confirmation'), findsNothing);
    });

    testWidgets('a declined payment is still shown as failed', (tester) async {
      await _openAndPay(tester, const [
        BridgePaymentStatus(localStatus: BridgeLocalStatus.failed),
      ]);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Payment Failed'), findsOneWidget);
    });
  });
}
