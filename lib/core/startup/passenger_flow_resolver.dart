// lib/core/startup/passenger_flow_resolver.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../routes/app_routes.dart';
import 'route_destination.dart';

class PassengerFlowResolver {
  static Future<RouteDestination> resolve(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      // ── No user document → no account, send to login ──
      if (!doc.exists || doc.data() == null) {
        await FirebaseAuth.instance.signOut();
        return const RouteDestination(AppRoutes.login);
      }

      final data = doc.data()!;

      // ── Wrong app — driver trying to use passenger app ──
      final role = data['role'] as String? ?? 'passenger';
      if (role != 'passenger') {
        await FirebaseAuth.instance.signOut();
        return const RouteDestination(AppRoutes.login);
      }

      // ── All checks passed → main shell ──
      return const RouteDestination(AppRoutes.shell);
    } catch (e) {
      debugPrint('❌ PassengerFlowResolver error: $e');
      return const RouteDestination(AppRoutes.shell);
    }
  }
}