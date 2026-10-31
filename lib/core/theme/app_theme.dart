import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import '../constants/app_text_styles.dart';
import 'cts_theme.dart';

class AppTheme {
  // Font families
  static const String primaryFontFamily = 'Inter';
  static const String secondaryFontFamily = 'Inter';

  // Color Constants (Strictly synchronized with the premium brand palette)
  static const Color primary = AppColors.primary;
  static const Color primaryColor = AppColors.primary;
  static const Color background = AppColors.background;
  static const Color backgroundColor = AppColors.background;
  static const Color surface = AppColors.surface;
  static const Color surfaceAlt = AppColors.surfaceAlt;
  static const Color danger = AppColors.error;
  static const Color error = AppColors.error;
  static const Color errorColor = AppColors.error;
  static const Color success = AppColors.success;
  static const Color successColor = AppColors.success;
  static const Color warning = AppColors.warning;
  static const Color warningColor = AppColors.warning;
  static const Color info = AppColors.info;
  static const Color border = AppColors.border;
  static const Color borderLight = AppColors.borderLight;
  static const Color textPrimary = AppColors.textPrimary;
  static const Color textSecondary = AppColors.textSecondary;
  static const Color textTertiary = AppColors.textTertiary;
  static const Color textOnDarkMuted = AppColors.textOnDarkMuted;
  
  // Refactored to premium deep forest neutral instead of standard web navy
  static const Color darkNavy = CtsTheme.forest;
  
  // Functional semantic overlays with professional 10% opacity hex weights
  static const Color errorLight = CtsTheme.errorTint;
  static const Color successLight = CtsTheme.successTint;
  
  // The app theme lives in CtsTheme; these keep old references working.
  static final ThemeData lightTheme = CtsTheme.light();
  static final ThemeData darkTheme = CtsTheme.light();

  // Modernized Mono-chromatic brand gradients (Eliminated neon purple fields)
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [CtsTheme.brand, CtsTheme.primary], // #16A34A → #15803D
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  
  static const LinearGradient surfaceGradient = LinearGradient(
    colors: [AppColors.surface, AppColors.surfaceAlt],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  
  // High-fidelity low-frequency ambient shadows
  static List<BoxShadow> get primaryGlow => [
    BoxShadow(
      color: AppColors.primary.withValues(alpha: 0.15),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];
  
  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: const Color(0xFF0B1F16).withValues(alpha: 0.04),
      blurRadius: 24,
      offset: const Offset(0, 4),
    ),
  ];
  
  // Custom Typography Bridges
  static TextStyle get titleLarge => AppTextStyles.heading2;
  static TextStyle get titleMedium => AppTextStyles.heading3;
  static TextStyle get titleSmall => AppTextStyles.heading4;
  static TextStyle get bodyLarge => AppTextStyles.bodyLarge;
  static TextStyle get bodyMedium => AppTextStyles.bodyMedium;
  static TextStyle get bodySmall => AppTextStyles.bodySmall;
  static TextStyle get labelLarge => AppTextStyles.labelLarge;
  static TextStyle get labelMedium => AppTextStyles.labelMedium;
  static TextStyle get labelSmall => AppTextStyles.caption;
  static TextStyle get caption => AppTextStyles.caption;
  static TextStyle get heading1 => AppTextStyles.heading1;
  static TextStyle get heading2 => AppTextStyles.heading2;
  static TextStyle get heading3 => AppTextStyles.heading3;
  static TextStyle get heading4 => AppTextStyles.heading4;
  
  // Spacing System Tokens
  static const double spacingSmall = 8.0;
  static const double spacingMedium = 16.0;
  static const double spacingLarge = 24.0;
  static const double spacingXLarge = 32.0;
  
  // Proportional Premium Rounded Architecture
  static const BorderRadius borderRadiusSmall = BorderRadius.all(Radius.circular(8));
  static const BorderRadius borderRadiusMedium = BorderRadius.all(Radius.circular(12));
  static const BorderRadius borderRadiusLarge = BorderRadius.all(Radius.circular(16));
  static const BorderRadius borderRadiusXLarge = BorderRadius.all(Radius.circular(24));
  static const BorderRadius borderRadiusCircle = BorderRadius.all(Radius.circular(99));
  
  // Structural Padding Blocks
  static const EdgeInsets paddingSmall = EdgeInsets.all(8);
  static const EdgeInsets paddingMedium = EdgeInsets.all(16);
  static const EdgeInsets paddingLarge = EdgeInsets.all(24);
  
  static const EdgeInsets screenPadding = EdgeInsets.symmetric(horizontal: 16);
  static const EdgeInsets screenPaddingVertical = EdgeInsets.symmetric(vertical: 16);

  // ==========================================================================
  // ADD THIS LINE TO FIX THE GAS ORDER SCREEN COMPILER ERROR:
  // ==========================================================================
  static TextStyle get headlineMedium => AppTextStyles.heading2;
}