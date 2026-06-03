// lib/core/startup/startup_resolver.dart


import 'package:firebase_auth/firebase_auth.dart';

import '../routes/app_routes.dart';
import '../services/local/onboarding_local_service.dart';
import 'passenger_flow_resolver.dart';
import 'route_destination.dart';

class StartupResolver {
  const StartupResolver._(); // prevent instantiation — pure static utility

  static Future<RouteDestination> resolve() async {
    // ── 1. First app open — show onboarding walkthrough ─────────────
    final seenOnboarding = await OnboardingLocalService.isCompleted();
    if (!seenOnboarding) {
      return const RouteDestination(AppRoutes.onboarding);
    }

    // ── 2. Not authenticated — go to login ──────────────────────────
    // Wait for Firebase Auth to restore persisted session
final user = await FirebaseAuth.instance
    .authStateChanges()
    .first
    .timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
if (user == null) {
  return const RouteDestination(AppRoutes.login);
}

    // ── 3. Authenticated — delegate to passenger flow resolver ───────
    // PassengerFlowResolver checks Firestore for profile completion,
    // KYC status, etc. and returns the correct next screen.
    return PassengerFlowResolver.resolve(user.uid);
  }
}