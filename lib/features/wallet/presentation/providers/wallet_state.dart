import '../../domain/entities/wallet.dart';
import '../../domain/entities/transaction.dart';

class WalletState {
  final Wallet? wallet;
  final List<Transaction> transactions;
  final bool isLoading;
  final bool isProcessing;
  final String? error;
  final String? successMessage;

  const WalletState({
    this.wallet,
    this.transactions = const [],
    this.isLoading = false,
    this.isProcessing = false,
    this.error,
    this.successMessage,
  });

  WalletState copyWith({
    Wallet? wallet,
    List<Transaction>? transactions,
    bool? isLoading,
    bool? isProcessing,
    String? error,
    String? successMessage,
  }) {
    return WalletState(
      wallet: wallet ?? this.wallet,
      transactions: transactions ?? this.transactions,
      isLoading: isLoading ?? this.isLoading,
      isProcessing: isProcessing ?? this.isProcessing,
      error: error,
      successMessage: successMessage,
    );
  }
}