import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';

import '../../domain/entities/wallet.dart';
import '../../domain/entities/transaction.dart';
import '../../domain/entities/paystack_init_response.dart';
import '../../domain/failures/wallet_failures.dart';
import '../../../../features/wallet/data/repositories/wallet_repository.dart';

import '../datasources/wallet_remote_datasource.dart';

class WalletRepositoryImpl implements WalletRepository {
  final WalletRemoteDataSource _remoteDataSource;

  WalletRepositoryImpl(this._remoteDataSource);

  @override
  Future<Either<WalletFailure, Wallet>> getWallet() async {
    try {
      final model = await _remoteDataSource.getWallet();

      return Right(model.toEntity());
    } catch (e) {
      return Left(
        WalletNotFoundFailure(
          "Could not retrieve wallet balance.",
        ),
      );
    }
  }

  @override
  Stream<Wallet> watchWallet() {
    return _remoteDataSource
        .watchWallet()
        .map((model) => model.toEntity());
  }
@override
Future<Either<WalletFailure, List<Transaction>>> getTransactionHistory({
  int limit = 20,
  String? lastTransactionId,
}) async {
  try {
    final transactions = await _remoteDataSource.getTransactions(limit: limit);
    return Right(transactions); // ✅ already List<Transaction>
  } catch (e) {
    return Left(NetworkFailure("Failed to load transaction history."));
  }
}

@override
Stream<List<Transaction>> watchRecentTransactions({int limit = 5}) {
  return _remoteDataSource.watchRecentTransactions(); // ✅ already Stream<List<Transaction>>
}

  @override
  Future<Either<WalletFailure, PaystackInitResponse>>
      initializeTopUp({
    required double amount,
    required String paymentMethod,
    required String email,
  }) async {
    try {
      final result =
          await _remoteDataSource
              .initializePaystackPayment(
        amount: amount,
        paymentMethod: paymentMethod,
        email: email,
      );

      return Right(
        PaystackInitResponse(
          authorizationUrl:
              result['authorization_url'] ?? '',
          reference: result['reference'] ?? '',
          accessCode: result['access_code'] ?? '',
        ),
      );
    } catch (e) {
      return Left(
        PaymentInitializationFailure(
          "Payment initialization failed.",
        ),
      );
    }
  }

  @override
  Future<bool> verifyPaystackPayment({
    required String reference,
  }) async {
    return await _remoteDataSource
        .verifyPayment(reference);
  }

  @override
  Future<bool> transferFunds({
    required String recipientPhone,
    required double amount,
    String? note,
  }) async {
    return await _remoteDataSource.transferFunds(
      recipientPhone: recipientPhone,
      amount: amount,
      note: note,
    );
  }

  @override
  Future<bool> withdrawFunds({
    required double amount,
    required String phoneNumber,
    required String network,
  }) async {
    return await _remoteDataSource.withdrawFunds(
      amount: amount,
      phoneNumber: phoneNumber,
      network: network,
    );
  }

  @override
  Future<String> getTransactionReceipt(
    String transactionId,
  ) async {
    return await _remoteDataSource
        .getTransactionReceipt(transactionId);
  }

  @override
  Future<String> exportTransactionHistory(
    DateTimeRange range,
  ) async {
    return await _remoteDataSource
        .exportTransactionHistory(range);
  }

  @override
  Future<Wallet> createWallet(
    String userId,
    String email,
  ) async {
    final model = await _remoteDataSource
        .createWallet(userId, email);

    return model.toEntity();
  }

  @override
  Future<Wallet?> getWalletByUserId(
    String userId,
  ) async {
    final model = await _remoteDataSource
        .getWalletByUserId(userId);

    return model?.toEntity();
  }

  @override
  Future<bool> hasSufficientBalance(
    double amount,
  ) async {
    return await _remoteDataSource
        .hasSufficientBalance(amount);
  }

 @override
Future<Transaction?> getTransactionByReference(String reference) async {
  return _remoteDataSource.getTransactionByReference(reference); // ✅ already Transaction?
}
}