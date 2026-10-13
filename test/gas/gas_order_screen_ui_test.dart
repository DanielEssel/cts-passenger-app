// Gas order screen redesign: renders immediately, shows the prices GasPricing
// charges, and keeps the existing validation gate on the confirm button.

import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/gas/presentation/screens/gas_order_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester,
    {Size size = const Size(390, 844), double textScale = 1.0}) async {
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

String _price(double v) => '₵${v.toStringAsFixed(0)}';

void main() {
  testWidgets('form is fully visible on the first frame (no fade-in)',
      (tester) async {
    await _pump(tester);
    // No fade wraps the form itself (route transitions and the scrollbar
    // thumb have their own, which are fine).
    final inScreen = find
        .descendant(
            of: find.byType(GasOrderScreen),
            matching: find.byType(FadeTransition))
        .evaluate()
        .map((e) => e.widget)
        .toSet();
    final aroundForm = tester.widgetList(find.ancestor(
        of: find.text('Service'), matching: find.byType(FadeTransition)));
    expect(aroundForm.where(inScreen.contains), isEmpty);
    expect(find.text('Service'), findsOneWidget);
    expect(find.text('Exchange Empty'), findsOneWidget);
  });

  testWidgets('cylinder prices follow the selected service', (tester) async {
    await _pump(tester);
    const size = CylinderSize.kg6;
    expect(find.text(_price(size.refillPrice)), findsWidgets);

    await tester.tap(find.text('New Cylinder'));
    await tester.pump();
    expect(find.text('Price per new cylinder'), findsOneWidget);
    expect(find.text(_price(size.fullCylinderPrice)), findsWidgets);
  });

  testWidgets('confirm stays disabled until address and safety are set',
      (tester) async {
    await _pump(tester);
    final button =
        tester.widget<CtsPrimaryButton>(find.byType(CtsPrimaryButton));
    expect(button.onPressed, isNull);
    expect(find.textContaining('to continue'), findsOneWidget);

    // Accepting safety alone is not enough: an address is still required.
    await tester.scrollUntilVisible(
        find.text('I confirm all safety requirements are met'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('I confirm all safety requirements are met'));
    await tester.pump();
    expect(
        tester
            .widget<CtsPrimaryButton>(find.byType(CtsPrimaryButton))
            .onPressed,
        isNull);
  });

  for (final scale in const [1.0, 1.3]) {
    testWidgets('no overflow at 320dp, text x$scale', (tester) async {
      await _pump(tester, size: const Size(320, 640), textScale: scale);
      expect(tester.takeException(), isNull);
      // Scroll through every section.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
