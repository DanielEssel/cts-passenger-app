// lib/features/gas/theme/gas_theme.dart

import 'package:flutter/material.dart';

class GasTheme {
  // ── Brand colors — premium forest green ──
  static const Color primary       = Color(0xFF16A34A); // CTSGo green
  static const Color primaryDark   = Color(0xFF15803D); // deep green
  static const Color primaryLight  = Color(0xFF22C55E); // soft green
  static const Color primaryDim    = Color(0xFFE8F5EC); // green tint

  static const Color accent        = Color(0xFF00C566); // electric green
  static const Color accentDim     = Color(0xFFF0FDF9); // accent tint

  // ── Surfaces ──
  static const Color background    = Color(0xFFF8F8F5);
  static const Color surface       = Color(0xFFFFFFFF);
  static const Color surfaceAlt    = Color(0xFFF2F3EF);

  // ── Text ──
  static const Color textPrimary   = Color(0xFF111A14);
  static const Color textSecondary = Color(0xFF55615A);
  static const Color textTertiary  = Color(0xFF7D877F);

  // ── Status ──
  static const Color success       = Color(0xFF16A34A);
  static const Color error         = Color(0xFFE53935);
  static const Color warning       = Color(0xFFF59E0B);

  // ── Border ──
  static const Color border        = Color(0xFFE6E8E3);

  // ── Gradients ──
  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF15803D), Color(0xFF16A34A)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0xFFF1F8F3), Color(0xFFF6FAF7)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static List<BoxShadow> get primaryGlow => [
    BoxShadow(
      color: const Color(0xFF16A34A).withValues(alpha: 0.18),
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