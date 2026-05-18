// lib/features/gas/providers/gas_order_providers.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/gas/repositories/gas_order_repository.dart';

// ─────────────────────────────────────────────
// Auth
// ─────────────────────────────────────────────

/// Streams the current Firebase Auth user in real time.
final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

/// Convenience provider — throws if the user is not signed in.
final currentUserProvider = Provider<User>((ref) {
  final user = ref.watch(authStateProvider).value;
  if (user == null) throw Exception('User not authenticated');
  return user;
});

// ─────────────────────────────────────────────
// Repository  (plain Provider — no StateNotifier needed)
// ─────────────────────────────────────────────

final gasOrderRepositoryProvider = Provider<GasOrderRepository>((ref) {
  return GasOrderRepository(FirebaseFirestore.instance);
});

// ─────────────────────────────────────────────
// Streams
// ─────────────────────────────────────────────

/// Real-time stream of the current user's gas orders.
final userGasOrdersStreamProvider =
    StreamProvider.autoDispose<List<GasRefillRequest>>((ref) {
  final userAsync = ref.watch(authStateProvider);
  final user = userAsync.value;
  if (user == null) return const Stream.empty();

  final repo = ref.read(gasOrderRepositoryProvider);
  return repo.watchUserOrders(user.uid);
});

/// Real-time stream of a specific order (tracking / success screen).
final gasOrderStreamProvider =
    StreamProvider.autoDispose.family<GasRefillRequest?, String>((ref, orderId) {
  final repo = ref.read(gasOrderRepositoryProvider);
  return repo.watchOrder(orderId);
});

// ─────────────────────────────────────────────
// Derived — active orders only
// ─────────────────────────────────────────────

final activeGasOrdersProvider =
    Provider.autoDispose<List<GasRefillRequest>>((ref) {
  final ordersAsync = ref.watch(userGasOrdersStreamProvider);
  return ordersAsync.value
          ?.where((o) =>
              o.status != GasOrderStatus.delivered &&
              o.status != GasOrderStatus.cancelled &&
              o.status != GasOrderStatus.failed)
          .toList() ??
      [];
});