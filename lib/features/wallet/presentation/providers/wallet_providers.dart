import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/wallet/data/datasources/wallet_remote_datasource.dart';
import '../../../../features/wallet/data/repositories/wallet_repository_impl.dart';
import '../../../../features/wallet/data/repositories/wallet_repository.dart';
import '../../../../features/wallet/domain/usecases/get_wallet_usecase.dart';
import '../../../../features/wallet/domain/usecases/get_transaction_usecase.dart';
import '../../../../features/wallet/domain/usecases/initialize_paystack_payment_usecase.dart';
import '../../../../features/wallet/domain/entities/wallet.dart';
import '../../../../features/wallet/domain/entities/transaction.dart';

// ── Data source ───────────────────────────────────────────────────────────────

final walletRemoteDataSourceProvider = Provider<WalletRemoteDataSource>(
  (_) => WalletRemoteDataSource(),
);

// ── Repository ────────────────────────────────────────────────────────────────

final walletRepositoryProvider = Provider<WalletRepository>((ref) {
  return WalletRepositoryImpl(ref.watch(walletRemoteDataSourceProvider));
});

// ── Use cases ─────────────────────────────────────────────────────────────────

final getWalletUseCaseProvider = Provider<GetWalletUseCase>(
  (ref) => GetWalletUseCase(ref.watch(walletRepositoryProvider)),
);

final getTransactionsUseCaseProvider = Provider<GetTransactionsUseCase>(
  (ref) => GetTransactionsUseCase(ref.watch(walletRepositoryProvider)),
);

final initializePaystackPaymentUseCaseProvider =
    Provider<InitializePaystackPaymentUseCase>(
  (ref) => InitializePaystackPaymentUseCase(ref.watch(walletRepositoryProvider)),
);

// ── Wallet state ──────────────────────────────────────────────────────────────

class WalletStateNotifier extends Notifier<AsyncValue<Wallet?>> {
  @override
  AsyncValue<Wallet?> build() {
    Future.microtask(loadWallet);
    return const AsyncValue.loading();
  }

  Future<void> loadWallet() async {
  state = const AsyncValue.loading();
  try {
    final result = await ref.read(getWalletUseCaseProvider).execute();
    state = result.fold(
      (failure) => AsyncValue.error(failure, StackTrace.current), // ← Left
      (wallet)  => AsyncValue.data(wallet),                       // ← Right
    );
  } catch (e, st) {
    state = AsyncValue.error(e, st);
  }
}

  Future<void> refresh() => loadWallet();
}

final walletProvider =
    NotifierProvider<WalletStateNotifier, AsyncValue<Wallet?>>(
  WalletStateNotifier.new,
);

// ── Transactions ──────────────────────────────────────────────────────────────

final transactionHistoryProvider = FutureProvider<List<Transaction>>((ref) async {
  final result = await ref.watch(getTransactionsUseCaseProvider).execute(limit: 50);
  return result.fold(
    (failure) => throw failure,   // ← Left
    (list)    => list,            // ← Right
  );
});

// ── Streams ───────────────────────────────────────────────────────────────────

final walletStreamProvider = StreamProvider<Wallet>((ref) {
  return ref.watch(walletRepositoryProvider).watchWallet();
});

final recentTransactionsStreamProvider = StreamProvider<List<Transaction>>((ref) {
  return ref.watch(walletRepositoryProvider).watchRecentTransactions();
});

// ── Payment controller ────────────────────────────────────────────────────────

class PaymentController {
  const PaymentController(this._ref);
  final Ref _ref;

  Future<bool> initializeTopUp({
    required double amount,
    required String paymentMethod,
    required String email,
  }) async {
    final result = await _ref
        .read(initializePaystackPaymentUseCaseProvider)
        .execute(amount: amount, paymentMethod: paymentMethod, email: email);

    return result.fold(
    (_)        => false,                              // ← Left (failure)
    (response) => response.authorizationUrl.isNotEmpty, // ← Right
  );
  }
}

final paymentControllerProvider = Provider(
  (ref) => PaymentController(ref),
);