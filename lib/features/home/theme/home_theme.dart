import 'package:flutter/material.dart';

class HomeTheme {
  // Background Colors
  static const Color background = Color(0xFF0A0E2A);  // Very dark navy
  static const Color surface = Color(0xFF1A1F3F);     // Dark navy surface
  static const Color surfaceAlt = Color(0xFF252A4A);  // Lighter dark navy
  
  // Border Colors
  static const Color border = Color(0xFF2D3250);
  static const Color borderLight = Color(0xFF373D5F);
  
  // Text Colors
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFF9CA3AF);
  static const Color textTertiary = Color(0xFF6B7280);
  static const Color textMuted = Color(0xFF6B7280);
  
  // Status Colors
  static const Color primary = Color(0xFF00C566);
  static const Color error = Color(0xFFEF4444);
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color info = Color(0xFF3B82F6);
  static const Color danger = Color(0xFFEF4444);
  
  // Glass Effect Colors
  static const Color glassBackground = Color(0x1AFFFFFF); // 10% white
  static const Color glassBorder = Color(0x26FFFFFF);    // 15% white
  
  // Dark Navy for headers
  static const Color darkNavy = Color(0xFF0A0E2A);
  
  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF00C566), Color(0xFF7C3AED)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  
  static List<BoxShadow> get primaryGlow => [
    BoxShadow(
      color: const Color(0xFF00C566).withValues(alpha: 0.3),
      blurRadius: 12,
      offset: const Offset(0, 4),
    ),
  ];
  
  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.2),
      blurRadius: 10,
      offset: const Offset(0, 2),
    ),
  ];
  
  // Text Styles
  static const TextStyle headingLarge = TextStyle(
    color: textPrimary,
    fontSize: 28,
    fontWeight: FontWeight.bold,
  );
  
  static const TextStyle headingMedium = TextStyle(
    color: textPrimary,
    fontSize: 20,
    fontWeight: FontWeight.w600,
  );
  
  static const TextStyle bodyMedium = TextStyle(
    color: textSecondary,
    fontSize: 14,
  );
  
  static const TextStyle bodySmall = TextStyle(
    color: textTertiary,
    fontSize: 12,
  );
}