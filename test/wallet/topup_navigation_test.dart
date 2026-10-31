// Wallet top-up navigation: starting a top-up never closes the Wallet (or
// the booking screen under it), the Wallet confirms only a confirmed
// success, and the retired Paystack "Processing payment…" overlay is gone.
// The payment controller is faked: no Firebase, no network, no money.

import 'package:cts_transport_app/core/theme/cts_theme.dart';
import 'package:cts_transport_app/features/wallet/domain/entities/bridge_payment_status.dart';
import 'package:cts_transport_app/features/wallet/domain/entities/transaction.dart';
import 'package:cts_transport_app/features/wallet/domain/entities/wallet.dart';
import 'package:cts_transport_app/features/wallet/presentation/providers/wallet_controller.dart';
import 'package:cts_transport_app/features/wallet/presentation/providers/wallet_providers.dart';
import 'package:cts_transport_app/features/wallet/presentation/screens/wallet_screen.dart';
import 'package:cts_transport_app/features/wallet/presentation/screens/wallet_standalone_screen.dart';
import 'package:cts_transport_app/features/wallet/presentation/widgets/bridge_momo_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _pending = BridgePaymentStatus(localStatus: BridgeLocalStatus.pending);
const _success = BridgePaymentStatus(localStatus: BridgeLocalStatus.success);
const _failed = BridgePaymentStatus(localStatus: BridgeLocalStatus.failed);
const _unverified = BridgePaymentStatus(
    localStatus: BridgeLocalStatus.pending, awaitingVerification: true);

class _FakeController extends WalletController {
  _FakeController(super.ref, this.status);
  final BridgePaymentStatus status;
  int initiated = 0;
  int checks = 0;

  @override
  Future<String> initiateBridgeTopUp(
      {required double amount,
      required String phone,
      required String network}) async {
    initiated++;
    return 'CTS-TOPUP-TEST';
  }

  @override
  Future<BridgePaymentStatus> checkBridgeTopUpStatus(String id) async {
    checks++;
    return status;
  }

  @override
  Future<void> onTopUpSuccess() async {}
}

/// Records the Wallet's own refresh instead of loading from Firestore.
class _FakeWalletNotifier extends WalletStateNotifier {
  static int refreshes = 0;
  @override
  AsyncValue<Wallet?> build() => const AsyncValue.data(null);
  @override
  Future<void> refresh() async => refreshes++;
}

final _now = DateTime(2026, 10, 19);
final _wallet = Wallet(
    userId: 'u',
    balance: 10,
    cashBalance: 0,
    mobileMoneyBalance: 0,
    cardBalance: 0,
    currency: 'GHS',
    createdAt: _now,
    lastUpdated: _now,
    status: 'active');

late _FakeController _fake;

List _overrides(BridgePaymentStatus status) => [
      walletStreamProvider.overrideWith((ref) => Stream.value(_wallet)),
      recentTransactionsStreamProvider
          .overrideWith((ref) => Stream.value(<Transaction>[])),
      walletProvider.overrideWith(_FakeWalletNotifier.new),
      walletControllerProvider
          .overrideWith((ref) => _fake = _FakeController(ref, status)),
    ];

const _booking = 'BOOKING SCREEN';

/// The app as it is when a booking screen's low-balance "Top Up" pushes
/// /wallet on the root navigator (gas, ride and delivery all do this).
Future<void> _pumpFromBooking(
    WidgetTester t, BridgePaymentStatus status) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  _FakeWalletNotifier.refreshes = 0;
  await t.pumpWidget(ProviderScope(
    overrides: [..._overrides(status).cast()],
    child: MaterialApp(
      theme: CtsTheme.light(),
      routes: {'/wallet': (_) => const WalletStandaloneScreen()},
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              // Same call the booking screens make.
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .pushNamed('/wallet'),
              child: const Text(_booking),
            ),
          ),
        ),
      ),
    ),
  ));
  await t.tap(find.text(_booking));
  await t.pumpAndSettle();
}

