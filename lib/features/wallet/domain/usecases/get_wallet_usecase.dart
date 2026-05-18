import 'package:dartz/dartz.dart';

import '../entities/wallet.dart';
import '../../domain/failures/wallet_failures.dart';
import '../../data/repositories/wallet_repository.dart';

class GetWalletUseCase {
  final WalletRepository _repository;

  GetWalletUseCase(this._repository);

  Future<Either<WalletFailure, Wallet>> execute() async {
  try {
    return await _repository.getWallet(); // ✅ already Either — return directly
  } catch (e) {
    return Left(WalletNotFoundFailure("Failed to load wallet"));
  }
}
}