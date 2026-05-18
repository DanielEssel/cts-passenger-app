import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import '../../domain/entities/wallet.dart';
import '../../domain/entities/transaction.dart';
import '../../domain/failures/wallet_failures.dart';
import '../../domain/entities/paystack_init_response.dart';

abstract class WalletRepository {

  Future<Either<WalletFailure, Wallet>> getWallet();

  Stream<Wallet> watchWallet();

  Future<Either<WalletFailure, List<Transaction>>>
      getTransactionHistory({
    int limit = 20,
    String? lastTransactionId,
  });

  Stream<List<Transaction>> watchRecentTransactions({
    int limit = 5,
  });

  Future<Either<WalletFailure, PaystackInitResponse>>
      initializeTopUp({
    required double amount,
    required String paymentMethod,
    required String email,
  });

  Future<bool> verifyPaystackPayment({
    required String reference,
  });

  Future<bool> transferFunds({
    required String recipientPhone,
    required double amount,
    String? note,
  });

  Future<bool> withdrawFunds({
    required double amount,
    required String phoneNumber,
    required String network,
  });

  Future<String> getTransactionReceipt(
    String transactionId,
  );

  Future<String> exportTransactionHistory(
    DateTimeRange range,
  );

  Future<Wallet> createWallet(
    String userId,
    String email,
  );

  Future<Wallet?> getWalletByUserId(
    String userId,
  );

  Future<bool> hasSufficientBalance(
    double amount,
  );

  Future<Transaction?> getTransactionByReference(
    String reference,
  );
}