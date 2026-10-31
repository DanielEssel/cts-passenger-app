// lib/features/gas/domain/gas_checkout.dart
//
// What a gas order submission works from, fixed at the moment the customer
// taps "Place gas order", and the collaborators the order screen uses to
// check out. The defaults (null) are the real services; tests pass fakes.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';

import '../../../core/services/escrow_service.dart';
import '../models/gas_refill_request.dart';
import '../presentation/widgets/gas_payment_sheet.dart';
import 'gas_pricing.dart';

/// Everything an order is placed with, captured once. The payment sheet,
/// the wallet hold and the order document all read from the same quote, so
/// a later change on screen (or a late distance result) cannot make the
/// amount held differ from the amount shown or recorded.
class GasOrderQuote {
  final GasRefillType type;
  final CylinderSize size;
  final GasBrand? brand;
  final int quantity;
  final String address;
  final GeoPoint location;
  final String paymentMethod;
  final bool safetyAccepted;
  final GasPriceBreakdown pricing;

  const GasOrderQuote({
    required this.type,
    required this.size,
    required this.brand,
    required this.quantity,
    required this.address,
    required this.location,
    required this.paymentMethod,
    required this.safetyAccepted,
    required this.pricing,
  });

  double get total => pricing.total;
  double get deliveryFee => pricing.deliveryFee;
}

/// The order screen's outside calls. Any left null uses the real service.
class GasCheckoutDeps {
  /// Opens the address picker; returns {'address': String, 'location':
  /// GeoPoint} or null.
  final Future<Map<String, dynamic>?> Function(BuildContext context)?
      pickAddress;

  /// One-way distance in km used for the delivery fee.
  final Future<double> Function(GeoPoint destination)? estimateDistanceKm;

  /// Shows the wallet payment sheet; true when the customer confirms.
  final Future<bool?> Function(BuildContext context, GasPaymentSheet sheet)?
      confirmWalletPayment;

  /// Holds [amount] from the wallet in escrow.
  final Future<EscrowResult> Function(double amount)? holdBalance;

  /// Links the escrow to the created order.
  final Future<void> Function(String escrowId, String orderId)? attachEscrow;

  /// Records the escrow id on the order document.
  final Future<void> Function(String orderId, String escrowId)?
      saveOrderEscrowId;

  /// The signed-in customer's uid, or null.
  final String? Function()? currentUserId;

  /// Reads the current prices (settings/platform) from the server before an
  /// order is placed; false when they could not be read, and nothing is
  /// then held or ordered.
  final Future<bool> Function()? refreshPricing;

  /// Asks the customer to accept a total that changed from [was] to [now]
  /// since it was shown; true to go on at [now].
  final Future<bool?> Function(BuildContext context, double was, double now)?
      confirmPriceChange;

  const GasCheckoutDeps({
    this.pickAddress,
    this.estimateDistanceKm,
    this.confirmWalletPayment,
    this.holdBalance,
    this.attachEscrow,
    this.saveOrderEscrowId,
    this.currentUserId,
    this.refreshPricing,
    this.confirmPriceChange,
  });
}
