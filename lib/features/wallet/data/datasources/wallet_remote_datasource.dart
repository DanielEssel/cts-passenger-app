// lib/features/wallet/data/datasources/wallet_remote_datasource.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/wallet_model.dart';
import '../../domain/entities/transaction.dart';
import '../../data/models/transaction_model.dart';

class WalletRemoteDataSource {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final FirebaseFunctions _functions;

  WalletRemoteDataSource({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    FirebaseFunctions? functions,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  // ─────────────────────────────────────────────
  // Auth helper
  // ─────────────────────────────────────────────

  /// Returns the current user's UID or null if not signed in.
  String? get _uid => _auth.currentUser?.uid;

  /// Throws if user is not authenticated.
  String get _requireUid {
    final uid = _uid;
    if (uid == null || uid.isEmpty) {
      throw Exception('User not authenticated');
    }
    return uid;
  }

  // ─────────────────────────────────────────────
  // Wallet reads
  // ─────────────────────────────────────────────

  
  /// One-time fetch — reads directly from Firestore.
Future<WalletModel> getWallet() async {
  try {
    final uid = _requireUid;
    final doc = await _firestore.collection('wallets').doc(uid).get();
    if (!doc.exists || doc.data() == null) {
      // Auto-create wallet if missing
      return WalletModel.fromJson({
        'balance':   0.0,
        'currency':  'GHS',
        'userId':    uid,
        'status':    'active',
        'createdAt': DateTime.now().toIso8601String(),
        'lastUpdated': DateTime.now().toIso8601String(),
      });
    }
    return WalletModel.fromFirestore(doc);
  } catch (e) {
    throw _handleException(e);
  }
}

  /// One-time direct Firestore read by user ID.
  Future<WalletModel?> getWalletByUserId(String userId) async {
    try {
      final doc =
          await _firestore.collection('wallets').doc(userId).get();
      if (!doc.exists || doc.data() == null) return null;
      return WalletModel.fromFirestore(doc);
    } catch (e) {
      throw _handleException(e);
    }
  }

  /// Real-time wallet stream — returns zero balance if doc doesn't exist yet.
  Stream<WalletModel> watchWallet() {
    final uid = _uid;
    if (uid == null || uid.isEmpty) {
      return Stream.error(Exception('User not authenticated'));
    }
    return _firestore
        .collection('wallets')
        .doc(uid)
        .snapshots()
        .map((doc) {
          if (!doc.exists || doc.data() == null) {
            return WalletModel.fromJson({
              'balance': 0.0,
              'currency': 'GHS',
              'userId': uid,
            });
          }
          return WalletModel.fromFirestore(doc);
        });
  }

  /// Checks if the current user has enough balance for a given amount.
  Future<bool> hasSufficientBalance(double amount) async {
    try {
      final doc = await _firestore
          .collection('wallets')
          .doc(_requireUid)
          .get();
      if (!doc.exists) return false;
      final balance =
          (doc.data()?['balance'] as num?)?.toDouble() ?? 0.0;
      return balance >= amount;
    } catch (e) {
      throw _handleException(e);
    }
  }

  // ─────────────────────────────────────────────
  // Wallet mutations
  // ─────────────────────────────────────────────

  /// Creates a wallet for a new user via Cloud Function.
  Future<WalletModel> createWallet(String userId, String email) async {
    try {
      final result =
          await _functions.httpsCallable('createWallet').call({
        'userId': userId,
        'email': email,
      });
      return WalletModel.fromJson(result.data as Map<String, dynamic>);
    } catch (e) {
      throw _handleException(e);
    }
  }

  /// Deducts wallet balance for a gas/service order via Cloud Function.
  /// The function handles the atomic Firestore transaction server-side.
  Future<bool> deductWalletBalance({
    required double amount,
    required String description,
    required String category,
  }) async {
    try {
      final result =
          await _functions.httpsCallable('deductWalletBalance').call({
        'amount': amount,
        'description': description,
        'category': category,
      });
      return result.data['success'] as bool? ?? false;
    } catch (e) {
      throw _handleException(e);
    }
  }

  Future<bool> transferFunds({
    required String recipientPhone,
    required double amount,
    String? note,
  }) async {
    try {
      final result =
          await _functions.httpsCallable('transferFunds').call({
        'recipientPhone': recipientPhone,
        'amount': amount,
        'note': note,
      });
      return result.data['success'] as bool;
    } catch (e) {
      throw _handleException(e);
    }
  }

  Future<bool> withdrawFunds({
    required double amount,
    required String phoneNumber,
    required String network,
  }) async {
    try {
      final result =
          await _functions.httpsCallable('withdrawFunds').call({
        'amount': amount,
        'phoneNumber': phoneNumber,
        'network': network,
      });
      return result.data['success'] as bool;
    } catch (e) {
      throw _handleException(e);
    }
  }

  // ─────────────────────────────────────────────
  // Transactions
  // ─────────────────────────────────────────────

  Future<List<Transaction>> getTransactions({int limit = 50}) async {
    try {
      final result =
          await _functions.httpsCallable('getTransactionHistory').call({
        'limit': limit,
      });
      return (result.data['transactions'] as List)
          .map((json) =>
              TransactionModel.fromJson(json as Map<String, dynamic>)
                  .toEntity())
          .toList();
    } catch (e) {
      throw _handleException(e);
    }
  }

  /// Real-time stream of recent transactions.
  Stream<List<Transaction>> watchRecentTransactions() {
    final uid = _uid;
    if (uid == null || uid.isEmpty) {
      return Stream.error(Exception('User not authenticated'));
    }
    return _firestore
        .collection('transactions')
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(20)
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) =>
                TransactionModel.fromFirestore(doc).toEntity())
            .toList());
  }

  Future<Transaction?> getTransactionByReference(
      String reference) async {
    try {
      final snap = await _firestore
          .collection('transactions')
          .where('reference', isEqualTo: reference)
          .limit(1)
          .get();
      if (snap.docs.isEmpty) return null;
      return TransactionModel.fromFirestore(snap.docs.first).toEntity();
    } catch (e) {
      throw _handleException(e);
    }
  }

  Future<String> getTransactionReceipt(String transactionId) async {
    try {
      final result =
          await _functions.httpsCallable('getTransactionReceipt').call({
        'transactionId': transactionId,
      });
      return result.data['receipt'] as String;
    } catch (e) {
      throw _handleException(e);
    }
  }

  Future<String> exportTransactionHistory(DateTimeRange range) async {
    try {
      final result = await _functions
          .httpsCallable('exportTransactionHistory')
          .call({
        'startDate': range.start.toIso8601String(),
        'endDate': range.end.toIso8601String(),
      });
      return result.data['exportUrl'] as String;
    } catch (e) {
      throw _handleException(e);
    }
  }

  // ─────────────────────────────────────────────
  // Payments
  // ─────────────────────────────────────────────

  Future<Map<String, dynamic>> initializePaystackPayment({
    required double amount,
    required String paymentMethod,
    required String email,
  }) async {
    try {
      final result = await _functions
          .httpsCallable('initializePaystackPayment')
          .call({
        'amount': amount,
        'paymentMethod': paymentMethod,
        'email': email,
        'userId': _requireUid,
      });
      return result.data as Map<String, dynamic>;
    } catch (e) {
      throw _handleException(e);
    }
  }

  Future<bool> verifyPayment(String reference) async {
    try {
      final result = await _functions
          .httpsCallable('verifyPaystackPayment')
          .call({'reference': reference});
      return result.data['success'] as bool? ?? false;
    } catch (e) {
      throw _handleException(e);
    }
  }

  // ─────────────────────────────────────────────
  // Error handler
  // ─────────────────────────────────────────────

  Exception _handleException(dynamic e) {
    if (e is FirebaseFunctionsException) {
      return Exception(e.message ?? 'Function call failed');
    }
    if (e is Exception) return e;
    return Exception('Unexpected error: $e');
  }
}