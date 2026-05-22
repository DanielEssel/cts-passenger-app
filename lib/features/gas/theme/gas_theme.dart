// lib/features/gas/theme/gas_theme.dart

import 'package:flutter/material.dart';

class GasTheme {
  // ── Brand colors — premium forest green ──
  static const Color primary       = Color(0xFF00A86B); // forest green
  static const Color primaryDark   = Color(0xFF007A4D); // deep forest
  static const Color primaryLight  = Color(0xFF33C98A); // soft green
  static const Color primaryDim    = Color(0xFFE6F7F1); // green tint

  static const Color accent        = Color(0xFF00C566); // electric green
  static const Color accentDim     = Color(0xFFF0FDF9); // accent tint

  // ── Surfaces ──
  static const Color background    = Color(0xFFF7FAF8);
  static const Color surface       = Color(0xFFFFFFFF);
  static const Color surfaceAlt    = Color(0xFFF3F8F5);

  // ── Text ──
  static const Color textPrimary   = Color(0xFF0D1F14);
  static const Color textSecondary = Color(0xFF4A6B57);
  static const Color textTertiary  = Color(0xFF8CA898);

  // ── Status ──
  static const Color success       = Color(0xFF00A86B);
  static const Color error         = Color(0xFFE53935);
  static const Color warning       = Color(0xFFF59E0B);

  // ── Border ──
  static const Color border        = Color(0xFFDDEBE4);

  // ── Gradients ──
  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF007A4D), Color(0xFF00A86B), Color(0xFF00C566)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0xFFE6F7F1), Color(0xFFF0FDF9)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static List<BoxShadow> get primaryGlow => [
    BoxShadow(
      color: const Color(0xFF00A86B).withValues(alpha: 0.3),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];

  // Keep emberGlow as alias so screen code doesn't break
  static List<BoxShadow> get emberGlow => primaryGlow;

  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.06),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];
}