// Small phone (320 px) with 2x text: headlines never split a word, and the
// Mobile Money networks keep their full names and stay selectable.

import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:cts_transport_app/core/constants/app_text_styles.dart';
import 'package:cts_transport_app/core/theme/cts_theme.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/wallet/presentation/widgets/bridge_momo_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester t, Widget child,
    {Size size = const Size(320, 640), double scale = 2}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: CtsTheme.light(),
      home: Builder(
        builder: (c) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: Scaffold(body: child),
        ),
      ),
    ),
  ));
  await t.pump(const Duration(milliseconds: 300));
}

/// True when no single word is wider than the line, i.e. Flutter never had
/// to break inside a word.
bool _wordsFit(WidgetTester t, Finder text) {
  final p = t.renderObject<RenderParagraph>(text);
  return p.getMinIntrinsicWidth(double.infinity) <= p.size.width + 0.5;
}

// Measure with the app's real font (the test default draws every glyph as a
// wide square, which would exaggerate widths).
Future<void> _loadInter() async {
  final loader = FontLoader('Inter');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/inter/Inter-$w.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void main() {
  setUpAll(_loadInter);

  group('Welcome headline (CtsWholeWordText)', () {
    Widget headline(String text) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: CtsWholeWordText(text,
              style: AppTextStyles.display,
              textAlign: TextAlign.center,
              horizontalInset: 48),
        );

    for (final text in [
      'Welcome! 🎉',
      'Welcome, Ama! 🎉',
      'Welcome, Oluwaseyifunmi! 🎉',
    ]) {
      testWidgets('"$text" keeps whole words at 320px @2x', (t) async {
        await _pump(t, headline(text));
        expect(t.takeException(), isNull);
        expect(_wordsFit(t, find.text(text)), isTrue);
      });
    }

    testWidgets('works inside the full-height scroll layout used by Welcome',
        (t) async {
      await _pump(
          t,
          CtsFillScrollView(
            child: Column(children: [
              const Spacer(),
              headline('Welcome! 🎉'),
              const Spacer(),
            ]),
          ));
      expect(t.takeException(), isNull);
      expect(_wordsFit(t, find.text('Welcome! 🎉')), isTrue);
    });

    testWidgets('keeps the user text scale when the words already fit',
        (t) async {
      await _pump(t, headline('Hi'), scale: 2);
      final text = t.widget<Text>(find.text('Hi'));
      expect(text.textScaler, const TextScaler.linear(2));
    });

    testWidgets('only scales down as far as needed', (t) async {
      await _pump(t, headline('Welcome! 🎉'), scale: 2);
      final s = t.widget<Text>(find.text('Welcome! 🎉')).textScaler!.scale(1);
      expect(s, lessThan(2));
      expect(s, greaterThan(1)); // still larger than the default size
    });
  });

  group('Mobile Money networks', () {
    const names = ['MTN', 'TELECEL', 'AIRTELTIGO'];
    Widget sheet() =>
        const SingleChildScrollView(child: BridgeMomoSheet(amount: 50));

    testWidgets('full names, no overflow at 320px @2x', (t) async {
      await _pump(t, sheet());
      expect(t.takeException(), isNull);
      for (final n in names) {
        final p = t.renderObject<RenderParagraph>(find.text(n));
        expect(p.didExceedMaxLines, isFalse, reason: n);
        expect(_wordsFit(t, find.text(n)), isTrue, reason: n);
      }
      // Stacked one per row at this size.
      final ys = names.map((n) => t.getTopLeft(find.text(n)).dy).toList();
      expect(ys.toSet().length, names.length);
    });

    testWidgets('three across on a regular phone at 1x', (t) async {
      await _pump(t, sheet(), size: const Size(390, 844), scale: 1);
      expect(t.takeException(), isNull);
      final ys = names.map((n) => t.getTopLeft(find.text(n)).dy).toSet();
      expect(ys.length, 1);
    });

    testWidgets('each network is a selectable button for screen readers',
        (t) async {
      final h = t.ensureSemantics();
      await _pump(t, sheet());
      final node = t
          .getSemantics(find.bySemanticsLabel('Telecel Cash'))
          .getSemanticsData();
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.hasAction(SemanticsAction.tap), isTrue);
      t.semantics.tap(find.semantics.byLabel('Telecel Cash'));
      await t.pump(const Duration(milliseconds: 300));
      expect(
          t
                  .getSemantics(find.bySemanticsLabel('Telecel Cash'))
                  .getSemanticsData()
                  .flagsCollection
                  .isSelected ==
              Tristate.isTrue,
          isTrue);
      h.dispose();
    });
  });
}
