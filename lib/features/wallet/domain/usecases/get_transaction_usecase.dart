import 'package:dartz/dartz.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/transaction.dart';
import '../../domain/failures/wallet_failures.dart';
import '../../data/repositories/wallet_repository.dart';
import '../../presentation/providers/wallet_providers.dart';

class GetTransactionsUseCase {
  final WalletRepository _repository;

  GetTransactionsUseCase(this._repository);

  Future<Either<WalletFailure, List<Transaction>>> execute({
    int limit = 50,
    String? lastTransactionId,
  }) async {
    return _repository.getTransactionHistory( // ✅ correct method name
      limit: limit,
      lastTransactionId: lastTransactionId,
    );
  }
}

final getTransactionsUseCaseProvider = Provider<GetTransactionsUseCase>((ref) {
  final repository = ref.watch(walletRepositoryProvider);
  return GetTransactionsUseCase(repository);
});