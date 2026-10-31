// Receipt actions tell the truth: Save exports a real CTSGo receipt file,
// Share shares CTSGo receipt text, and Report says plainly that it cannot
// send anything yet. Confirmations appear only when the platform confirms.
// The share sheet and clipboard are mocked; nothing leaves the test.

import 'dart:io';

import 'package:cts_transport_app/core/theme/cts_theme.dart';
import 'package:cts_transport_app/features/wallet/presentation/screens/transaction_detail_screen.dart';
import 'package:cts_transport_app/features/wallet/presentation/screens/wallet_screen.dart';
import 'package:cts_transport_app/features/wallet/presentation/widgets/receipt_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TxItem _tx({bool credit = false, String note = ''}) => TxItem(
      icon: Icons.local_taxi_rounded,
      iconBg: CtsTheme.appleSoft,
      iconColor: CtsTheme.primaryDeep,
      label: credit ? 'Wallet top-up' : 'Taxi ride to Kotoka Airport',
      sub: 'Today 14:30',
      amount: credit ? '+GHS 100.00' : '-GHS 1,242.50',
      isCredit: credit,
      type: credit ? 'Top-ups' : 'Rides',
      ref: 'CTS-7F3K9Q2M',
      fullDate: 'Oct 19, 2026 · 2:30 PM',
      status: 'completed',
      note: note,
    );

/// Stands in for the platform share sheet.
class _FakeSharer extends ReceiptSharer {
  _FakeSharer(this.result);

  /// An outcome to return, or an error to throw.
  final Object result;
  final calls = <(String kind, String text, String? fileName)>[];

  Future<ReceiptShareOutcome> _answer() async {
    if (result is ReceiptShareOutcome) return result as ReceiptShareOutcome;
    throw result;
  }

  @override
  Future<ReceiptShareOutcome> shareText(String text,
      {required String subject}) {
    calls.add(('text', text, null));
    return _answer();
  }

  @override
  Future<ReceiptShareOutcome> shareFile(String text,
      {required String fileName, required String subject}) {
    calls.add(('file', text, fileName));
    return _answer();
  }
}

Future<void> _open(WidgetTester t, TxItem tx,
    {ReceiptSharer? sharer, List<String?>? pushed}) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    overrides: [
      if (sharer != null) receiptSharerProvider.overrideWithValue(sharer),
    ],
    child: MaterialApp(
      theme: CtsTheme.light(),
      onGenerateRoute: (s) {
        pushed?.add(s.name);
        return MaterialPageRoute(
            builder: (_) => Scaffold(body: Text('ROUTE ${s.name}')));
      },
      home: TransactionDetailScreen(tx: tx),
    ),
  ));
  await t.pumpAndSettle();
}

Future<void> _tap(WidgetTester t, String label) async {
  await t.scrollUntilVisible(find.text(label), 100);
  await t.tap(find.text(label));
  await t.pumpAndSettle();
}

