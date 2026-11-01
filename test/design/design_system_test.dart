// CTSGo design system: readable colour pairs, one font across the app, and
// auth screens that hold up on small phones with large text.

import 'dart:math' as math;

import 'package:cts_transport_app/features/auth/widgets/otp_code_field.dart';
import 'package:cts_transport_app/core/constants/app_colors.dart';
import 'package:cts_transport_app/core/theme/cts_theme.dart';
import 'package:cts_transport_app/features/auth/presentation/login_screen.dart';
import 'package:cts_transport_app/features/auth/presentation/otp_verification_screen.dart';
import 'package:cts_transport_app/features/auth/presentation/signup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Future<void> _pumpSmall(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: CtsTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: screen,
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  group('contrast (WCAG AA)', () {
    const textPairs = {
      'white on action green': (Colors.white, CtsTheme.primary),
      'forest label on vivid button': (CtsTheme.onVivid, CtsTheme.vivid),
      // Text accents on the forest cards and headers use light green; it
      // must read across the whole forest gradient.
      'light green accent on forest card': (
        CtsTheme.appleSoft,
        CtsTheme.forest
      ),
      'light green accent on forest gradient end': (
        CtsTheme.appleSoft,
        CtsTheme.forestMid
      ),
      'deep green on vivid tint': (CtsTheme.primaryDeep, CtsTheme.appleSoft),
      'green text on selected tint': (CtsTheme.primary, CtsTheme.primaryTint),
      'ink on apple green': (CtsTheme.textPrimary, CtsTheme.apple),
      'primary text on page': (CtsTheme.textPrimary, CtsTheme.background),
      'secondary text on card': (CtsTheme.textSecondary, CtsTheme.surface),
      'tertiary text on page': (CtsTheme.textTertiary, CtsTheme.background),
      'link green on card': (CtsTheme.primary, CtsTheme.surface),
      'deep green on selected tint': (
        CtsTheme.primaryDeep,
        CtsTheme.primaryTint
      ),
      'error text on card': (CtsTheme.error, CtsTheme.surface),
      'error text on error tint': (CtsTheme.errorDeep, CtsTheme.errorTint),
      'warning text on warning tint': (CtsTheme.warning, CtsTheme.warningTint),
      'info text on info tint': (CtsTheme.info, CtsTheme.infoTint),
      'muted text on forest': (CtsTheme.onForestMuted, CtsTheme.forest),
      'delivery accent on card': (CtsTheme.serviceDelivery, CtsTheme.surface),
      'gas accent on card': (CtsTheme.serviceGas, CtsTheme.surface),
      'legacy tertiary text': (AppColors.textTertiary, AppColors.surface),
      'legacy warning text': (AppColors.warning, AppColors.surface),
    };
    for (final e in textPairs.entries) {
      test(e.key, () {
        final (fg, bg) = e.value;
        expect(_contrast(fg, bg), greaterThanOrEqualTo(4.5), reason: e.key);
      });
    }

    // Brand green stays on forest only as icons and marks (WCAG 1.4.11
    // non-text contrast, 3:1), never as text.
    test('brand green icons on forest card', () {
      expect(_contrast(CtsTheme.apple, CtsTheme.forest),
          greaterThanOrEqualTo(3.0));
      expect(_contrast(CtsTheme.vivid, CtsTheme.forest), lessThan(4.5),
          reason: 'too low for text on forest: use appleSoft');
    });

    test('legacy palette matches the design system', () {
      expect(AppColors.primary, CtsTheme.primary);
      expect(AppColors.textPrimary, CtsTheme.textPrimary);
      expect(AppColors.error, CtsTheme.error);
      expect(AppColors.background, CtsTheme.background);
    });
  });

  test('vivid green is never paired with white text', () {
    // Guards the rule documented in CtsTheme: white on vivid is 2.3:1.
    expect(_contrast(Colors.white, CtsTheme.vivid), lessThan(4.5));
    expect(
        CtsTheme.light()
            .elevatedButtonTheme
            .style!
            .foregroundColor!
            .resolve({}),
        CtsTheme.onVivid);
    expect(
        CtsTheme.light().filledButtonTheme.style!.foregroundColor!.resolve({}),
        CtsTheme.onVivid);
  });

  group('typography', () {
    test('the app theme uses Inter everywhere', () {
      final theme = CtsTheme.light();
      final t = theme.textTheme;
      for (final style in [
        t.displaySmall,
        t.headlineMedium,
        t.titleLarge,
        t.titleMedium,
        t.bodyLarge,
        t.bodyMedium,
        t.bodySmall,
        t.labelLarge,
        t.labelSmall,
      ]) {
        expect(style?.fontFamily, 'Inter');
      }
      expect(theme.appBarTheme.titleTextStyle?.fontFamily, 'Inter');
    });

    test('no role in the scale is smaller than 12', () {
      for (final s in [
        CtsText.display,
        CtsText.title1,
        CtsText.title2,
        CtsText.title3,
        CtsText.section,
        CtsText.cardTitle,
        CtsText.body,
        CtsText.bodySmall,
        CtsText.label,
        CtsText.caption,
        CtsText.overline,
        CtsText.button,
        CtsText.navLabel,
        CtsText.price,
        CtsText.priceLarge,
      ]) {
        expect(s.fontSize, greaterThanOrEqualTo(12));
      }
    });
  });

  group('auth on a small phone with 2x text', () {
    testWidgets('OTP digit boxes fit without overflowing', (tester) async {
      await _pumpSmall(tester, const OtpVerificationScreen());
      expect(tester.takeException(), isNull);
      // One input behind six boxes (paste and SMS autofill need a single
      // field); the boxes must still fit the screen.
      final field = tester.getRect(find.byType(OtpCodeField));
      expect(field.left, greaterThanOrEqualTo(0));
      expect(field.right, lessThanOrEqualTo(320));
    });

    testWidgets('login lays out and keeps its actions', (tester) async {
      await _pumpSmall(tester, const LoginScreen());
      expect(tester.takeException(), isNull);
      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Create an account'), findsOneWidget);
    });

    testWidgets('signup lays out and keeps its actions', (tester) async {
      await _pumpSmall(tester, const SignupScreen());
      expect(tester.takeException(), isNull);
      expect(find.text('Create Account'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    });
  });
}
