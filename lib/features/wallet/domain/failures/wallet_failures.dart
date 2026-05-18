abstract class WalletFailure {
  final String message;
  const WalletFailure(this.message);
}

class WalletNotFoundFailure extends WalletFailure {
  const WalletNotFoundFailure(super.message);
}

class NetworkFailure extends WalletFailure {
  const NetworkFailure(super.message);
}

class PaymentInitializationFailure extends WalletFailure {
  const PaymentInitializationFailure(super.message);
}