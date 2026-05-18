// lib/core/constants/app_colors.dart

import 'package:flutter/material.dart';

// ════════════════════════════════════════════════════════════
//  CTS TRANSPORT — PREMIUM DARK OBSIDIAN PALETTE
//
//  Philosophy: luxury night-time transport.
//  Obsidian blacks + electric emerald + champagne gold.
//  Every name is identical to the original — zero breakage.
// ════════════════════════════════════════════════════════════

class AppColors {

  // ──────────────────────────────────────────────────────────
  // PRIMARY  —  Electric Emerald
  // Vibrant, modern green. Used for CTAs, active states,
  // glows. Feels alive against the dark backgrounds.
  // ──────────────────────────────────────────────────────────
  static const Color primary       = Color(0xFF00C566); // electric emerald
  static const Color primaryDark   = Color(0xFF009E52); // pressed / deep state
  static const Color primaryLight  = Color(0xFF33D47F); // hover / highlight
  static const Color primaryDim    = Color(0x1A00C566); // 10 % tint overlay
  static const Color primaryGlow1  = Color(0x4000C566); // glow shadow / bloom

  // ──────────────────────────────────────────────────────────
  // SECONDARY  —  Champagne Gold
  // Warm luxury accent. Used for badges, ratings, premium
  // tier indicators. Never competes with primary.
  // ──────────────────────────────────────────────────────────
  static const Color secondary      = Color(0xFFD4A843); // champagne gold
  static const Color secondaryDark  = Color(0xFFB08B2E); // deep amber
  static const Color secondaryLight = Color(0xFFE8C86A); // pale gold shimmer
  static const Color secondaryDim   = Color(0x1AD4A843); // 10 % tint overlay
  static const Color goldAccent     = Color(0xFFD4A843); // alias — same token

  // ──────────────────────────────────────────────────────────
  // BACKGROUNDS  —  Obsidian Depth Scale
  // Layered near-blacks with a subtle warm-green undertone so
  // the emerald primary reads crisply without harshness.
  // ──────────────────────────────────────────────────────────
  static const Color background        = Color(0xFE070E1C); // deep obsidian
  static const Color backgroundAlt     = Color(0xFF0C1410); // slightly lifted
  static const Color surface           = Color(0xFF111A15); // card base
  static const Color surfaceAlt        = Color(0xFF182219); // raised card
  static const Color surfaceElevated   = Color(0xFF1F2D22); // modal / sheet

  // Dark-specific aliases kept for any dark-mode-specific refs
  static const Color darkSurface = Color(0xFF0C1410);
  static const Color darkNavy    = Color(0xFF060C09);
  static const Color deepBlue    = Color(0xFF0C1410); // name preserved; green-dark
  static const Color darkBlue    = Color(0xFF111A15); // name preserved; green-dark

  // ──────────────────────────────────────────────────────────
  // TEXT  —  Pearl Hierarchy
  // High-contrast pearl white stepping down to ghost gray.
  // ──────────────────────────────────────────────────────────
  static const Color textPrimary     = Color(0xFFF0F7F3); // near-white pearl
  static const Color textSecondary   = Color(0xFFADC4B7); // muted sage
  static const Color textTertiary    = Color(0xFF6A8878); // ghost metadata
  static const Color textDisabled    = Color(0xFF3A5046); // disabled state
  static const Color textOnDark      = Color(0xFFF0F7F3); // on dark surfaces
  static const Color textOnDarkMuted = Color(0xFFADC4B7); // secondary on dark

  // ──────────────────────────────────────────────────────────
  // STATUS COLORS  —  Vivid, readable on dark
  // ──────────────────────────────────────────────────────────
  static const Color success      = Color(0xFF00C566);
  static const Color successLight = Color(0x1A00C566);
  static const Color successDark  = Color(0xFF009E52);

  static const Color error        = Color(0xFFFF4D4D);
  static const Color errorLight   = Color(0x1AFF4D4D);
  static const Color errorDark    = Color(0xFFCC3333);

  static const Color warning      = Color(0xFFFFB800);
  static const Color warningLight = Color(0x1AFFB800);
  static const Color warningDark  = Color(0xFFCC9200);

  static const Color info         = Color(0xFF3D9BE9);
  static const Color infoLight    = Color(0x1A3D9BE9);
  static const Color infoDark     = Color(0xFF2578C4);

  // ──────────────────────────────────────────────────────────
  // BORDERS & DIVIDERS
  // Very subtle — visible but never distracting on dark bg.
  // ──────────────────────────────────────────────────────────
  static const Color border       = Color(0xFF1E2E26); // soft dark edge
  static const Color borderLight  = Color(0xFF162019); // hairline
  static const Color borderFocus  = Color(0x4000C566); // active input ring
  static const Color divider      = Color(0xFF182219); // section rule

  // ──────────────────────────────────────────────────────────
  // COMPONENT TOKENS
  // ──────────────────────────────────────────────────────────
  static const Color shimmerBase      = Color(0xFF182219);
  static const Color shimmerHighlight = Color(0xFF243028);

  // ──────────────────────────────────────────────────────────
  // MAP COLORS  —  Dark map tile tones
  // ──────────────────────────────────────────────────────────
  static const Color mapRoad          = Color(0xFF2A3E34);
  static const Color mapRoadHighlight = Color(0xFF334A3D);
  static const Color mapWater         = Color(0xFF0D2131);
  static const Color mapBuilding      = Color(0xFF1A2A21);
  static const Color mapPark          = Color(0xFF152B1E);

  // ──────────────────────────────────────────────────────────
  // RIDE TYPE ACCENT COLORS
  // Each service has its own identity accent.
  // ──────────────────────────────────────────────────────────
  static const Color taxi     = Color(0xFF00C566); // emerald  — flagship
  static const Color okada    = Color(0xFFD4A843); // gold     — fast & agile
  static const Color delivery = Color(0xFF3D9BE9); // sapphire — logistics
  static const Color gas      = Color(0xFFFF7A35); // ember    — energy/heat

  // ──────────────────────────────────────────────────────────
  // UTILITY
  // ──────────────────────────────────────────────────────────
  static const Color white       = Colors.white;
  static const Color black       = Colors.black;
  static const Color transparent = Colors.transparent;

  // ──────────────────────────────────────────────────────────
  // LEGACY ALIASES  —  untouched for zero breakage
  // ──────────────────────────────────────────────────────────
  static const Color primaryColor       = primary;
  static const Color borderColor        = border;
  static const Color errorColor         = error;
  static const Color textPrimaryColor   = textPrimary;
  static const Color textSecondaryColor = textSecondary;
  static const Color textDisabledColor  = textDisabled;
  static const Color backgroundColor    = background;
}