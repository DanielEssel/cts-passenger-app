// lib/features/wallet/domain/entities/bridge_payment_status.dart

import 'package:equatable/equatable.dart';

enum BridgeLocalStatus { pending, success, failed, cancelled, unknown }

class BridgePaymentStatus extends Equatable {
  const BridgePaymentStatus({
    required this.localStatus,
    this.bridgeStatus,
    this.amount,
    this.transactionId,
  });

  final BridgeLocalStatus localStatus;
  final String? bridgeStatus;   // Bridge raw code: "000", "001", "002", "003"
  final double? amount;
  final String? transactionId;

  bool get isSuccess   => localStatus == BridgeLocalStatus.success;
  bool get isFailed    => localStatus == BridgeLocalStatus.failed
                       || localStatus == BridgeLocalStatus.cancelled;
  bool get isPending   => localStatus == BridgeLocalStatus.pending;

  factory BridgePaymentStatus.fromMap(Map<String, dynamic> map) {
    final raw = map['localStatus'] as String? ?? 'pending';
    final status = switch (raw) {
      'success'   => BridgeLocalStatus.success,
      'failed'    => BridgeLocalStatus.failed,
      'cancelled' => BridgeLocalStatus.cancelled,
      'pending'   => BridgeLocalStatus.pending,
      _           => BridgeLocalStatus.unknown,
    };

    return BridgePaymentStatus(
      localStatus:   status,
      bridgeStatus:  map['status'] as String?,
      amount:        (map['amount'] as num?)?.toDouble(),
      transactionId: map['transactionId'] as String?,
    );
  }

  @override
  List<Object?> get props => [localStatus, bridgeStatus, amount, transactionId];
}