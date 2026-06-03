// lib/core/constants/app_colors.dart

import 'package:flutter/material.dart';

// ════════════════════════════════════════════════════════════
//  CTS TRANSPORT — PREMIUM LIGHT FOREST PALETTE
//
//  Philosophy: premium daytime transport — clean, trustworthy,
//  and alive. Crisp whites + rich forest green + warm gold.
//  Every variable name preserved — zero breakage.
// ════════════════════════════════════════════════════════════

class AppColors {

  // ──────────────────────────────────────────────────────────
  // PRIMARY  —  Forest Green
  // Rich, confident green. Readable on white, premium on card.
  // ──────────────────────────────────────────────────────────
  static const Color primary       = Color(0xFF00A86B); // forest emerald
  static const Color primaryDark   = Color(0xFF007A4D); // deep pressed state
  static const Color primaryLight  = Color(0xFF33C98A); // hover / highlight
  static const Color primaryDim    = Color(0xFFE6F7F1); // 10% tint overlay
  static const Color primaryGlow1  = Color(0x4000A86B); // glow shadow

  // ──────────────────────────────────────────────────────────
  // SECONDARY  —  Warm Gold
  // Luxury accent for badges, ratings, premium tiers.
  // ──────────────────────────────────────────────────────────
  static const Color secondary      = Color(0xFFD4A843); // champagne gold
  static const Color secondaryDark  = Color(0xFFB08B2E); // deep amber
  static const Color secondaryLight = Color(0xFFE8C86A); // pale gold shimmer
  static const Color secondaryDim   = Color(0xFFFDF6E3); // 10% tint overlay
  static const Color goldAccent     = Color(0xFFD4A843); // alias

  // ──────────────────────────────────────────────────────────
  // BACKGROUNDS  —  Clean White Scale
  // Pure white base stepping up to very faint sage tints.
  // Feels airy, clinical-clean, premium.
  // ──────────────────────────────────────────────────────────
  static const Color background        = Color(0xFFF7FAF8); // off-white sage
  static const Color backgroundAlt     = Color(0xFFF0F5F2); // slightly tinted
  static const Color surface           = Color(0xFFFFFFFF); // pure white card
  static const Color surfaceAlt        = Color(0xFFF3F8F5); // lifted card
  static const Color surfaceElevated   = Color(0xFFECF4EF); // modal / sheet

  // Dark-specific aliases — kept for headers / navbars
  static const Color darkSurface = Color(0xFF0D3D24); // deep forest
  static const Color darkNavy    = Color(0xFF0A2E1A); // richest forest black
  static const Color deepBlue    = Color(0xFF0D3D24); // name preserved
  static const Color darkBlue    = Color(0xFF0F4A2C); // name preserved

  // ──────────────────────────────────────────────────────────
  // TEXT  —  Charcoal Hierarchy
  // Deep charcoal stepping down to soft sage.
  // Excellent readability on white backgrounds.
  // ──────────────────────────────────────────────────────────
  static const Color textPrimary     = Color(0xFF0D1F14); // deep forest black
  static const Color textSecondary   = Color(0xFF4A6B57); // sage charcoal
  static const Color textTertiary    = Color(0xFF8CA898); // muted sage
  static const Color textDisabled    = Color(0xFFBDD4C7); // disabled
  static const Color textOnDark      = Color(0xFFF7FAF8); // on dark surfaces
  static const Color textOnDarkMuted = Color(0xFFADD4BE); // secondary on dark

  // ──────────────────────────────────────────────────────────
  // STATUS COLORS  —  Vivid, readable on white
  // ──────────────────────────────────────────────────────────
  static const Color success      = Color(0xFF00A86B);
  static const Color successLight = Color(0xFFE6F7F1);
  static const Color successDark  = Color(0xFF007A4D);

  static const Color error        = Color(0xFFE53935);
  static const Color errorLight   = Color(0xFFFFEBEA);
  static const Color errorDark    = Color(0xFFC62828);

  static const Color warning      = Color(0xFFF59E0B);
  static const Color warningLight = Color(0xFFFFF8E1);
  static const Color warningDark  = Color(0xFFD97706);

  static const Color info         = Color(0xFF2196F3);
  static const Color infoLight    = Color(0xFFE3F2FD);
  static const Color infoDark     = Color(0xFF1565C0);

  // ──────────────────────────────────────────────────────────
  // BORDERS & DIVIDERS
  // Subtle on white — visible but never heavy.
  // ──────────────────────────────────────────────────────────
  static const Color border       = Color(0xFFDDEBE4); // soft sage edge
  static const Color borderLight  = Color(0xFFEEF5F1); // hairline
  static const Color borderFocus  = Color(0x6600A86B); // active input ring
  static const Color divider      = Color(0xFFE8F0EC); // section rule

  // ──────────────────────────────────────────────────────────
  // COMPONENT TOKENS
  // ──────────────────────────────────────────────────────────
  static const Color shimmerBase      = Color(0xFFEEF4F0);
  static const Color shimmerHighlight = Color(0xFFF7FAF8);

  // ──────────────────────────────────────────────────────────
  // MAP COLORS  —  Light map tile tones
  // ──────────────────────────────────────────────────────────
  static const Color mapRoad          = Color(0xFFFFFFFF);
  static const Color mapRoadHighlight = Color(0xFFF5F5F5);
  static const Color mapWater         = Color(0xFFBBDEFB);
  static const Color mapBuilding      = Color(0xFFE8EDE9);
  static const Color mapPark          = Color(0xFFC8E6C9);

  // ──────────────────────────────────────────────────────────
  // RIDE TYPE ACCENT COLORS
  // ──────────────────────────────────────────────────────────
  static const Color taxi     = Color(0xFF00A86B); // forest green — flagship
  static const Color okada    = Color(0xFFD4A843); // gold — fast & agile
  static const Color delivery = Color(0xFF2196F3); // sapphire — logistics
  static const Color gas      = Color(0xFFFF7A35); // ember — energy

  // ──────────────────────────────────────────────────────────
  // UTILITY
  // ──────────────────────────────────────────────────────────
  static const Color white       = Colors.white;
  static const Color black       = Colors.black;
  static const Color transparent = Colors.transparent;


  // ──────────────────────────────────────────────────────────
  // LEGACY ALIASES — untouched for zero breakage
  // ──────────────────────────────────────────────────────────
  static const Color primaryColor       = primary;
  static const Color borderColor        = border;
  static const Color errorColor         = error;
  static const Color textPrimaryColor   = textPrimary;
  static const Color textSecondaryColor = textSecondary;
  static const Color textDisabledColor  = textDisabled;
  static const Color backgroundColor    = background;
  static const Color backgroundLightColor = backgroundAlt;
}