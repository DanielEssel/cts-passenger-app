// lib/core/constants/app_colors.dart

import 'package:flutter/material.dart';

// ════════════════════════════════════════════════════════════
//  CTSGo — APPLE-GREEN PALETTE (legacy names)
//
//  Values mirror CtsTheme (lib/core/theme/cts_theme.dart), the
//  source of truth. Names are kept so existing screens compile
//  unchanged; new code should use CtsTheme / CtsText.
// ════════════════════════════════════════════════════════════

class AppColors {

  // ──────────────────────────────────────────────────────────
  // PRIMARY  —  Forest Green
  // Rich, confident green. Readable on white, premium on card.
  // ──────────────────────────────────────────────────────────
  static const Color primary       = Color(0xFF15803D); // CTSGo action green (CtsTheme.primary)
  static const Color primaryDark   = Color(0xFF15803D); // deep pressed state
  static const Color primaryLight  = Color(0xFF16A34A); // brand-green accent
  static const Color primaryDim    = Color(0xFFDCFCE7); // selected tint
  static const Color primaryGlow1  = Color(0x4015803D); // glow shadow

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
  static const Color background        = Color(0xFFF7F9F7); // page
  static const Color backgroundAlt     = Color(0xFFF0F3F0); // slightly tinted
  static const Color surface           = Color(0xFFFFFFFF); // pure white card
  static const Color surfaceAlt        = Color(0xFFF0F3F0); // inset / field
  static const Color surfaceElevated   = Color(0xFFDCFCE7); // tinted panel

  // Dark-specific aliases — kept for headers / navbars
  static const Color darkSurface = Color(0xFF166534); // deep forest
  static const Color darkNavy    = Color(0xFF0F3D24); // richest forest black
  static const Color deepBlue    = Color(0xFF0D3D24); // name preserved
  static const Color darkBlue    = Color(0xFF0F4A2C); // name preserved

  // ──────────────────────────────────────────────────────────
  // TEXT  —  Charcoal Hierarchy
  // Deep charcoal stepping down to soft sage.
  // Excellent readability on white backgrounds.
  // ──────────────────────────────────────────────────────────
  static const Color textPrimary     = Color(0xFF17211B); // ink
  static const Color textSecondary   = Color(0xFF667168); // secondary (5.1:1)
  static const Color textTertiary    = Color(0xFF6B756D); // tertiary (4.8:1)
  static const Color textDisabled    = Color(0xFF9AA39C); // disabled
  static const Color textOnDark      = Color(0xFFF7F9F7); // on dark surfaces
  static const Color textOnDarkMuted = Color(0xFFC9EDB8); // secondary on dark

  // ──────────────────────────────────────────────────────────
  // STATUS COLORS  —  Vivid, readable on white
  // ──────────────────────────────────────────────────────────
  static const Color success      = Color(0xFF15803D);
  static const Color successLight = Color(0xFFDCFCE7);
  static const Color successDark  = Color(0xFF15803D);

  static const Color error        = Color(0xFFDC2626);
  static const Color errorLight   = Color(0xFFFEF2F2);
  static const Color errorDark    = Color(0xFFB91C1C);

  static const Color warning      = Color(0xFFB45309); // readable amber
  static const Color warningLight = Color(0xFFFFF7E6);
  static const Color warningDark  = Color(0xFF92400E);

  static const Color info         = Color(0xFF1D4ED8);
  static const Color infoLight    = Color(0xFFEFF4FF);
  static const Color infoDark     = Color(0xFF1E3A8A);

  // ──────────────────────────────────────────────────────────
  // BORDERS & DIVIDERS
  // Subtle on white — visible but never heavy.
  // ──────────────────────────────────────────────────────────
  static const Color border       = Color(0xFFE1E7E1); // card & field edge
  static const Color borderLight  = Color(0xFFEDF1ED); // hairline
  static const Color borderFocus  = Color(0x6615803D); // active input ring
  static const Color divider      = Color(0xFFEDF1ED); // section rule

  // ──────────────────────────────────────────────────────────
  // COMPONENT TOKENS
  // ──────────────────────────────────────────────────────────
  static const Color shimmerBase      = Color(0xFFEDF1ED);
  static const Color shimmerHighlight = Color(0xFFF7F9F7);

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
  static const Color taxi     = Color(0xFF15803D); // brand green — flagship
  static const Color okada    = Color(0xFFB45309); // amber — fast & agile
  static const Color delivery = Color(0xFF0369A1); // sky — logistics
  static const Color gas      = Color(0xFFC2410C); // ember — energy

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


  // ──────────────────────────────────────────────────────────
// TYPOGRAPHY TOKENS
// Premium Transport App Typography
// ──────────────────────────────────────────────────────────

static const TextStyle titleLarge = TextStyle(
  fontSize: 24,
  fontWeight: FontWeight.w700,
  color: textPrimary,
  letterSpacing: -0.5,
);

static const TextStyle titleMedium = TextStyle(
  fontSize: 18,
  fontWeight: FontWeight.w600,
  color: textPrimary,
);

static const TextStyle bodyMedium = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w400,
  color: textSecondary,
  height: 1.5,
);

static const TextStyle labelSmall = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w500,
  color: textTertiary,
  letterSpacing: 0.2,
);
}

