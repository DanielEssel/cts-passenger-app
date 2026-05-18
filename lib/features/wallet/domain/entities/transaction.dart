// lib/features/wallet/domain/entities/transaction.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

// ── Enums ─────────────────────────────────────────────────────────────────────

enum TransactionType { credit, debit }

enum TransactionStatus { pending, completed, failed, refunded }

enum PaymentMethod { mobileMoney, card, bankTransfer, cash, system }

// ── Entity ────────────────────────────────────────────────────────────────────

class Transaction extends Equatable {
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

  const Transaction({
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

  // ── Convenience getters ───────────────────────────────────────────────────

  bool get isCredit    => type == TransactionType.credit;
  bool get isDebit     => type == TransactionType.debit;
  bool get isCompleted => status == TransactionStatus.completed;
  bool get isPending   => status == TransactionStatus.pending;
  bool get isFailed    => status == TransactionStatus.failed;
  bool get isRefunded  => status == TransactionStatus.refunded;

  // ── Serialisation ─────────────────────────────────────────────────────────

  factory Transaction.fromMap(Map<String, dynamic> map) {
    return Transaction(
      id:            map['id'] as String? ?? '',
      userId:        map['userId'] as String? ?? '',
      amount:        (map['amount'] as num?)?.toDouble() ?? 0.0,
      type:          TransactionType.values.firstWhere(
                       (e) => e.name == map['type'],
                       orElse: () => TransactionType.debit,
                     ),
      status:        TransactionStatus.values.firstWhere(
                       (e) => e.name == map['status'],
                       orElse: () => TransactionStatus.pending,
                     ),
      description:   map['description'] as String? ?? '',
      paymentMethod: PaymentMethod.values.firstWhere(
                       (e) => e.name == map['paymentMethod'],
                       orElse: () => PaymentMethod.cash,
                     ),
      reference:     map['reference'] as String? ?? '',
      createdAt:     map['createdAt'] != null
                       ? (map['createdAt'] as Timestamp).toDate()
                       : DateTime.now(),
      metadata:      map['metadata'] != null
                       ? Map<String, dynamic>.from(map['metadata'] as Map)
                       : null,
    );
  }

  Map<String, dynamic> toMap() => {
        'id':            id,
        'userId':        userId,
        'amount':        amount,
        'type':          type.name,
        'status':        status.name,
        'description':   description,
        'paymentMethod': paymentMethod.name,
        'reference':     reference,
        'createdAt':     Timestamp.fromDate(createdAt),
        'metadata':      metadata,
      };

  // ── copyWith ──────────────────────────────────────────────────────────────

  Transaction copyWith({
    String?                  id,
    String?                  userId,
    double?                  amount,
    TransactionType?         type,
    TransactionStatus?       status,
    String?                  description,
    PaymentMethod?           paymentMethod,
    String?                  reference,
    DateTime?                createdAt,
    Map<String, dynamic>?    metadata,
  }) =>
      Transaction(
        id:            id            ?? this.id,
        userId:        userId        ?? this.userId,
        amount:        amount        ?? this.amount,
        type:          type          ?? this.type,
        status:        status        ?? this.status,
        description:   description   ?? this.description,
        paymentMethod: paymentMethod ?? this.paymentMethod,
        reference:     reference     ?? this.reference,
        createdAt:     createdAt     ?? this.createdAt,
        metadata:      metadata      ?? this.metadata,
      );

  // ── Equatable ─────────────────────────────────────────────────────────────

  @override
  List<Object?> get props => [
        id, userId, amount, type, status,
        description, paymentMethod, reference, createdAt, metadata,
      ];

  @override
  String toString() =>
      'Transaction(id: $id, type: ${type.name}, amount: $amount, '
      'status: ${status.name})';
}

// ── Extensions ────────────────────────────────────────────────────────────────

extension TransactionTypeX on TransactionType {
  String get displayName => switch (this) {
        TransactionType.credit => 'Credit',
        TransactionType.debit  => 'Debit',
      };
}

extension TransactionStatusX on TransactionStatus {
  String get displayName => switch (this) {
        TransactionStatus.pending   => 'Pending',
        TransactionStatus.completed => 'Completed',
        TransactionStatus.failed    => 'Failed',
        TransactionStatus.refunded  => 'Refunded',
      };
}

extension PaymentMethodX on PaymentMethod {
  String get displayName => switch (this) {
        PaymentMethod.mobileMoney  => 'Mobile Money',
        PaymentMethod.card         => 'Card',
        PaymentMethod.bankTransfer => 'Bank Transfer',
        PaymentMethod.cash         => 'Cash',
        PaymentMethod.system       => 'System',
      };
}