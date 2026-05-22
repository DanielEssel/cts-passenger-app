// lib/features/home/theme/home_theme.dart

import 'package:flutter/material.dart';



class HomeTheme {

  // ── Backgrounds ─────────────────────────────────────────────
  // Sheet & card surfaces — clean whites
  static const Color background  = Color(0xFFF7FAF8); // off-white sage
  static const Color surface     = Color(0xFFFFFFFF); // pure white sheet
  static const Color surfaceAlt  = Color(0xFFF3F8F5); // lifted card

  // ── Borders ──────────────────────────────────────────────────
  static const Color border      = Color(0xFFDDEBE4); // soft sage edge
  static const Color borderLight = Color(0xFFEEF5F1); // hairline

  // ── Text ─────────────────────────────────────────────────────
  // On the white sheet — dark charcoal hierarchy
  static const Color textPrimary   = Color(0xFF0D1F14); // deep forest black
  static const Color textSecondary = Color(0xFF4A6B57); // sage charcoal
  static const Color textTertiary  = Color(0xFF8CA898); // muted sage
  static const Color textMuted     = Color(0xFF8CA898); // alias

  // ── Brand ─────────────────────────────────────────────────────
  static const Color primary = Color(0xFF00A86B); // forest emerald
  static const Color danger  = Color(0xFFE53935);
  static const Color error   = Color(0xFFE53935);
  static const Color success = Color(0xFF00A86B);
  static const Color warning = Color(0xFFF59E0B);
  static const Color info    = Color(0xFF2196F3);

  // ── Dark navy — kept for top bar overlay on map ───────────────
  // The map is dark so the top bar glass uses dark tokens
  static const Color darkNavy        = Color(0xFF0A2E1A);
  static const Color glassBackground = Color(0x1AFFFFFF);
  static const Color glassBorder     = Color(0x26FFFFFF);

  // ── Gradients ─────────────────────────────────────────────────
  // Primary — pure green, no purple
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF00A86B), Color(0xFF00C97E)],
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
      color: const Color(0xFF00A86B).withValues(alpha: 0.28),
      blurRadius: 16,
      offset: const Offset(0, 6),
    ),
  ];

  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: const Color(0xFF0D1F14).withValues(alpha: 0.06),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
    BoxShadow(
      color: const Color(0xFF0D1F14).withValues(alpha: 0.03),
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