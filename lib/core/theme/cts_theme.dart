// lib/core/theme/cts_theme.dart
//
// CTSGo design system: colour, type, spacing and the app's ThemeData.
// Every passenger screen draws from here — HomeTheme is an alias of this
// class and AppColors / AppTextStyles map onto the same values.
//
// Colour rules (contrast measured against WCAG 2.1):
//   • [vivid] (#16A34A, the CTSGo Driver Wallet green) is the dominant
//     CTSGo green: primary buttons, selected chips and tabs, progress,
//     highlights. Text on it is always [onVivid] ink (4.9:1) — never white
//     (3.3:1). It is not used for text or thin icons on white.
//   • [primary] (#15803D) is green for text, icons, links and selected
//     borders on light surfaces (5.0:1 on white).
//   • [forest] (#0F3D24) adds depth: the wallet balance card, booking
//     headers and price panels. Text and small accents on forest use
//     [appleSoft] (12.9:1); [vivid] on forest is 3.7:1, so only for icons
//     and marks sitting directly on the dark forest (3:1 minimum).
//   • [brand] (#16A34A) is the same green as [vivid]; the primary
//     gradient runs [brand] to [primary] (#16A34A to #15803D).
//   • Error, warning and info are kept apart from brand green.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class CtsTheme {
  static const String fontFamily = 'Inter';

  // ── Backgrounds ─────────────────────────────────────────────
  static const Color background = Color(0xFFF7F9F7); // page
  static const Color surface = Color(0xFFFFFFFF); // cards & sheets
  static const Color surfaceAlt = Color(0xFFF0F3F0); // fields / insets

  // ── Borders ──────────────────────────────────────────────────
  static const Color border = Color(0xFFE1E7E1); // card & field edge
  static const Color borderLight = Color(0xFFEDF1ED); // hairline / divider

  // ── Text ─────────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFF17211B); // 15.6:1 on bg
  static const Color textSecondary = Color(0xFF667168); // 5.1:1 on white
  static const Color textTertiary = Color(0xFF6B756D); // 4.8:1 on white
  static const Color textMuted = textTertiary; // alias
  static const Color textDisabled = Color(0xFF9AA39C); // disabled only

  // ── Brand ─────────────────────────────────────────────────────
  static const Color vivid = Color(0xFF16A34A); // dominant brand green
  static const Color onVivid = Color(0xFF17211B); // text & icons on vivid
  static const Color vividPressed = Color(0xFF15803D);
  static const Color apple = vivid; // legacy name for the vivid accent
  static const Color appleSoft = Color(0xFFDCFCE7); // vivid tint fill
  static const Color brand = Color(0xFF16A34A); // legacy CTS reference
  static const Color primary = Color(0xFF15803D); // green text, icons, links
  static const Color primaryDeep = Color(0xFF15803D); // pressed / on tint
  static const Color primaryTint = Color(0xFFF0FDF4); // selected surfaces

  // ── Semantic ─────────────────────────────────────────────────
  static const Color success = primary;
  static const Color successTint = primaryTint;
  static const Color error = Color(0xFFDC2626); // 4.8:1 on white
  static const Color errorDeep = Color(0xFFB91C1C); // text on errorTint
  static const Color errorTint = Color(0xFFFEF2F2);
  static const Color errorBorder = Color(0xFFFECACA);
  static const Color danger = error;
  static const Color warning = Color(0xFFB45309); // amber text & icons
  static const Color warningFill = Color(0xFFF59E0B); // amber marks
  static const Color warningTint = Color(0xFFFFF7E6);
  static const Color warningBorder = Color(0xFFF5D9A8);
  static const Color info = Color(0xFF1D4ED8);
  static const Color infoTint = Color(0xFFEFF4FF);

  // ── Service accents (icons and tints for history, receipts) ──
  static const Color serviceRide = primary;
  static const Color serviceRideTint = primaryTint;
  static const Color serviceDelivery = Color(0xFF0369A1); // 5.9:1 on white
  static const Color serviceDeliveryTint = Color(0xFFE0F2FE);
  static const Color serviceGas = Color(0xFFC2410C); // 5.2:1 on white
  static const Color serviceGasTint = Color(0xFFFFF1E6);

  // ── Booking identity (Delivery & Gas headers, price panels) ──
  static const Color forest = Color(0xFF0F3D24); // deep green
  static const Color forestMid = Color(0xFF166534); // gradient partner
  static const Color onForestMuted = Color(0xFFC9EDB8); // 9.5:1 on forest
  static const Color charcoal = textPrimary;
  static const Color mint = primaryTint;
  static const Color mintBorder = Color(0xFFBBF7D0);
  static const Color canvas = background;
  static const Color cardEdge = border;

  static const LinearGradient forestGradient = LinearGradient(
    colors: [forest, forestMid],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ── Dark tokens — top bar overlay on map ─────────────────────
  static const Color darkNavy = forest;
  static const Color glassBackground = Color(0x1AFFFFFF);
  static const Color glassBorder = Color(0x26FFFFFF);

  // ── Gradients ─────────────────────────────────────────────────
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [brand, primary], // #16A34A → #15803D
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient sheetHeaderGradient = LinearGradient(
    colors: [Color(0xFFFFFFFF), Color(0xFFF7FAF7)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // ── Spacing & shape ──────────────────────────────────────────
  static const double gutter = 16; // page side margin
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 20;
  static const double space6 = 24;
  static const double space8 = 32;

  static const double radiusSm = 10; // chips, small tiles
  static const double radiusMd = 14; // fields, buttons
  static const double radiusLg = 18; // cards
  static const double radiusXl = 24; // sheets, dialogs, hero panels

  static const double minTouch = 48;
  static const double buttonHeight = 54;

  // ── Shadows ───────────────────────────────────────────────────
  static List<BoxShadow> get primaryGlow => [
        BoxShadow(
          color: primary.withValues(alpha: 0.20),
          blurRadius: 14,
          offset: const Offset(0, 5),
        ),
      ];

  static List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: textPrimary.withValues(alpha: 0.05),
          blurRadius: 12,
          offset: const Offset(0, 3),
        ),
        BoxShadow(
          color: textPrimary.withValues(alpha: 0.03),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ];

  static List<BoxShadow> get sheetShadow => [
        BoxShadow(
          color: textPrimary.withValues(alpha: 0.12),
          blurRadius: 40,
          offset: const Offset(0, -8),
        ),
      ];

  // ── Legacy text styles (kept for existing callers) ───────────
  static const TextStyle headingLarge = CtsText.title1;
  static const TextStyle headingMedium = CtsText.title2;
  static const TextStyle bodyMedium = TextStyle(
    fontFamily: fontFamily,
    color: textSecondary,
    fontSize: 14,
    height: 1.5,
  );
  static const TextStyle bodySmall = TextStyle(
    fontFamily: fontFamily,
    color: textTertiary,
    fontSize: 12,
    height: 1.5,
  );

  // ── ThemeData ────────────────────────────────────────────────
  /// The app theme. Material widgets that are not styled by hand (dialogs,
  /// snack bars, sheets, inputs, buttons) pick up the CTSGo look from here.
  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: fontFamily,
    );
    const scheme = ColorScheme.light(
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer: primaryTint,
      onPrimaryContainer: primaryDeep,
      secondary: primary,
      onSecondary: Colors.white,
      secondaryContainer: appleSoft,
      onSecondaryContainer: textPrimary,
      tertiary: apple,
      onTertiary: textPrimary,
      surface: surface,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      surfaceContainerLowest: surface,
      surfaceContainerLow: background,
      surfaceContainer: surfaceAlt,
      surfaceContainerHigh: surfaceAlt,
      surfaceContainerHighest: border,
      outline: border,
      outlineVariant: borderLight,
      error: error,
      onError: Colors.white,
      errorContainer: errorTint,
      onErrorContainer: errorDeep,
    );

    OutlineInputBorder field(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: c, width: w),
        );
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radiusMd),
    );
    const buttonMin = Size(64, minTouch);

    return base.copyWith(
      colorScheme: scheme,
      primaryColor: primary,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      dividerColor: borderLight,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      textTheme: CtsText.textTheme(base.textTheme),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: Colors.transparent,
        foregroundColor: textPrimary,
        centerTitle: false,
        titleTextStyle: CtsText.title3,
        iconTheme: IconThemeData(color: textPrimary, size: 22),
      ),
      iconTheme: const IconThemeData(color: textPrimary, size: 22),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: vivid,
          foregroundColor: onVivid,
          disabledBackgroundColor: surfaceAlt,
          disabledForegroundColor: textTertiary,
          minimumSize: buttonMin,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: CtsText.button,
          shape: buttonShape,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: vivid,
          foregroundColor: onVivid,
          disabledBackgroundColor: surfaceAlt,
          disabledForegroundColor: textTertiary,
          minimumSize: buttonMin,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: CtsText.button,
          shape: buttonShape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          minimumSize: buttonMin,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          side: const BorderSide(color: border, width: 1.2),
          textStyle: CtsText.button,
          shape: buttonShape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          minimumSize: const Size(48, minTouch),
          textStyle: CtsText.label.copyWith(fontSize: 14.5),
          shape: buttonShape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: textPrimary,
          minimumSize: const Size(minTouch, minTouch),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
        border: field(border),
        enabledBorder: field(border),
        focusedBorder: field(primary, 1.6),
        errorBorder: field(error),
        focusedErrorBorder: field(error, 1.6),
        disabledBorder: field(borderLight),
        labelStyle: CtsText.bodySmall.copyWith(color: textSecondary),
        floatingLabelStyle: CtsText.label.copyWith(color: primary),
        hintStyle: CtsText.body.copyWith(color: textTertiary),
        helperStyle: CtsText.caption,
        errorStyle: CtsText.caption.copyWith(color: error),
        prefixIconColor: textSecondary,
        suffixIconColor: textSecondary,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          side: const BorderSide(color: border),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: vivid,
        side: const BorderSide(color: border),
        labelStyle: CtsText.label.copyWith(color: textPrimary),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: const StadiumBorder(),
        checkmarkColor: onVivid,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: textSecondary,
        titleTextStyle: CtsText.cardTitle,
        subtitleTextStyle: CtsText.bodySmall,
        minVerticalPadding: 10,
      ),
      dividerTheme: const DividerThemeData(
        color: borderLight,
        thickness: 1,
        space: 1,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        backgroundColor: surface,
        selectedItemColor: primary,
        unselectedItemColor: textSecondary,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        selectedLabelStyle: CtsText.navLabel,
        unselectedLabelStyle: CtsText.navLabel,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: textPrimary,
        unselectedLabelColor: textSecondary,
        indicatorColor: primary,
        dividerColor: borderLight,
        labelStyle: CtsText.label.copyWith(fontSize: 14),
        unselectedLabelStyle: CtsText.label.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusXl),
        ),
        titleTextStyle: CtsText.title3,
        contentTextStyle: CtsText.body.copyWith(color: textSecondary),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: surface,
        showDragHandle: false,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusXl)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: textPrimary,
        contentTextStyle: CtsText.body.copyWith(color: Colors.white),
        actionTextColor: vivid,
        elevation: 0,
        insetPadding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: appleSoft,
        circularTrackColor: Colors.transparent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Colors.white : textTertiary),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? vivid : surfaceAlt),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? vivid : border),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? primary : Colors.transparent),
        side: const BorderSide(color: textTertiary, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? primary : textTertiary),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: primary,
        selectionColor: apple.withValues(alpha: 0.35),
        selectionHandleColor: primary,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// CTSGo type scale (Inter). Sizes are logical pixels and scale with the
