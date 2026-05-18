import 'package:cloud_firestore/cloud_firestore.dart';
import '../../domain/entities/wallet.dart';

class WalletModel extends Wallet {
  const WalletModel({
    required super.userId,
    required super.balance,
    required super.cashBalance,
    required super.mobileMoneyBalance,
    required super.cardBalance,
    required super.currency,
    required super.createdAt,
    required super.lastUpdated,
    required super.status,
  });

  /// Firestore → Model
  factory WalletModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    return WalletModel(
      userId: doc.id,
      balance: (data['balance'] ?? 0).toDouble(),
      cashBalance: (data['cashBalance'] ?? 0).toDouble(),
      mobileMoneyBalance: (data['mobileMoneyBalance'] ?? 0).toDouble(),
      cardBalance: (data['cardBalance'] ?? 0).toDouble(),
      currency: data['currency'] ?? 'GHS',
      createdAt:
          (data['createdAt'] as Timestamp?)?.toDate() ??
          DateTime.now(),
      lastUpdated:
          (data['lastUpdated'] as Timestamp?)?.toDate() ??
          DateTime.now(),
      status: data['status'] ?? 'active',
    );
  }

  /// JSON → Model
  factory WalletModel.fromJson(Map<String, dynamic> json) {
    return WalletModel(
      userId: json['userId'] ?? '',
      balance: (json['balance'] ?? 0).toDouble(),
      cashBalance: (json['cashBalance'] ?? 0).toDouble(),
      mobileMoneyBalance:
          (json['mobileMoneyBalance'] ?? 0).toDouble(),
      cardBalance: (json['cardBalance'] ?? 0).toDouble(),
      currency: json['currency'] ?? 'GHS',
      createdAt:
          DateTime.tryParse(json['createdAt'] ?? '') ??
          DateTime.now(),
      lastUpdated:
          DateTime.tryParse(json['lastUpdated'] ?? '') ??
          DateTime.now(),
      status: json['status'] ?? 'active',
    );
  }

  /// Model → Map
  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'balance': balance,
      'cashBalance': cashBalance,
      'mobileMoneyBalance': mobileMoneyBalance,
      'cardBalance': cardBalance,
      'currency': currency,
      'createdAt': Timestamp.fromDate(createdAt),
      'lastUpdated': Timestamp.fromDate(lastUpdated),
      'status': status,
    };
  }

  /// Model → Entity
  Wallet toEntity() {
    return Wallet(
      userId: userId,
      balance: balance,
      cashBalance: cashBalance,
      mobileMoneyBalance: mobileMoneyBalance,
      cardBalance: cardBalance,
      currency: currency,
      createdAt: createdAt,
      lastUpdated: lastUpdated,
      status: status,
    );
  }
}