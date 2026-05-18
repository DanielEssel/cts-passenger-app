// lib/core/services/local/onboarding_local_service.dart

import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether the user has seen the onboarding walkthrough.
/// Uses SharedPreferences so it survives app restarts but resets
/// on fresh installs — exactly the right behaviour for onboarding.
class OnboardingLocalService {
  static const _key = 'onboarding_completed';

  /// Returns true if the user has already seen onboarding.
  static Future<bool> isCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  /// Call this at the end of the last onboarding page.
  static Future<void> markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }

  /// Use during development / account reset flows only.
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}