/// device text setting; screens should pick a role here rather than a size.
class CtsText {
  CtsText._();

  static const String _f = CtsTheme.fontFamily;

  /// Hero numbers and onboarding headlines.
  static const TextStyle display = TextStyle(
    fontFamily: _f,
    fontSize: 30,
    height: 1.15,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.8,
    color: CtsTheme.textPrimary,
  );

  /// Page titles.
  static const TextStyle title1 = TextStyle(
    fontFamily: _f,
    fontSize: 26,
    height: 1.2,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.6,
    color: CtsTheme.textPrimary,
  );

  /// Screen headings and sheet titles.
  static const TextStyle title2 = TextStyle(
    fontFamily: _f,
    fontSize: 21,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    color: CtsTheme.textPrimary,
  );

  /// App-bar titles and dialog titles.
  static const TextStyle title3 = TextStyle(
    fontFamily: _f,
    fontSize: 18,
    height: 1.3,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    color: CtsTheme.textPrimary,
  );

  /// Section headings inside a page.
  static const TextStyle section = TextStyle(
    fontFamily: _f,
    fontSize: 16.5,
    height: 1.3,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.25,
    color: CtsTheme.textPrimary,
  );

  /// Titles on cards and list rows.
  static const TextStyle cardTitle = TextStyle(
    fontFamily: _f,
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.15,
    color: CtsTheme.textPrimary,
  );

