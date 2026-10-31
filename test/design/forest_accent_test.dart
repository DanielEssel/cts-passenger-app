// Accents on the dark forest surfaces: text and accents on light tiles use
// light green (#DCFCE7) so they read at any text size; brand green
// (#16A34A) stays only on icons sitting directly on forest (3:1 non-text).

import 'dart:math' as math;

import 'package:cts_transport_app/core/theme/cts_theme.dart';
import 'package:cts_transport_app/core/widgets/cts_booking.dart';
import 'package:cts_transport_app/features/ride/presentation/trip_complete_screen.dart';
import 'package:cts_transport_app/features/wallet/presentation/screens/transaction_detail_screen.dart';
import 'package:cts_transport_app/features/wallet/presentation/screens/wallet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Widget _app(Widget home) => ProviderScope(
      child: MaterialApp(theme: CtsTheme.light(), home: home),
    );

void main() {
  test('light green reads on both ends of the forest gradient', () {
    expect(_contrast(CtsTheme.appleSoft, CtsTheme.forest),
        greaterThanOrEqualTo(4.5));
    expect(_contrast(CtsTheme.appleSoft, CtsTheme.forestMid),
        greaterThanOrEqualTo(4.5));
  });

  testWidgets('booking header: eyebrow, icon and progress use light green',
      (t) async {
    await t.pumpWidget(_app(const Scaffold(
      body: CtsBrandHeader(
        title: 'Gas refill',
        subtitle: 'Delivered to your door',
        eyebrow: 'Gas',
        icon: Icons.local_fire_department_rounded,
        footer: CtsHeaderProgress(
            steps: ['Cylinder', 'Address', 'Pay'], current: 1),
      ),
    )));
    await t.pump();

    final eyebrow = t.widget<Text>(find.text('GAS'));
    expect(eyebrow.style?.color, CtsTheme.appleSoft);

    final icon =
        t.widget<Icon>(find.byIcon(Icons.local_fire_department_rounded));
    expect(icon.color, CtsTheme.appleSoft);

    // Active segments (steps 1 and 2) in light green, the rest translucent.
    final bars = t
        .widgetList<Container>(find.byType(Container))
        .where((c) => c.constraints?.maxHeight == 4)
        .map((c) => (c.decoration as BoxDecoration).color)
        .toList();
    expect(bars.take(2), everyElement(CtsTheme.appleSoft));
    expect(bars.last, isNot(CtsTheme.appleSoft));
  });

  testWidgets('receipt hero: credit sign and icon use light green', (t) async {
    await t.pumpWidget(_app(const TransactionDetailScreen(
      tx: TxItem(
        icon: Icons.south_west_rounded,
        iconBg: CtsTheme.appleSoft,
        iconColor: CtsTheme.primaryDeep,
        label: 'Wallet top-up',
        sub: 'Today 9:12',
        amount: '+GHS 100.00',
        isCredit: true,
        type: 'Top-ups',
        ref: 'CTS-1',
        fullDate: 'Oct 19, 2026 · 9:12 AM',
        status: 'completed',
        note: '',
      ),
    )));
    await t.pumpAndSettle();

    final amount = t
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere((r) => r.text.toPlainText() == '+ GHS 100.00');
    TextSpan? sign;
    amount.text.visitChildren((span) {
      if (span is TextSpan && span.text == '+ ') sign = span;
      return sign == null;
    });
    expect(sign, isNotNull);
    expect(sign!.style?.color, CtsTheme.appleSoft);

    expect(t.widget<Icon>(find.byIcon(Icons.south_west_rounded)).color,
        CtsTheme.appleSoft);
  });

  testWidgets('trip complete: wallet caption uses light green, icon stays',
      (t) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(const TripCompleteScreen(
      tripId: 't1',
      driverId: 'd1',
      driverName: 'Kwame Mensah',
      destination: 'Accra Mall',
      fare: 'GHS 42.50',
      rideType: 'Taxi',
      driverRating: 4.8,
    )));
    await t.pump(const Duration(seconds: 2));

    final caption = t.widget<Text>(find.text('CTSGo Wallet'));
    expect(caption.style?.color, CtsTheme.appleSoft);

    // The 14px wallet icon sits directly on solid forest: 3:1 is enough.
    final icon =
        t.widget<Icon>(find.byIcon(Icons.account_balance_wallet_rounded));
    expect(icon.color, CtsTheme.apple);
    expect(_contrast(icon.color!, CtsTheme.forest), greaterThanOrEqualTo(3.0));
  });
}
