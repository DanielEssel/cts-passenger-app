import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;
import '../../domain/entities/transaction.dart';

class TransactionModel {
  final String id;
  final String userId;
  final double amount;
  final TransactionType type;
  final TransactionStatus status;
  final String description;
  final PaymentMethod paymentMethod;
  final String reference;
  
  final DateTime createdAt;
  final Map<String, dynamic>? metadata;

  const TransactionModel({
    required this.id,
    required this.userId,
    required this.amount,
    required this.type,
    required this.status,
    required this.description,
    required this.paymentMethod,
    required this.reference,
    required this.createdAt,
    this.metadata,
  });

  /// Firestore → Model
  factory TransactionModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    return TransactionModel.fromJson({
      'id': doc.id,
      ...data,
    });
  }

  /// Ledger → Model (maps our immutable ledger schema to Transaction entity)
  factory TransactionModel.fromLedger(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    // Map ledger type to transaction type
    final ledgerType = data['type'] as String? ?? '';
    final txType = (ledgerType == 'TOPUP' || ledgerType == 'REFUND')
        ? 'credit'
        : 'debit';

    // Map ledger status
    final ledgerStatus = data['status'] as String? ?? 'COMPLETED';
    final txStatus = ledgerStatus == 'COMPLETED' ? 'completed'
        : ledgerStatus == 'FAILED' ? 'failed'
        : 'pending';

    // Build description from ledger data
    String description = data['referenceType'] as String? ?? 'Transaction';
    if (ledgerType == 'TOPUP')   description = 'Wallet top-up';
    if (ledgerType == 'HOLD')    description = 'Payment held for service';
    if (ledgerType == 'CAPTURE') description = 'Service payment';
    if (ledgerType == 'REFUND')  description = 'Refund to wallet';
    if (ledgerType == 'FEE')     description = 'Platform fee';

    return TransactionModel.fromJson({
      'id':          doc.id,
      'userId':      data['fromUserId'] ?? data['toUserId'] ?? '',
      'amount':      data['amount'],
      'type':        txType,
      'status':      txStatus,
      'description': description,
      'paymentMethod': 'system',
      'reference':   data['referenceId'] ?? doc.id,
      'createdAt':   data['createdAt'],
      'metadata':    {'ledgerType': ledgerType, 'referenceType': data['referenceType']},
    });
  }

  /// JSON → Model (Cloud Functions / REST / Firestore map)
  factory TransactionModel.fromJson(Map<String, dynamic> json) {
    return TransactionModel(
      id: json['id'] ?? '',
      userId: json['userId'] ?? '',
      amount: (json['amount'] ?? 0).toDouble(),
      type: _parseType(json['type']),
      status: _parseStatus(json['status']),
      paymentMethod: _parsePaymentMethod(json['paymentMethod']),
      description: json['description'] ?? '',
      reference: json['reference'] ?? '',
      createdAt: _parseDate(json['createdAt']),
      metadata: json['metadata'],
    );
  }

  /// Model → Domain Entity
  Transaction toEntity() {
    return Transaction(
      id: id,
      userId: userId,
      amount: amount,
      type: type,
      status: status,
      description: description,
      paymentMethod: paymentMethod,
      reference: reference,
      createdAt: createdAt,
      metadata: metadata,
    );
  }

  /// Domain → JSON (useful for writing back to Firestore)
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'amount': amount,
      'type': type.name,
      'status': status.name,
      'paymentMethod': paymentMethod.name,
      'description': description,
      'reference': reference,
      'createdAt': Timestamp.fromDate(createdAt),
      'metadata': metadata,
    };
  }

  // ---------------- helpers ----------------

  static TransactionType _parseType(String? value) {
    return value == 'credit'
        ? TransactionType.credit
        : TransactionType.debit;
  }

  static TransactionStatus _parseStatus(String? value) {
    switch (value) {
      case 'completed':
        return TransactionStatus.completed;
      case 'failed':
        return TransactionStatus.failed;
      case 'refunded':
        return TransactionStatus.refunded;
      default:
        return TransactionStatus.pending;
    }
  }

  static PaymentMethod _parsePaymentMethod(String? value) {
    switch (value) {
      case 'mobileMoney':
        return PaymentMethod.mobileMoney;
      case 'card':
        return PaymentMethod.card;
      case 'bankTransfer':
        return PaymentMethod.bankTransfer;
      case 'cash':
        return PaymentMethod.cash;
      default:
        return PaymentMethod.system;
    }
  }

  static DateTime _parseDate(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.parse(value);
    return DateTime.now();
  }
}