/// The Wallet tab: root of its own tab Navigator, as in the app shell.
Future<void> _pumpWalletTab(WidgetTester t, BridgePaymentStatus status) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  _FakeWalletNotifier.refreshes = 0;
  await t.pumpWidget(ProviderScope(
    overrides: [..._overrides(status).cast()],
    child: MaterialApp(
      theme: CtsTheme.light(),
      home: Scaffold(
        body: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute(
              builder: (_) =>
                  WalletScreen(scrollController: ScrollController())),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

/// Top up → GHS 50 → Pay. Leaves the MoMo sheet open at its input stage.
Future<void> _startTopUp(WidgetTester t) async {
  await t.tap(find.text('Top up'));
  await t.pumpAndSettle();
  await t.tap(find.text('GHS 50'));
  await t.pump();
  await t.ensureVisible(find.text('Pay GHS 50.00 via MoMo'));
  await t.tap(find.text('Pay GHS 50.00 via MoMo'));
  await t.pumpAndSettle();
}

/// Sends the MoMo prompt and lets the sheet check the status once.
Future<void> _sendPromptAndPoll(WidgetTester t) async {
  await t.enterText(
      find.descendant(
          of: find.byType(BridgeMomoSheet), matching: find.byType(TextField)),
      '0241234567');
  await t.pump();
  await t.tap(find.text('Send Payment Prompt  →'));
  await t.pump();
  await t.pump(const Duration(seconds: 5));
  await t.pump();
}

/// Lets a dialog open or close without running the payment clock on (the
/// waiting stage animates, so pumpAndSettle would run past the timeout).
Future<void> _settleDialog(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

const _successMessage = 'GHS 50.00 added to your wallet';

void main() {
  group('from a booking screen (standalone /wallet)', () {
    testWidgets('Pay keeps the Wallet open underneath the MoMo sheet',
        (t) async {
      await _pumpFromBooking(t, _pending);
      await _startTopUp(t);
      expect(find.byType(BridgeMomoSheet), findsOneWidget);
      expect(find.byType(WalletStandaloneScreen), findsOneWidget);
      // The booking screen is still there, under the Wallet.
      expect(find.text(_booking, skipOffstage: false), findsOneWidget);
      expect(find.text('Processing payment...'), findsNothing);
    });

    testWidgets('a confirmed success refreshes the Wallet and says so',
        (t) async {
      await _pumpFromBooking(t, _success);
      await _startTopUp(t);
      await _sendPromptAndPoll(t);
      expect(find.text('Wallet Topped Up! 🎉'), findsOneWidget);
      await t.tap(find.text('Done'));
      await t.pumpAndSettle();

      expect(find.byType(BridgeMomoSheet), findsNothing);
      expect(find.byType(WalletStandaloneScreen), findsOneWidget);
      expect(_FakeWalletNotifier.refreshes, 1);
      expect(find.text(_successMessage), findsOneWidget);

      // Back from the Wallet returns to the booking screen.
      Navigator.of(t.element(find.byType(WalletStandaloneScreen))).pop();
      await t.pumpAndSettle();
      expect(find.text(_booking), findsOneWidget);
    });

    testWidgets('a declined payment shows no success and no refresh',
        (t) async {
      await _pumpFromBooking(t, _failed);
      await _startTopUp(t);
      await _sendPromptAndPoll(t);
      expect(find.text('Payment Failed'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.byType(WalletStandaloneScreen), findsOneWidget);
      expect(find.text(_successMessage), findsNothing);
      expect(_FakeWalletNotifier.refreshes, 0);
    });

    testWidgets('an unconfirmed payment is not treated as a success',
        (t) async {
      await _pumpFromBooking(t, _unverified);
      await _startTopUp(t);
      await _sendPromptAndPoll(t);
      expect(find.text('Awaiting confirmation'), findsOneWidget);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      expect(find.byType(WalletStandaloneScreen), findsOneWidget);
      expect(find.text(_successMessage), findsNothing);
      expect(_FakeWalletNotifier.refreshes, 0);
    });

    testWidgets('a timed-out payment is not treated as a success', (t) async {
      await _pumpFromBooking(t, _pending);
      await _startTopUp(t);
      await _sendPromptAndPoll(t);
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(seconds: 5));
      }
      await t.pump();
      expect(find.text('Awaiting confirmation'), findsOneWidget);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      expect(find.text(_successMessage), findsNothing);
      expect(_FakeWalletNotifier.refreshes, 0);
    });

    testWidgets('closing the amount sheet leaves both screens in place',
        (t) async {
      await _pumpFromBooking(t, _pending);
      await t.tap(find.text('Top up'));
      await t.pumpAndSettle();
      await t.tapAt(const Offset(195, 40)); // tap the barrier above it
      await t.pumpAndSettle();
      expect(find.text('Top up wallet'), findsNothing);
      expect(find.byType(WalletStandaloneScreen), findsOneWidget);
      expect(find.text(_booking, skipOffstage: false), findsOneWidget);
    });
  });

  group('from the Wallet tab', () {
    testWidgets('Pay keeps the Wallet tab under the MoMo sheet', (t) async {
      await _pumpWalletTab(t, _pending);
      await _startTopUp(t);
      expect(find.byType(BridgeMomoSheet), findsOneWidget);
      expect(find.byType(WalletScreen), findsOneWidget);
    });

    testWidgets('a confirmed success refreshes the Wallet and says so',
        (t) async {
      await _pumpWalletTab(t, _success);
      await _startTopUp(t);
      await _sendPromptAndPoll(t);
      await t.tap(find.text('Done'));
      await t.pumpAndSettle();
      expect(find.byType(WalletScreen), findsOneWidget);
      expect(_FakeWalletNotifier.refreshes, 1);
      expect(find.text(_successMessage), findsOneWidget);
    });
  });

  testWidgets('the retired "Processing payment…" overlay never appears',
      (t) async {
    await _pumpWalletTab(t, _success);
    final overlay = find.textContaining('Processing payment');
    final dontClose = find.textContaining('do not close the app');
    expect(overlay, findsNothing);
    await _startTopUp(t);
    expect(overlay, findsNothing);
    await _sendPromptAndPoll(t);
    expect(overlay, findsNothing);
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(overlay, findsNothing);
    expect(dontClose, findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  group('"Cancel and try again" while waiting', () {
    Future<void> waiting(WidgetTester t) async {
      await _pumpWalletTab(t, _pending);
      await _startTopUp(t);
      await _sendPromptAndPoll(t);
      expect(find.text('Approve on your phone'), findsOneWidget);
      await t.tap(find.text('Cancel and try again'));
      await _settleDialog(t);
    }

    testWidgets('warns about a double charge before anything changes',
        (t) async {
      await waiting(t);
      expect(find.text('Send a new request?'), findsOneWidget);
      expect(find.textContaining('may be charged twice'), findsOneWidget);
      expect(
          find.textContaining('still be added to your wallet'), findsOneWidget);
    });

    testWidgets('Keep waiting keeps checking the first request', (t) async {
      await waiting(t);
      final before = _fake.checks;
      await t.tap(find.text('Keep waiting'));
      await _settleDialog(t);
      expect(find.text('Approve on your phone'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
      await t.pump();
      expect(_fake.checks, greaterThan(before));
      expect(_fake.initiated, 1);
    });

    testWidgets('Send new request returns to the form without retrying',
        (t) async {
      await waiting(t);
      await t.tap(find.text('Send new request'));
      await _settleDialog(t);
      expect(find.text('Send Payment Prompt  →'), findsOneWidget);
      final checks = _fake.checks;
      await t.pump(const Duration(seconds: 15));
      expect(_fake.checks, checks); // the old request is no longer polled
      expect(_fake.initiated, 1); // nothing was sent again by itself
    });
  });
}
