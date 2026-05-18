// lib/features/wallet/presentation/providers/wallet_controller.dart

import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:cts_transport_app/core/providers/navigation_providers.dart';
import '../providers/wallet_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────

final walletControllerProvider = Provider<WalletController>(
  (ref) => WalletController(ref),
);

// ─────────────────────────────────────────────────────────────────────────────
// WalletController
// ─────────────────────────────────────────────────────────────────────────────

class WalletController {
  const WalletController(this._ref);

  final Ref _ref;

  // ─────────────────────────────────────────────
  // Auth helper
  // ─────────────────────────────────────────────

  /// Returns the current user or throws if not signed in.
  User get _requireUser {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('User not authenticated');
    return user;
  }

  /// Returns a valid email for Paystack.
  /// Phone-auth users don't have an email, so we generate one.
  String _resolveEmail(User user) {
    if (user.email != null && user.email!.isNotEmpty) return user.email!;
    if (user.phoneNumber != null && user.phoneNumber!.isNotEmpty) {
      return '${user.phoneNumber!.replaceAll('+', '')}@cts.app';
    }
    return '${user.uid}@cts.app';
  }

  // ─────────────────────────────────────────────
  // Refresh helper
  // ─────────────────────────────────────────────

  Future<void> _refreshWallet() async {
    await _ref.read(walletProvider.notifier).refresh();
    _ref.invalidate(transactionHistoryProvider);
    _ref.invalidate(recentTransactionsStreamProvider);
  }

  // ─────────────────────────────────────────────
  // Top up via Paystack
  // ─────────────────────────────────────────────

  Future<bool> topUp({
    required double amount,
    required String paymentMethod,
  }) async {
    final user = _requireUser;
    final email = _resolveEmail(user);

    try {
      final remote = _ref.read(walletRemoteDataSourceProvider);

      final result = await remote.initializePaystackPayment(
        amount: amount,
        paymentMethod: paymentMethod,
        email: email,
      );

      final url = result['authorization_url'] as String?;
      final reference = result['reference'] as String?;

      if (url == null || url.isEmpty) {
        throw Exception('Invalid payment URL from Paystack');
      }

      await _openPaystackCheckout(url, reference ?? '');
      await _refreshWallet();
      return true;
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Paystack init error [${e.code}]: ${e.message}');
      throw Exception(e.message ?? 'Payment initialisation failed');
    } catch (e) {
      debugPrint('Top up error: $e');
      rethrow;
    }
  }

  // ─────────────────────────────────────────────
  // Deduct wallet for a service order
  // Delegates to Cloud Function for atomic server-side transaction.
  // ─────────────────────────────────────────────

  Future<bool> deductForGasOrder({
    required double amount,
    required String description,
  }) async {
    _requireUser; // throws if not authenticated

    try {
      final remote = _ref.read(walletRemoteDataSourceProvider);

      final success = await remote.deductWalletBalance(
        amount: amount,
        description: description,
        category: 'gas_order',
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
      final remote = _ref.read(walletRemoteDataSourceProvider);
      final success = await remote.transferFunds(
        recipientPhone: recipientPhone,
        amount: amount,
        note: note,
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
  // Withdraw
  // ─────────────────────────────────────────────

  Future<bool> withdraw({
    required double amount,
    required String phoneNumber,
    required String network,
  }) async {
    _requireUser;
    try {
      final remote = _ref.read(walletRemoteDataSourceProvider);
      final success = await remote.withdrawFunds(
        amount: amount,
        phoneNumber: phoneNumber,
        network: network,
      );
      if (success) await _refreshWallet();
      return success;
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Withdrawal failed');
    } catch (e) {
      rethrow;
    }
  }

  // ─────────────────────────────────────────────
  // Utilities
  // ─────────────────────────────────────────────

  Future<String> getReceipt(String transactionId) async {
    final remote = _ref.read(walletRemoteDataSourceProvider);
    return remote.getTransactionReceipt(transactionId);
  }

  Future<String> exportHistory(DateTimeRange range) async {
    final remote = _ref.read(walletRemoteDataSourceProvider);
    return remote.exportTransactionHistory(range);
  }

  // ─────────────────────────────────────────────
  // Paystack WebView
  // ─────────────────────────────────────────────

  Future<void> _openPaystackCheckout(String url, String reference) async {
    final completer = Completer<void>();

    final webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (currentUrl) {
          if (currentUrl.contains('success') ||
              currentUrl.contains('callback')) {
            if (!completer.isCompleted) completer.complete();
          } else if (currentUrl.contains('cancel') ||
              currentUrl.contains('close')) {
            if (!completer.isCompleted) {
              completer.completeError(Exception('Payment cancelled'));
            }
          }
        },
      ))
      ..loadRequest(Uri.parse(url));

    final navigatorKey = _ref.read(navigatorKeyProvider);
    final context = navigatorKey.currentContext;
    if (context == null) throw Exception('No navigation context available');

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PaystackWebView(
          webController: webController,
          onClose: () {
            if (!completer.isCompleted) {
              completer.completeError(Exception('Payment cancelled'));
            }
            Navigator.pop(context);
          },
        ),
      ),
    );

    // Await the result — throws if cancelled
    await completer.future;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Paystack WebView screen (extracted for clarity)
// ─────────────────────────────────────────────────────────────────────────────

class _PaystackWebView extends StatelessWidget {
  final WebViewController webController;
  final VoidCallback onClose;

  const _PaystackWebView({
    required this.webController,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paystack Payment'),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: onClose,
          tooltip: 'Cancel payment',
        ),
        actions: [
          // Reload button in case page fails to load
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => webController.reload(),
            tooltip: 'Reload',
          ),
        ],
      ),
      body: Column(
        children: [
          // Security banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6),
            color: const Color(0xFF00C566).withValues(alpha: 0.1),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_rounded,
                    size: 12, color: Color(0xFF00C566)),
                SizedBox(width: 6),
                Text(
                  'Secured by Paystack · 256-bit SSL encryption',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF00C566),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: WebViewWidget(controller: webController)),
        ],
      ),
    );
  }
}