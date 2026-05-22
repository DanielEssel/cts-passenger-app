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

  // ── Factories ──────────────────────────────────────────────────────────────

  factory WalletModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return WalletModel(
      userId:             doc.id,
      balance:            (data['balance']            as num?)?.toDouble() ?? 0.0,
      cashBalance:        (data['cashBalance']        as num?)?.toDouble() ?? 0.0,
      mobileMoneyBalance: (data['mobileMoneyBalance'] as num?)?.toDouble() ?? 0.0,
      cardBalance:        (data['cardBalance']        as num?)?.toDouble() ?? 0.0,
      currency:           data['currency']            as String? ?? 'GHS',
      status:             data['status']              as String? ?? 'active',
      createdAt:          _parseDate(data['createdAt']),
      lastUpdated:        _parseDate(data['lastUpdated'] ?? data['updatedAt']),
    );
  }

  factory WalletModel.fromJson(Map<String, dynamic> json) {
    return WalletModel(
      userId:             json['userId']             as String? ?? '',
      balance:            (json['balance']            as num?)?.toDouble() ?? 0.0,
      cashBalance:        (json['cashBalance']        as num?)?.toDouble() ?? 0.0,
      mobileMoneyBalance: (json['mobileMoneyBalance'] as num?)?.toDouble() ?? 0.0,
      cardBalance:        (json['cardBalance']        as num?)?.toDouble() ?? 0.0,
      currency:           json['currency']            as String? ?? 'GHS',
      status:             json['status']              as String? ?? 'active',
      createdAt:          _parseDate(json['createdAt']),
      lastUpdated:        _parseDate(json['lastUpdated'] ?? json['updatedAt']),
    );
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  Map<String, dynamic> toMap() => {
        'userId':             userId,
        'balance':            balance,
        'cashBalance':        cashBalance,
        'mobileMoneyBalance': mobileMoneyBalance,
        'cardBalance':        cardBalance,
        'currency':           currency,
        'status':             status,
        'createdAt':          Timestamp.fromDate(createdAt),
        'lastUpdated':        Timestamp.fromDate(lastUpdated),
      };

  Wallet toEntity() => Wallet(
        userId:             userId,
        balance:            balance,
        cashBalance:        cashBalance,
        mobileMoneyBalance: mobileMoneyBalance,
        cardBalance:        cardBalance,
        currency:           currency,
        createdAt:          createdAt,
        lastUpdated:        lastUpdated,
        status:             status,
      );

  // ── Helpers ────────────────────────────────────────────────────────────────

  static DateTime _parseDate(dynamic value) {
    if (value == null)      return DateTime.now();
    if (value is Timestamp) return value.toDate();
    if (value is String)    return DateTime.tryParse(value) ?? DateTime.now();
    if (value is Map) {
      // Firestore Timestamp serialized from Cloud Function response
      // as {_seconds: int, _nanoseconds: int}
      final seconds = value['_seconds'] as int?
                   ?? value['seconds']  as int?
                   ?? 0;
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    }
    return DateTime.now();
  }
}