import 'package:flutter/material.dart';

import '../../ride/services/payment_method_service.dart';

enum PaymentType {
  wallet,
  cash,
  momo,
  card,
}

class PaymentMethod {
  final PaymentType type;
  final String name;
  final IconData icon;
  final String subtitle;
  final bool isRecommended;

  const PaymentMethod({
    required this.type,
    required this.name,
    required this.icon,
    this.subtitle = '',
    this.isRecommended = false,
  });

  String get displayName => name;

  /// Convert enum -> full payment model
  static PaymentMethod fromType(PaymentType type) {
    return PaymentMethodService.availableMethods.firstWhere(
      (method) => method.type == type,
    );
  }
}