  /// Default reading text.
  static const TextStyle body = TextStyle(
    fontFamily: _f,
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: CtsTheme.textPrimary,
  );

  /// Supporting text and descriptions.
  static const TextStyle bodySmall = TextStyle(
    fontFamily: _f,
    fontSize: 13.5,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: CtsTheme.textSecondary,
  );

  /// Form labels, chip text, inline links.
  static const TextStyle label = TextStyle(
    fontFamily: _f,
    fontSize: 13.5,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: CtsTheme.textPrimary,
  );

  /// Metadata, timestamps and helper text. Never smaller than 12.
  static const TextStyle caption = TextStyle(
    fontFamily: _f,
    fontSize: 12,
    height: 1.35,
    fontWeight: FontWeight.w500,
    color: CtsTheme.textTertiary,
  );

  /// Small uppercase labels above content.
  static const TextStyle overline = TextStyle(
    fontFamily: _f,
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.6,
    color: CtsTheme.textSecondary,
  );

  static const TextStyle button = TextStyle(
    fontFamily: _f,
    fontSize: 16,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.1,
  );

  static const TextStyle navLabel = TextStyle(
    fontFamily: _f,
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );

  /// Prices in rows and summaries. Tabular figures keep columns aligned.
  static const TextStyle price = TextStyle(
    fontFamily: _f,
    fontSize: 17,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: CtsTheme.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Totals and wallet balances.
  static const TextStyle priceLarge = TextStyle(
    fontFamily: _f,
    fontSize: 30,
    height: 1.1,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.8,
    color: CtsTheme.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Maps the scale onto Material's [TextTheme] so stock widgets match.
  static TextTheme textTheme(TextTheme base) => base
      .copyWith(
        displayLarge: display.copyWith(fontSize: 40),
        displayMedium: display.copyWith(fontSize: 34),
        displaySmall: display,
        headlineLarge: title1.copyWith(fontSize: 28),
        headlineMedium: title1,
        headlineSmall: title2,
        titleLarge: title3,
        titleMedium: cardTitle.copyWith(fontSize: 16),
        titleSmall: cardTitle.copyWith(fontSize: 14),
        bodyLarge: body.copyWith(fontSize: 16),
        bodyMedium: body,
        bodySmall: bodySmall,
        labelLarge: label.copyWith(fontSize: 14.5),
        labelMedium: label.copyWith(fontSize: 12.5),
        labelSmall: caption,
      )
      .apply(fontFamily: _f);
}
