// lib/features/wallet/presentation/providers/wallet_controller.dart

import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../domain/entities/bridge_payment_status.dart';
// ← ghana_phone.dart removed — phone utilities live in bridge_momo_sheet.dart
import '../providers/wallet_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────

final walletControllerProvider = Provider<WalletController>(
  (ref) => WalletController(ref),
);

class WalletController {
  const WalletController(this._ref);

  final Ref _ref;

  // ─────────────────────────────────────────────
  // Auth helpers
  // ─────────────────────────────────────────────

  User get _requireUser {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('User not authenticated');
    return user;
  }

  /// Generates an email for wallet creation.
  /// Phone-auth users don't have one, so we derive it from their UID.
  String _resolveEmail(User user) {
    if (user.email != null && user.email!.isNotEmpty) return user.email!;
    if (user.phoneNumber != null && user.phoneNumber!.isNotEmpty) {
      return '${user.phoneNumber!.replaceAll('+', '')}@cts.app';
    }
    return '${user.uid}@cts.app';
  }

  Future<void> _refreshAuthToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Please log in to continue');
    await user.getIdToken(true);
  }

  // ─────────────────────────────────────────────
  // Wallet refresh
  // ─────────────────────────────────────────────

  Future<void> _refreshWallet() async {
    await _ref.read(walletProvider.notifier).refresh();
    _ref.invalidate(transactionHistoryProvider);
    _ref.invalidate(recentTransactionsStreamProvider);
  }

  // ─────────────────────────────────────────────
  // Bridge — top-up
  // ─────────────────────────────────────────────

  Future<String> initiateBridgeTopUp({
    required double amount,
    required String phone,
    required String network,
  }) async {
    await _refreshAuthToken();
    final user  = _requireUser;
    final email = _resolveEmail(user);

    try {
      final remote = _ref.read(walletRemoteDataSourceProvider);

      final existing = await remote.getWalletByUserId(user.uid);
      if (existing == null) {
        await remote.createWallet(user.uid, email);
      }

      return await remote.initiateBridgeTopUp(
        amount:  amount,
        phone:   phone,
        network: network,
      );
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Payment initiation failed');
    }
  }

  Future<BridgePaymentStatus> checkBridgeTopUpStatus(
    String transactionId,
  ) async {
    try {
      final remote = _ref.read(walletRemoteDataSourceProvider);
      return await remote.checkBridgeTopUpStatus(transactionId);
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Status check failed');
    }
  }

  Future<void> onTopUpSuccess() async {
    await _refreshWallet();
  }

  
  // ─────────────────────────────────────────────
  // Service order deduction (escrow)
  // ─────────────────────────────────────────────

  Future<bool> deductForGasOrder({
    required double amount,
    required String description,
  }) async {
    await _refreshAuthToken();
    try {
      final remote  = _ref.read(walletRemoteDataSourceProvider);
      final success = await remote.deductWalletBalance(
        amount:      amount,
        description: description,
        category:    'gas_order',
      );
      if (!success) throw Exception('Payment failed. Please try again.');
      await _refreshWallet();
      return true;
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Payment failed');
    } catch (e) {
      rethrow;
    }
  }

  // ─────────────────────────────────────────────
  // Transfer
  // ─────────────────────────────────────────────

  Future<bool> transfer({
    required String recipientPhone,
    required double amount,
    String? note,
  }) async {
    _requireUser;
    try {
      final remote  = _ref.read(walletRemoteDataSourceProvider);
      final success = await remote.transferFunds(
        recipientPhone: recipientPhone,
        amount:         amount,
        note:           note,
      );
      if (success) await _refreshWallet();
      return success;
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Transfer failed');
    } catch (e) {
      rethrow;
    }
  }


  // ─────────────────────────────────────────────
  // Utilities
  // ─────────────────────────────────────────────

  Future<String> getReceipt(String transactionId) async {
    return _ref.read(walletRemoteDataSourceProvider)
        .getTransactionReceipt(transactionId);
  }

  Future<String> exportHistory(DateTimeRange range) async {
    return _ref.read(walletRemoteDataSourceProvider)
        .exportTransactionHistory(range);
  }
}