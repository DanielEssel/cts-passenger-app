// lib/core/theme/cts_theme.dart
//
// CTSGo design tokens shared by Home, Ride, Delivery and Gas. Home's
// HomeTheme is an alias of this class.

import 'package:flutter/material.dart';

class CtsTheme {
  // ── Backgrounds ─────────────────────────────────────────────
  // Sheet & card surfaces — clean whites
  static const Color background = Color(0xFFF8F8F5); // warm white
  static const Color surface = Color(0xFFFFFFFF); // pure white card
  static const Color surfaceAlt = Color(0xFFF2F3EF); // field / inset

  // ── Borders ──────────────────────────────────────────────────
  static const Color border = Color(0xFFE6E8E3); // soft neutral edge
  static const Color borderLight = Color(0xFFF0F1EC); // hairline

  // ── Text ─────────────────────────────────────────────────────
  // On the white sheet — dark charcoal hierarchy
  static const Color textPrimary = Color(0xFF111A14); // green-black charcoal
  static const Color textSecondary = Color(0xFF55615A); // charcoal grey
  static const Color textTertiary = Color(0xFF7D877F); // muted (AA on white)
  static const Color textMuted = Color(0xFF7D877F); // alias

  // ── Brand ─────────────────────────────────────────────────────
  static const Color primary = Color(0xFF16A34A); // CTSGo green
  static const Color primaryDeep = Color(0xFF15803D); // pressed / banners
  static const Color primaryTint = Color(0xFFEFF8F2); // selected surfaces
  static const Color danger = Color(0xFFE53935);
  static const Color error = Color(0xFFE53935);
  static const Color success = Color(0xFF16A34A);
  static const Color warning = Color(0xFFF59E0B);
  static const Color info = Color(0xFF2196F3);

  // ── Dark navy — kept for top bar overlay on map ───────────────
  // The map is dark so the top bar glass uses dark tokens
  static const Color darkNavy = Color(0xFF0A2E1A);
  static const Color glassBackground = Color(0x1AFFFFFF);
  static const Color glassBorder = Color(0x26FFFFFF);

  // ── Gradients ─────────────────────────────────────────────────
  // Primary — pure green, no purple
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF16A34A), Color(0xFF15803D)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Sheet header gradient — white to transparent
  static const LinearGradient sheetHeaderGradient = LinearGradient(
    colors: [Color(0xFFFFFFFF), Color(0xFFF7FAF8)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // ── Shadows ───────────────────────────────────────────────────
  static List<BoxShadow> get primaryGlow => [
        BoxShadow(
          color: const Color(0xFF16A34A).withValues(alpha: 0.22),
          blurRadius: 14,
          offset: const Offset(0, 5),
        ),
      ];

  static List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: const Color(0xFF111A14).withValues(alpha: 0.05),
          blurRadius: 12,
          offset: const Offset(0, 3),
        ),
        BoxShadow(
          color: const Color(0xFF111A14).withValues(alpha: 0.04),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
      ];

  static List<BoxShadow> get sheetShadow => [
        BoxShadow(
          color: const Color(0xFF0D1F14).withValues(alpha: 0.12),
          blurRadius: 40,
          offset: const Offset(0, -8),
        ),
      ];

  // ── Text styles ───────────────────────────────────────────────
  static const TextStyle headingLarge = TextStyle(
    fontFamily: 'Inter',
    color: textPrimary,
    fontSize: 28,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.6,
  );

  static const TextStyle headingMedium = TextStyle(
    fontFamily: 'Inter',
    color: textPrimary,
    fontSize: 20,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontFamily: 'Inter',
    color: textSecondary,
    fontSize: 14,
    height: 1.5,
  );

  static const TextStyle bodySmall = TextStyle(
    fontFamily: 'Inter',
    color: textTertiary,
    fontSize: 12,
    height: 1.5,
  );
}
