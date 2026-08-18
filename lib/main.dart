// UPDATE: main.dart
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/cupertino.dart';

import 'package:cts_transport_app/features/profile/presentation/privacy_security_screen.dart';
import 'package:flutter/material.dart';
import 'features/wallet/presentation/screens/wallet_standalone_screen.dart';
import 'core/services/pricing_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'; // Add this
import 'core/constants/app_colors.dart';
import 'core/providers/navigation_providers.dart';
import 'core/routes/app_routes.dart';
import 'package:cts_transport_app/features/home/services/notification_service.dart';

import 'features/delivery/presentation/delivery_tracking_screen.dart';
import 'features/gas/presentation/screens/gas_order_tracking_screen.dart';

// AUTH FLOW
import 'features/splash/splash_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/auth/presentation/welcome_screen.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/auth/presentation/signup_screen.dart';
import 'features/auth/presentation/otp_verification_screen.dart';

// MAIN SHELL
import 'features/root/passenger_root_shell.dart';

// NON-TAB SCREENS
import 'features/ride/presentation/book_ride_screen.dart';
import 'features/delivery/presentation/delivery_screen.dart';
import 'features/delivery/presentation/delivery_vehicle_screen.dart'; // Add this
// Add this
import 'features/gas/presentation/screens/gas_order_screen.dart'; // Add this
import 'features/notification/presentation/notifications_screen.dart';
import 'features/ride_tracking/ride_tracking_screen.dart';

// PROFILE SUB-SCREENS
import 'features/profile/presentation/edit_profile_screen.dart';
import 'features/profile/presentation/saved_places_screen.dart';
import 'features/profile/presentation/payment_methods_screen.dart';
import 'features/profile/presentation/promotions_screen.dart';
import 'features/profile/presentation/help_support_screen.dart';
import 'features/profile/presentation/about_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Pre-load pricing settings
  // (called again after Firebase init)

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await PricingService.instance.fetch();

  await FirebaseAppCheck.instance.activate(
    providerAndroid:
        kDebugMode ? AndroidDebugProvider() : AndroidPlayIntegrityProvider(),
    providerApple:
        kDebugMode ? AppleDebugProvider() : AppleDeviceCheckProvider(),
  );

  await NotificationService.instance.initialize(appNavigatorKey); // ← ADD

  runApp(ProviderScope(child: RiderApp(navigatorKey: appNavigatorKey)));
}