/// Records clipboard writes.
List<String> _mockClipboard(WidgetTester t) {
  final copied = <String>[];
  t.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(() => t.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

void main() {
  group('receipt text', () {
    test('is CTSGo-branded and drops the legacy RIDEGO header', () {
      final text = buildReceiptText(_tx());
      expect(text, startsWith('CTSGo receipt\n'));
      expect(text.toUpperCase(), isNot(contains('RIDEGO')));
      expect(text, contains('Thank you for using CTSGo.'));
    });

    test('holds only the fields the receipt already shows', () {
      final text = buildReceiptText(_tx(note: 'internal: driver 0244000000'));
      expect(
          text.split('\n'),
          containsAllInOrder([
            'Taxi ride to Kotoka Airport',
            'Paid: GHS 1,242.50',
            'Category: Rides',
            'Date: Oct 19, 2026 · 2:30 PM',
            'Status: Completed',
            'Reference: CTS-7F3K9Q2M',
          ]));
      expect(text, isNot(contains('internal')));
      expect(buildReceiptText(_tx(credit: true)),
          contains('Received: GHS 100.00'));
    });

    test('file name is CTSGo-branded and safe on every platform', () {
      expect(receiptFileName(_tx()), 'CTSGo-receipt-CTS-7F3K9Q2M.txt');
    });
  });

  group('default sharer (share_plus mocked at the platform channel)', () {
    const share = MethodChannel('dev.fluttercommunity.plus/share');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    late Directory tmp;
    late List<MethodCall> calls;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      tmp = Directory.systemTemp.createTempSync('receipt_test');
      calls = [];
      final m =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(paths, (c) async => tmp.path);
      m.setMockMethodCallHandler(share, (c) async {
        calls.add(c);
        return 'com.example.files'; // the app the customer picked
      });
    });

    tearDown(() {
      final m =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(share, null);
      m.setMockMethodCallHandler(paths, null);
      tmp.deleteSync(recursive: true);
    });

    test('Save writes a real CTSGo .txt receipt and offers it', () async {
      final outcome = await const ReceiptSharer().shareFile(
          buildReceiptText(_tx()),
          fileName: receiptFileName(_tx()),
          subject: 'CTSGo receipt');
      expect(outcome, ReceiptShareOutcome.completed);
      expect(calls.single.method, 'shareFiles');
      final args = calls.single.arguments as Map;
      final path = (args['paths'] as List).single as String;
      expect(path, endsWith('CTSGo-receipt-CTS-7F3K9Q2M.txt'));
      expect(args['mimeTypes'], ['text/plain']);
      expect(File(path).readAsStringSync(), buildReceiptText(_tx()));
    });

    test('maps dismissed and unconfirmed platform results', () async {
      final m =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(share, (c) async => '');
      expect(await const ReceiptSharer().shareText('x', subject: 's'),
          ReceiptShareOutcome.dismissed);
      m.setMockMethodCallHandler(
          share, (c) async => 'dev.fluttercommunity.plus/share/unavailable');
      expect(await const ReceiptSharer().shareText('x', subject: 's'),
          ReceiptShareOutcome.unconfirmed);
    });
  });

  group('Save receipt', () {
    testWidgets('exports the receipt file and confirms only on success',
        (t) async {
      final sharer = _FakeSharer(ReceiptShareOutcome.completed);
      await _open(t, _tx(), sharer: sharer);
      expect(find.text('Download receipt'), findsNothing);
      await _tap(t, 'Save receipt');
      expect(sharer.calls.single.$1, 'file');
      expect(sharer.calls.single.$2, buildReceiptText(_tx()));
      expect(sharer.calls.single.$3, 'CTSGo-receipt-CTS-7F3K9Q2M.txt');
      expect(find.text('Receipt file exported'), findsOneWidget);
      expect(find.textContaining('saved to downloads'), findsNothing);
    });

    testWidgets('says nothing when the customer closes the share sheet',
        (t) async {
      await _open(t, _tx(), sharer: _FakeSharer(ReceiptShareOutcome.dismissed));
      await _tap(t, 'Save receipt');
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('is honest when the platform cannot confirm', (t) async {
      await _open(t, _tx(),
          sharer: _FakeSharer(ReceiptShareOutcome.unconfirmed));
      await _tap(t, 'Save receipt');
      expect(find.textContaining("didn't confirm where the receipt was saved"),
          findsOneWidget);
      expect(find.text('Receipt file exported'), findsNothing);
    });

    testWidgets('explains unsupported platforms', (t) async {
      await _open(t, _tx(),
          sharer: _FakeSharer(MissingPluginException('no share')));
      await _tap(t, 'Save receipt');
      expect(find.text("Saving receipts isn't supported on this device."),
          findsOneWidget);
    });

    testWidgets('reports failures without claiming success', (t) async {
      await _open(t, _tx(), sharer: _FakeSharer(StateError('disk full')));
      await _tap(t, 'Save receipt');
      expect(find.text("Couldn't create the receipt file. Please try again."),
          findsOneWidget);
      expect(find.textContaining('disk full'), findsNothing);
    });
  });

  group('Share receipt', () {
    testWidgets('shares CTSGo receipt text through the share sheet', (t) async {
      final copied = _mockClipboard(t);
      final sharer = _FakeSharer(ReceiptShareOutcome.completed);
      await _open(t, _tx(), sharer: sharer);
      await _tap(t, 'Share receipt');
      expect(sharer.calls.single.$1, 'text');
      expect(sharer.calls.single.$2, startsWith('CTSGo receipt'));
      expect(copied, isEmpty); // no longer a silent clipboard copy
      expect(find.text('Receipt shared'), findsOneWidget);
    });

    testWidgets('claims nothing when dismissed or unconfirmed', (t) async {
      for (final outcome in [
        ReceiptShareOutcome.dismissed,
        ReceiptShareOutcome.unconfirmed,
      ]) {
        await _open(t, _tx(), sharer: _FakeSharer(outcome));
        await _tap(t, 'Share receipt');
        expect(find.byType(SnackBar), findsNothing, reason: '$outcome');
      }
    });

    testWidgets('explains when sharing is unsupported', (t) async {
      await _open(t, _tx(),
          sharer: _FakeSharer(MissingPluginException('no share')));
      await _tap(t, 'Share receipt');
      expect(
          find.text("Sharing isn't supported on this device."), findsOneWidget);
    });
  });

  group('Report an issue', () {
    testWidgets('says no report can be sent yet and never claims one was',
        (t) async {
      final copied = _mockClipboard(t);
      final pushed = <String?>[];
      await _open(t, _tx(), pushed: pushed);
      await _tap(t, 'Report an issue');

      expect(find.text('Report a problem with this payment'), findsOneWidget);
      expect(find.textContaining("can't send a report from the app yet"),
          findsOneWidget);
      expect(find.textContaining('submitted'), findsNothing);
      expect(find.byType(TextField), findsNothing); // no form that goes nowhere

      final inSheet = find.byType(BottomSheet);
      await t.tap(find.descendant(of: inSheet, matching: find.text('Copy')));
      await t.pump();
      expect(copied, ['CTS-7F3K9Q2M']);
      expect(find.descendant(of: inSheet, matching: find.text('Copied')),
          findsOneWidget);

      await t.tap(find.text('Open Help & Support'));
      await t.pumpAndSettle();
      expect(pushed, ['/help-support']);
      expect(find.text('ROUTE /help-support'), findsOneWidget);
    });

    testWidgets('Close leaves the receipt without side effects', (t) async {
      final pushed = <String?>[];
      await _open(t, _tx(), pushed: pushed);
      await _tap(t, 'Report an issue');
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      expect(find.text('Report a problem with this payment'), findsNothing);
      expect(pushed, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('still appears only for payments', (t) async {
      await _open(t, _tx(credit: true));
      await t.scrollUntilVisible(find.text('Share receipt'), 100);
      expect(find.text('Report an issue'), findsNothing);
    });
  });
}
