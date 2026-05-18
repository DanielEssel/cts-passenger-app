// lib/core/startup/startup_resolver.dart
//
// The single entry point for startup routing decisions.
// The splash screen calls resolve() and navigates to whatever
// RouteDestination is returned — no routing logic lives in the
// splash screen itself.
//
// Adding a new startup step:
//   1. Add the check to PassengerFlowResolver.resolve()
//   2. Add the route constant to AppRoutes
//   3. Register the screen in main.dart routes / onGenerateRoute
//   Nothing else needs to change.

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
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const RouteDestination(AppRoutes.login);
    }

    // ── 3. Authenticated — delegate to passenger flow resolver ───────
    // PassengerFlowResolver checks Firestore for profile completion,
    // KYC status, etc. and returns the correct next screen.
    return PassengerFlowResolver.resolve(user.uid);
  }
}