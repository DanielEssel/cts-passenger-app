import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../presentation/providers/wallet_providers.dart';
import '../../data/repositories/wallet_repository.dart';
import 'package:dartz/dartz.dart';
import '../../domain/entities/paystack_init_response.dart';
import '../../domain/failures/wallet_failures.dart';


class InitializePaystackPaymentUseCase {
  final WalletRepository _repository;

  InitializePaystackPaymentUseCase(this._repository);

  Future<Either<WalletFailure, PaystackInitResponse>> execute({
    required double amount,
    required String paymentMethod,
    required String email,
  }) async {
    return _repository.initializeTopUp(  // ✅ matches repository
      amount: amount,
      paymentMethod: paymentMethod,
      email: email,
    );
  }
}

final initializePaystackPaymentUseCaseProvider = Provider<InitializePaystackPaymentUseCase>((ref) {
  final repository = ref.watch(walletRepositoryProvider);
  return InitializePaystackPaymentUseCase(repository);
});