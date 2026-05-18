// lib/core/startup/passenger_flow_resolver.dart
//
// Single source of truth for deciding what screen a logged-in
// passenger should land on. Add new steps here as the product grows
// (KYC, profile photo, phone verification, etc.) — nowhere else.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../routes/app_routes.dart';
import 'route_destination.dart';

class PassengerFlowResolver {
  /// Reads the passenger's Firestore document and returns the correct
  /// [RouteDestination]. Steps are checked in order — the first
  /// incomplete step wins.
  static Future<RouteDestination> resolve(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('passengers')
          .doc(uid)
          .get();

      // ── No document → create a stub and go to profile completion ──
      if (!doc.exists || doc.data() == null) {
        await _createPassengerStub(uid);
        return const RouteDestination(AppRoutes.shell);
        // ↑ New passengers land on shell; onboarding within the app
        //   can prompt for profile completion on first use.
        //   Change to AppRoutes.completeProfile if you add that screen.
      }

      final data = doc.data()!;

      // ── Step flags — add new ones here as needed ─────────────────
      final bool profileComplete =
          (data['profileComplete'] as bool?) ?? false;

      // Future steps (uncomment when screens exist):
      // final bool phoneVerified  = (data['phoneVerified']  as bool?) ?? false;
      // final bool kycComplete    = (data['kycComplete']    as bool?) ?? false;

      // ── STEP 1: Profile not completed ─────────────────────────────
      // Uncomment when you build a CompleteProfileScreen:
      // if (!profileComplete) {
      //   return const RouteDestination(AppRoutes.completeProfile);
      // }

      // ── All checks passed → main shell ────────────────────────────
      return const RouteDestination(AppRoutes.shell);
    } catch (e) {
      debugPrint('❌ PassengerFlowResolver error: $e');
      // Safe fallback — never strand the user
      return const RouteDestination(AppRoutes.shell);
    }
  }

  /// Creates a minimal passenger document on first sign-in.
  /// Idempotent — safe to call multiple times.
  static Future<void> _createPassengerStub(String uid) async {
    final phone = FirebaseAuth.instance.currentUser?.phoneNumber;
    await FirebaseFirestore.instance
        .collection('passengers')
        .doc(uid)
        .set({
      'uid':             uid,
      'phone':           phone,
      'profileComplete': false,
      'createdAt':       FieldValue.serverTimestamp(),
      'updatedAt':       FieldValue.serverTimestamp(),
    }, SetOptions(merge: true)); // merge: true keeps any existing fields
  }
}