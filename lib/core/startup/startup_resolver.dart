// lib/core/startup/startup_resolver.dart

import 'package:firebase_auth/firebase_auth.dart';

import '../routes/app_routes.dart';
import '../services/local/onboarding_local_service.dart';
import 'passenger_flow_resolver.dart';
import 'route_destination.dart';

class StartupResolver {
  const StartupResolver._();

  static Future<RouteDestination> resolve() async {
    // ─────────────────────────────────────────────────────────────────────
    // 1. First app open → onboarding
    // ─────────────────────────────────────────────────────────────────────

    final seenOnboarding =
        await OnboardingLocalService.isCompleted();

    if (!seenOnboarding) {
      return const RouteDestination(
        AppRoutes.onboarding,
      );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Restore Firebase Auth session
    // ─────────────────────────────────────────────────────────────────────

    User? user;

    try {
      user = await FirebaseAuth.instance
          .authStateChanges()
          .first
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => null,
          );
    } catch (_) {
      user = FirebaseAuth.instance.currentUser;
    }

    // No Firebase authentication.
    if (user == null) {
      return const RouteDestination(
        AppRoutes.login,
      );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Firebase user exists.
    //
    // IMPORTANT:
    // Firebase user != CTSGo registered user.
    //
    // PassengerFlowResolver now checks users/{uid}.
    // ─────────────────────────────────────────────────────────────────────

    return PassengerFlowResolver.resolve(
      user.uid,
    );
  }
}