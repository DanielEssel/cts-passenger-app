// Gas provider selector: compact chips that keep every provider, a clear
// selected state, 48dp touch targets and long names that wrap, not clip.

import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/gas/presentation/screens/gas_order_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester,
    {double width = 390, double textScale = 1.0}) async {
  // Tall enough that the whole form is laid out without scrolling.
  final size = Size(width, 9000);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
            size: size, textScaler: TextScaler.linear(textScale)),
        child: const GasOrderScreen(),
      ),
    ),
  ));
  await tester.pump();
}

Finder _chip(GasBrand b) => find.ancestor(
    of: find.text(b.displayName), matching: find.byType(CtsSelectableCard));

Rect _chipArea(WidgetTester tester) => tester.getRect(find
    .ancestor(of: _chip(GasBrand.values.first), matching: find.byType(Wrap))
    .first);

void _expectSelected(WidgetTester tester, GasBrand b, bool selected) => expect(
    tester.getSemantics(_chip(b)), isSemantics(isSelected: selected),
    reason: b.displayName);

void main() {
  testWidgets('every provider is offered', (tester) async {
    await _pump(tester);
    for (final b in GasBrand.values) {
      expect(find.text(b.displayName), findsOneWidget, reason: b.displayName);
    }
  });

  testWidgets('chips are compact: single-line, 48dp, several per row',
      (tester) async {
    await _pump(tester);
    final area = _chipArea(tester);
    final first = tester.getRect(_chip(GasBrand.values.first));
    final second = tester.getRect(_chip(GasBrand.values[1]));
    for (final b in GasBrand.values) {
      expect(tester.getSize(_chip(b)).height, 48, reason: b.displayName);
    }
    // Sized to the name, not stretched to a fixed grid column.
    expect(first.width, lessThan(area.width / 2));
    // Rows are one chip tall: 14 providers in far fewer than 14 rows.
    final rows = {
      for (final b in GasBrand.values) tester.getRect(_chip(b)).top.round()
    };
    expect(rows.length, lessThan(GasBrand.values.length));
    expect(second.top >= first.top, isTrue);
  });

  for (final (width, scale) in const [(320.0, 1.0), (320.0, 2.0)]) {
    testWidgets('long names stay readable at ${width}dp, text x$scale',
        (tester) async {
      await _pump(tester, width: width, textScale: scale);
      expect(tester.takeException(), isNull);
      final area = _chipArea(tester);
      for (final b in GasBrand.values) {
        final r = tester.getRect(_chip(b));
        expect(r.height, greaterThanOrEqualTo(48), reason: b.displayName);
        expect(r.left, greaterThanOrEqualTo(area.left - 0.5));
        expect(r.right, lessThanOrEqualTo(area.right + 0.5));
        final p =
            tester.renderObject<RenderParagraph>(find.text(b.displayName));
        expect(p.didExceedMaxLines, isFalse, reason: b.displayName);
      }
    });
  }

  testWidgets('selecting shows a check and the premium; tapping clears',
      (tester) async {
    await _pump(tester);
    const b = GasBrand.totalEnergies;
    _expectSelected(tester, b, false);
    expect(find.text('${b.displayName} premium'), findsNothing);

    await tester.tap(_chip(b));
    await tester.pump();
    _expectSelected(tester, b, true);
    expect(
        find.descendant(
            of: _chip(b), matching: find.byIcon(Icons.check_rounded)),
        findsOneWidget);
    expect(find.text('Tap again to clear'), findsOneWidget);
    expect(find.text('${b.displayName} premium'), findsOneWidget);

    // Only one provider is selected at a time.
    await tester.tap(_chip(GasBrand.goGas));
    await tester.pump();
    _expectSelected(tester, b, false);
    _expectSelected(tester, GasBrand.goGas, true);

    await tester.tap(_chip(GasBrand.goGas));
    await tester.pump();
    _expectSelected(tester, GasBrand.goGas, false);
    for (final brand in GasBrand.values) {
      expect(
          find.descendant(
              of: _chip(brand), matching: find.byIcon(Icons.check_rounded)),
          findsNothing);
    }
  });

  testWidgets('a premium is announced in full, not just as a badge',
      (tester) async {
    await _pump(tester);
    const b = GasBrand.shell;
    final pct = ((b.priceMultiplier - 1) * 100).round();
    expect(find.descendant(of: _chip(b), matching: find.text('+$pct%')),
        findsOneWidget);
    expect(find.bySemanticsLabel('${b.displayName}, +$pct% on gas'),
        findsOneWidget);
    expect(
        find.bySemanticsLabel('${GasBrand.goGas.displayName}, Standard price'),
        findsOneWidget);
  });
}
