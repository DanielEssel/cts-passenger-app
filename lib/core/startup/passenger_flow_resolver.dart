// lib/core/startup/passenger_flow_resolver.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../routes/app_routes.dart';
import 'route_destination.dart';

class PassengerFlowResolver {
  const PassengerFlowResolver._();

  static Future<RouteDestination> resolve(
    String uid, {
    String? phoneNumber,
  }) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      // ─────────────────────────────────────────────────────────────────────
      // NO CTSGo USER DOCUMENT
      //
      // Firebase may know this phone number, but that does NOT mean the
      // person has registered for CTSGo.
      //
      // Send them to Signup, not the passenger shell.
      // ─────────────────────────────────────────────────────────────────────
      if (!doc.exists || doc.data() == null) {
        debugPrint(
          '⚠️ Firebase user $uid has no CTSGo profile. '
          'Redirecting to signup.',
        );

        await FirebaseAuth.instance.signOut();

        return RouteDestination(
          AppRoutes.signup,
          arguments: {
            'phone': phoneNumber ?? '',
            'fromUnregisteredLogin': true,
          },
        );
      }

      final data = doc.data()!;

      // ─────────────────────────────────────────────────────────────────────
      // WRONG ROLE
      //
      // A driver/company/admin account must not enter the passenger app.
      // ─────────────────────────────────────────────────────────────────────

      final role = data['role'] as String? ?? '';

      if (role != 'passenger') {
        debugPrint(
          '⚠️ User $uid has role "$role", not passenger.',
        );

        await FirebaseAuth.instance.signOut();

        return const RouteDestination(
          AppRoutes.login,
        );
      }

      // ─────────────────────────────────────────────────────────────────────
      // EXISTING PASSENGER — FIRST LOGIN
      // ─────────────────────────────────────────────────────────────────────

      final hasSeenWelcome =
          data['hasSeenWelcome'] as bool? ?? false;

      if (!hasSeenWelcome) {
        return const RouteDestination(
          AppRoutes.welcome,
        );
      }

      // ─────────────────────────────────────────────────────────────────────
      // EXISTING PASSENGER — NORMAL LOGIN
      // ─────────────────────────────────────────────────────────────────────

      debugPrint(
        '✅ Existing passenger profile found for $uid.',
      );

      return const RouteDestination(
        AppRoutes.shell,
      );
    } catch (e, stackTrace) {
      // NEVER allow a user into the passenger app when we cannot verify
      // their Firestore profile.
      debugPrint(
        '❌ PassengerFlowResolver error: $e',
      );
      debugPrintStack(stackTrace: stackTrace);

      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}

      return const RouteDestination(
        AppRoutes.login,
      );
    }
  }
}