import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../features/auth/providers/auth_providers.dart'; // adjust path to your auth provider

abstract class WalletService {
  Future<double> fetchBalance();
}

class FirestoreWalletService implements WalletService {
  final FirebaseFirestore _db;
  final String _userId;

  FirestoreWalletService(this._db, this._userId);

  @override
  Future<double> fetchBalance() async {
    final doc = await _db.collection('wallets').doc(_userId).get();
    if (!doc.exists) return 0.0;
    return (doc.data()?['balance'] as num?)?.toDouble() ?? 0.0;
  }
}
final walletServiceProvider = Provider<WalletService?>((ref) {
  final userId = ref.watch(userIdProvider);

  if (userId == null) return null; // 🔥 user not logged in yet

  return FirestoreWalletService(
    FirebaseFirestore.instance,
    userId,
  );
});