class RiderApp extends StatelessWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  const RiderApp({super.key, required this.navigatorKey});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'CTS Passenger',
      debugShowCheckedModeBanner: false,
      theme: _buildLightTheme(),
      themeMode: ThemeMode.light,
      initialRoute: AppRoutes.splash,
      routes: _buildRoutes(),
      onGenerateRoute: _onGenerateRoute,
      onUnknownRoute: _onUnknownRoute,
    );
  }

  ThemeData _buildLightTheme() {
    // ... keep your existing theme setup exactly as is ...
    const String primaryFont = 'Poppins';
    const String secondaryFont = 'Inter';

    return ThemeData(
      fontFamily: secondaryFont,
      primaryColor: AppColors.primaryColor,
      scaffoldBackgroundColor: AppColors.background,
      useMaterial3: true,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primaryColor,
        primary: AppColors.primaryColor,
        secondary: AppColors.primaryColor,
        brightness: Brightness.light,
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimaryColor,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
            fontFamily: primaryFont, fontSize: 32, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(
            fontFamily: primaryFont, fontSize: 28, fontWeight: FontWeight.w600),
        headlineSmall: TextStyle(
            fontFamily: primaryFont, fontSize: 24, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(fontFamily: secondaryFont, fontSize: 16),
        bodyMedium: TextStyle(fontFamily: secondaryFont, fontSize: 14),
        bodySmall: TextStyle(fontFamily: secondaryFont, fontSize: 12),
        labelLarge: TextStyle(
            fontFamily: secondaryFont,
            fontSize: 14,
            fontWeight: FontWeight.w600),
        labelMedium: TextStyle(
            fontFamily: secondaryFont,
            fontSize: 12,
            fontWeight: FontWeight.w500),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: AppColors.primaryColor,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(
            fontFamily: secondaryFont,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primaryColor,
          textStyle: const TextStyle(
            fontFamily: secondaryFont,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primaryColor,
          side: const BorderSide(color: AppColors.primaryColor),
          textStyle: const TextStyle(
            fontFamily: secondaryFont,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primaryColor, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.errorColor),
        ),
        labelStyle: const TextStyle(
          fontFamily: secondaryFont,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        hintStyle: TextStyle(
          fontFamily: secondaryFont,
          fontSize: 14,
          color: Colors.grey.shade400,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        color: Colors.white,
      ),
      chipTheme: ChipThemeData(
        labelStyle: const TextStyle(
          fontFamily: secondaryFont,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        selectedLabelStyle: TextStyle(
          fontFamily: secondaryFont,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
        unselectedLabelStyle: TextStyle(
          fontFamily: secondaryFont,
          fontSize: 10,
          fontWeight: FontWeight.w400,
        ),
      ),
      tabBarTheme: const TabBarThemeData(
        labelStyle: TextStyle(
          fontFamily: secondaryFont,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: TextStyle(
          fontFamily: secondaryFont,
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        titleTextStyle: const TextStyle(
          fontFamily: primaryFont,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimaryColor,
        ),
        contentTextStyle: const TextStyle(
          fontFamily: secondaryFont,
          fontSize: 14,
          color: AppColors.textSecondaryColor,
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }

  Map<String, WidgetBuilder> _buildRoutes() {
    return {
      // Auth Flow
      AppRoutes.splash: (_) => const SplashScreen(),
      AppRoutes.onboarding: (_) => const OnboardingScreen(),
      AppRoutes.login: (_) => const LoginScreen(),
      AppRoutes.signup: (_) => const SignupScreen(),
      AppRoutes.otpVerification: (_) => const OtpVerificationScreen(),

      // Main Shell
      AppRoutes.shell: (_) => const PassengerRootShell(),

      // Profile sub-screens
      AppRoutes.notifications: (_) => const NotificationsScreen(),
      AppRoutes.editProfile: (_) => const EditProfileScreen(),
      AppRoutes.savedPlaces: (_) => const SavedPlacesScreen(),
      AppRoutes.paymentMethods: (_) => const PaymentMethodsScreen(),
      AppRoutes.promotions: (_) => const PromotionsScreen(),
      AppRoutes.privacySecurity: (_) => const PrivacySecurityScreen(),
      AppRoutes.helpSupport: (_) => const HelpSupportScreen(),
      AppRoutes.about: (_) => const AboutScreen(),

      // Ride & Delivery Screens - ADD THESE
      AppRoutes.bookRide: (_) => const BookRideScreen(),
      AppRoutes.delivery: (_) => const DeliveryScreen(),
      AppRoutes.gasOrder: (_) => const GasOrderScreen(), // ADD THIS LINE

      // Welcome Screen
      AppRoutes.welcome: (_) => const WelcomeScreen(),
    };
  }

  Route<dynamic>? _onGenerateRoute(RouteSettings settings) {
  debugPrint('🎯 Generating route: ${settings.name}');

  final uri = Uri.parse(settings.name ?? '');
  final path = uri.path;

  switch (path) {
    case AppRoutes.bookRide:
      return MaterialPageRoute(
        builder: (context) => const BookRideScreen(),
        settings: settings,
      );

    case AppRoutes.delivery:
      return MaterialPageRoute(
        builder: (context) => const DeliveryScreen(),
        settings: settings,
      );

    case AppRoutes.deliveryVehicle:
      final args = settings.arguments as Map<String, dynamic>? ?? {};
      return MaterialPageRoute(
        builder: (context) => DeliveryVehicleScreen(
          pickup: args['pickup'] ?? '',
          pickupGeoPoint:
              args['pickupGeoPoint'] ?? const GeoPoint(5.6037, -0.1870),
          dropoff: args['dropoff'] ?? '',
          dropoffGeoPoint:
              args['dropoffGeoPoint'] ?? const GeoPoint(5.6037, -0.1870),
          weightTier: args['weightTier'] ?? '',
          weightRange: args['weightRange'] ?? '',
          eligibleVehicles: args['eligibleVehicles'] ?? [],
          parcelType: args['parcelType'] ?? '',
          isFragile: args['isFragile'] ?? false,
          requiresHelpers: args['requiresHelpers'] ?? false,
          hasPhoto: args['hasPhoto'] ?? false,
          receiverPhone: args['receiverPhone'] ?? '',
          receiverName: args['receiverName'] ?? '',
          notes: args['notes'] ?? '',
        ),
        settings: settings,
      );

    case AppRoutes.rideTracking:
      final args = settings.arguments;
      final tripId = args is String
          ? args
          : args is Map
              ? (args['tripId'] ?? args['rideId'] ?? '') as String
              : uri.queryParameters['tripId'] ?? '';
      return MaterialPageRoute(
        builder: (context) => RideTrackingScreen(tripId: tripId),
        settings: settings,
      );

    case AppRoutes.gasOrder:
      debugPrint('✅ Creating GasOrderScreen');
      return MaterialPageRoute(
        builder: (context) => const GasOrderScreen(),
        settings: settings,
      );

    case AppRoutes.deliveryTracking:
      final a = settings.arguments;
      final deliveryId = a is String
          ? a
          : a is Map
              ? (a['deliveryId'] ?? '') as String
              : uri.queryParameters['deliveryId'] ?? '';
      return MaterialPageRoute(
        builder: (_) => DeliveryTrackingScreen(deliveryId: deliveryId),
        settings: settings,
      );

    case AppRoutes.gasTracking:
      final a = settings.arguments;
      final orderId = a is String
          ? a
          : a is Map
              ? (a['orderId'] ?? '') as String
              : uri.queryParameters['orderId'] ?? '';
      return MaterialPageRoute(
        builder: (_) => GasOrderTrackingScreen(orderId: orderId),
        settings: settings,
      );

    case '/wallet':
      return MaterialPageRoute(
        builder: (context) => const WalletStandaloneScreen(),
        settings: settings,
      );

    default:
      debugPrint('⚠️ Unknown route in onGenerateRoute: ${settings.name}');
      return null;
  }
}

  Route<dynamic> _onUnknownRoute(RouteSettings settings) {
    debugPrint('⚠️ Unknown route: ${settings.name}');
    return MaterialPageRoute(
      builder: (context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 64,
                color: AppColors.errorColor,
              ),
              const SizedBox(height: 16),
              const Text(
                'Route not found',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${settings.name}',
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondaryColor,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  Navigator.pushNamedAndRemoveUntil(
                    context,
                    AppRoutes.shell,
                    (route) => false,
                  );
                },
                child: const Text('Go to Home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
