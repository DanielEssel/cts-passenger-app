import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../auth/providers/auth_providers.dart';   // 👈 your auth provider
import '../../wallet/services/wallet_service.dart';

/// Wallet service depends on logged in user
final walletServiceProvider = Provider<WalletService?>((ref) {
  final userId = ref.watch(userIdProvider);

  // Not logged in → no wallet service
  if (userId == null) return null;

  return FirestoreWalletService(
    FirebaseFirestore.instance,
    userId,
  );
});

/// Wallet balance (safe even when logged out)
final walletBalanceProvider = FutureProvider.autoDispose<double>((ref) async {
  final walletService = ref.watch(walletServiceProvider);

  if (walletService == null) return 0.0;

  return walletService.fetchBalance();
});