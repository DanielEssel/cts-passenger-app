class Wallet {
  final String userId;
  final double balance;
  final double cashBalance;
  final double mobileMoneyBalance;
  final double cardBalance;
  final String currency;
  final DateTime createdAt;
  final DateTime lastUpdated;
  final String status;

  const Wallet({
    required this.userId,
    required this.balance,
    required this.cashBalance,
    required this.mobileMoneyBalance,
    required this.cardBalance,
    required this.currency,
    required this.createdAt,
    required this.lastUpdated,
    required this.status,
  });

  double get totalBalance => balance;

  Wallet copyWith({
    String? userId,
    double? balance,
    double? cashBalance,
    double? mobileMoneyBalance,
    double? cardBalance,
    String? currency,
    DateTime? createdAt,
    DateTime? lastUpdated,
    String? status,
  }) {
    return Wallet(
      userId: userId ?? this.userId,
      balance: balance ?? this.balance,
      cashBalance: cashBalance ?? this.cashBalance,
      mobileMoneyBalance: mobileMoneyBalance ?? this.mobileMoneyBalance,
      cardBalance: cardBalance ?? this.cardBalance,
      currency: currency ?? this.currency,
      createdAt: createdAt ?? this.createdAt,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      status: status ?? this.status,
    );
  }
}