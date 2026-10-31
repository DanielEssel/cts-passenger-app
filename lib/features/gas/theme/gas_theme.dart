// lib/features/gas/theme/gas_theme.dart

import 'package:flutter/material.dart';

import '../../../core/theme/cts_theme.dart';

// Values come from CtsTheme so Gas matches the rest of the app.
class GasTheme {
  static const Color primary       = CtsTheme.primary;
  static const Color primaryDark   = CtsTheme.primaryDeep;
  static const Color primaryLight  = CtsTheme.apple;
  static const Color primaryDim    = CtsTheme.primaryTint;

  static const Color accent        = CtsTheme.apple;
  static const Color accentDim     = CtsTheme.primaryTint;

  // ── Surfaces ──
  static const Color background    = CtsTheme.background;
  static const Color surface       = CtsTheme.surface;
  static const Color surfaceAlt    = CtsTheme.surfaceAlt;

  // ── Text ──
  static const Color textPrimary   = CtsTheme.textPrimary;
  static const Color textSecondary = CtsTheme.textSecondary;
  static const Color textTertiary  = CtsTheme.textTertiary;

  // ── Status ──
  static const Color success       = CtsTheme.success;
  static const Color error         = CtsTheme.error;
  static const Color warning       = CtsTheme.warning;

  // ── Border ──
  static const Color border        = CtsTheme.border;

  // ── Gradients ──
  static const LinearGradient heroGradient = LinearGradient(
    colors: [CtsTheme.brand, CtsTheme.primary], // #16A34A → #15803D
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cardGradient = LinearGradient(
    colors: [CtsTheme.primaryTint, CtsTheme.background],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static List<BoxShadow> get primaryGlow => [
    BoxShadow(
      color: CtsTheme.primary.withValues(alpha: 0.18),
      blurRadius: 10,
      offset: const Offset(0, 4),
    ),
  ];

  // Keep emberGlow as alias so screen code doesn't break
  static List<BoxShadow> get emberGlow => primaryGlow;

  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.05),
      blurRadius: 8,
      offset: const Offset(0, 4),
    ),
  ];
}