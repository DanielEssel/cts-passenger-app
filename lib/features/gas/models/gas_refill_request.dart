// lib/features/gas/models/gas_refill_request.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/utils/otp_utils.dart';
import '../../../core/services/pricing_service.dart';
import 'package:flutter/material.dart';

// ─────────────────────────────────────────────
// Enums
// ─────────────────────────────────────────────

enum GasRefillType {
  exchangeEmpty,
  newCylinder,
  pickupAndReturn,
  commercialBulk;

  String get displayName => switch (this) {
        GasRefillType.exchangeEmpty => 'Exchange Empty',
        GasRefillType.newCylinder => 'New Cylinder',
        GasRefillType.pickupAndReturn => 'Pickup & Return',
        GasRefillType.commercialBulk => 'Commercial Bulk',
      };

  IconData get icon => switch (this) {
        GasRefillType.exchangeEmpty => Icons.swap_horiz_rounded,
        GasRefillType.newCylinder => Icons.add_circle_outline_rounded,
        GasRefillType.pickupAndReturn => Icons.local_shipping_rounded,
        GasRefillType.commercialBulk => Icons.business_rounded,
      };

  Duration get estimatedDuration => switch (this) {
        GasRefillType.exchangeEmpty => const Duration(minutes: 35),
        GasRefillType.newCylinder => const Duration(minutes: 50),
        GasRefillType.pickupAndReturn => const Duration(hours: 2, minutes: 30),
        GasRefillType.commercialBulk => const Duration(hours: 1, minutes: 30),
      };

  String get firestoreValue => name;

  static GasRefillType fromFirestore(String value) =>
      GasRefillType.values.firstWhere(
        (e) => e.name == value,
        orElse: () => GasRefillType.exchangeEmpty,
      );

  /// The ordered tracking steps for this type. Two flows:
  ///  • Pickup & Return → full round trip (collect → station → refill → return)
  ///  • Everything else → simple drop-off
  List<GasOrderStatus> get steps => switch (this) {
        GasRefillType.pickupAndReturn => const [
            GasOrderStatus.driverEnRoute,
            GasOrderStatus.driverArrived,
            GasOrderStatus.pickedUp,
            GasOrderStatus.atStation,
            GasOrderStatus.refilling,
            GasOrderStatus.returning,
            GasOrderStatus.delivered,
          ],
        _ => const [
            GasOrderStatus.driverEnRoute,
            GasOrderStatus.driverArrived,
            GasOrderStatus.delivered,
          ],
      };
}

// ─────────────────────────────────────────────

enum CylinderSize {
  kg3,
  kg6,
  kg12_5,
  kg14_5,
  kg19,
  kg45;

  String get displayName => switch (this) {
        CylinderSize.kg3 => '3 kg',
        CylinderSize.kg6 => '6 kg',
        CylinderSize.kg12_5 => '12.5 kg',
        CylinderSize.kg14_5 => '14.5 kg',
        CylinderSize.kg19 => '19 kg',
        CylinderSize.kg45 => '45 kg',
      };

  double get weight => switch (this) {
        CylinderSize.kg3 => 3.0,
        CylinderSize.kg6 => 6.0,
        CylinderSize.kg12_5 => 12.5,
        CylinderSize.kg14_5 => 14.5,
        CylinderSize.kg19 => 19.0,
        CylinderSize.kg45 => 45.0,
      };

  // Prices in GHS — fetched from Firestore settings/platform via PricingService.

  /// Gas-only refill price. Used by Exchange Empty and Pickup & Return.
  double get refillPrice {
    final p = PricingService.instance;
    return switch (this) {
      CylinderSize.kg3    => p.gasRefill3kg,
      CylinderSize.kg6    => p.gasRefill6kg,
      CylinderSize.kg12_5 => p.gasRefill12kg,
      CylinderSize.kg14_5 => p.gasRefill14kg,
      CylinderSize.kg19   => p.gasRefill19kg,
      CylinderSize.kg45   => p.gasRefill45kg,
    };
  }

  /// Full cylinder price (hardware + first fill). Used by New Cylinder.
  double get fullCylinderPrice {
    final p = PricingService.instance;
    return switch (this) {
      CylinderSize.kg3    => p.gasFull3kg,
      CylinderSize.kg6    => p.gasFull6kg,
      CylinderSize.kg12_5 => p.gasFull12kg,
      CylinderSize.kg14_5 => p.gasFull14kg,
      CylinderSize.kg19   => p.gasFull19kg,
      CylinderSize.kg45   => p.gasFull45kg,
    };
  }

  String get firestoreValue => name;

  static CylinderSize fromFirestore(String value) =>
      CylinderSize.values.firstWhere(
        (e) => e.name == value,
        orElse: () => CylinderSize.kg12_5,
      );
}

// ─────────────────────────────────────────────

enum GasBrand {
  goGas,
  soilGroup,
  total,
  zola,
  radix,
  any;

  String get displayName => switch (this) {
        GasBrand.goGas => 'GoGas',
        GasBrand.soilGroup => 'Soil Group',
        GasBrand.total => 'TotalEnergies',
        GasBrand.zola => 'Zola',
        GasBrand.radix => 'Radix',
        GasBrand.any => 'Any Brand',
      };

  double get priceMultiplier => switch (this) {
        GasBrand.goGas => 1.0,
        GasBrand.soilGroup => 1.0,
        GasBrand.total => 1.05,
        GasBrand.zola => 1.03,
        GasBrand.radix => 1.02,
        GasBrand.any => 1.0,
      };

  String get firestoreValue => name;

  static GasBrand fromFirestore(String value) =>
      GasBrand.values.firstWhere(
        (e) => e.name == value,
        orElse: () => GasBrand.any,
      );
}

// ─────────────────────────────────────────────

enum GasOrderStatus {
  pendingApproval,
  confirmed,
  driverAssigned,
  driverEnRoute,
  driverArrived,
  pickedUp,
  atStation,
  refilling,
  returning,
  outForDelivery,
  delivered,
  cancelled,
  failed;

  String get displayName => switch (this) {
        GasOrderStatus.pendingApproval => 'Pending Approval',
        GasOrderStatus.confirmed => 'Confirmed',
        GasOrderStatus.driverAssigned => 'Driver Assigned',
        GasOrderStatus.driverEnRoute => 'Driver En Route',
        GasOrderStatus.driverArrived => 'Driver Arrived',
        GasOrderStatus.pickedUp => 'Picked Up',
        GasOrderStatus.atStation => 'At Station',
        GasOrderStatus.refilling => 'Refilling',
        GasOrderStatus.returning => 'Returning',
        GasOrderStatus.outForDelivery => 'Out for Delivery',
        GasOrderStatus.delivered => 'Delivered',
        GasOrderStatus.cancelled => 'Cancelled',
        GasOrderStatus.failed => 'Failed',
      };

  /// Passenger-facing label — mirrors the pattern in TripStatus / DeliveryStatus.
  String get passengerDisplayName => switch (this) {
        GasOrderStatus.pendingApproval => 'Finding a driver…',
        GasOrderStatus.confirmed => 'Order Confirmed',
        GasOrderStatus.driverAssigned => 'Driver on the way',
        GasOrderStatus.driverEnRoute => 'Driver is coming',
        GasOrderStatus.driverArrived => 'Driver has arrived',
        GasOrderStatus.pickedUp => 'Cylinder picked up',
        GasOrderStatus.atStation => 'At the refill station',
        GasOrderStatus.refilling => 'Refilling your cylinder',
        GasOrderStatus.returning => 'Returning with your cylinder',
        GasOrderStatus.outForDelivery => 'On the way to you',
        GasOrderStatus.delivered => 'Delivered!',
        GasOrderStatus.cancelled => 'Order Cancelled',
        GasOrderStatus.failed => 'Order Failed',
      };

  Color get color => switch (this) {
        GasOrderStatus.pendingApproval => Colors.orange,
        GasOrderStatus.confirmed => Colors.blue,
        GasOrderStatus.driverAssigned => Colors.indigo,
        GasOrderStatus.driverEnRoute => Colors.blue,
        GasOrderStatus.driverArrived => Colors.cyan,
        GasOrderStatus.pickedUp => Colors.purple,
        GasOrderStatus.atStation => Colors.deepPurple,
        GasOrderStatus.refilling => Colors.teal,
        GasOrderStatus.returning => Colors.cyan,
        GasOrderStatus.outForDelivery => Colors.cyan,
        GasOrderStatus.delivered => Colors.green,
        GasOrderStatus.cancelled => Colors.red,
        GasOrderStatus.failed => Colors.red,
      };

  /// Short label for the stepper chips (driver + passenger).
  String get stepLabel => switch (this) {
        GasOrderStatus.driverEnRoute => 'En Route',
        GasOrderStatus.driverArrived => 'Arrived',
        GasOrderStatus.pickedUp => 'Collected',
        GasOrderStatus.atStation => 'At Station',
        GasOrderStatus.refilling => 'Refilling',
        GasOrderStatus.returning => 'Returning',
        GasOrderStatus.delivered => 'Delivered',
        _ => displayName,
      };

  /// The button label shown to the driver to ADVANCE INTO this status.
  String get driverActionLabel => switch (this) {
        GasOrderStatus.driverEnRoute => 'Start — En Route to Customer',
        GasOrderStatus.driverArrived => 'I Have Arrived',
        GasOrderStatus.pickedUp => 'Cylinder Collected',
        GasOrderStatus.atStation => 'Arrived at Station',
        GasOrderStatus.refilling => 'Start Refilling',
        GasOrderStatus.returning => 'Refill Done — Returning',
        GasOrderStatus.delivered => 'Complete Delivery',
        _ => 'Continue',
      };

  String get firestoreValue => name;

  static GasOrderStatus fromFirestore(String value) =>
      GasOrderStatus.values.firstWhere(
        (e) => e.name == value,
        orElse: () => GasOrderStatus.pendingApproval,
      );

  double get progressValue => switch (this) {
  GasOrderStatus.pendingApproval  => 0.1,
  GasOrderStatus.confirmed        => 0.25,
  GasOrderStatus.driverAssigned   => 0.35,
  GasOrderStatus.driverEnRoute    => 0.45,
  GasOrderStatus.driverArrived    => 0.55,
  GasOrderStatus.pickedUp         => 0.6,
  GasOrderStatus.atStation        => 0.68,
  GasOrderStatus.refilling        => 0.76,
  GasOrderStatus.returning        => 0.88,
  GasOrderStatus.outForDelivery   => 0.85,
  GasOrderStatus.delivered        => 1.0,
  GasOrderStatus.cancelled        => 0.0,
  GasOrderStatus.failed           => 0.0,
};
}

// ─────────────────────────────────────────────
// GasRefillRequest Model
// ─────────────────────────────────────────────

class GasRefillRequest {
  final String id;
  final String passengerId;
  final String? driverId;
  final String?   driverName;
  final String?   driverPhone;
  final String?   driverVehicle;    // e.g. "Motorcycle · GR-1234-22"
  final GeoPoint? driverLocation;
  final double?   driverHeading;   // live location, nullable
  final GasRefillType refillType;
  final CylinderSize cylinderSize;
  final GasBrand? preferredBrand;
  final int quantity;
  final GasOrderStatus status;

  // Location (Firestore GeoPoint)
  final GeoPoint pickupLocation;
  final GeoPoint deliveryLocation;
  final String? preferredStation;

  // Addresses
  final String pickupAddress;
  final String deliveryAddress;
  final String? preferredStationAddress;
  final String? pickupInstructions;
  final String? deliveryInstructions;

  // Cylinder condition
  final bool cylinderIsAvailable;
  final bool cylinderInGoodCondition;
  final String? cylinderConditionNotes;
  final bool safetyChecklistCompleted;

  // Pricing
  final double gasAmount;    // kg total
  final double gasPrice;     // price per kg or per cylinder
  final double serviceFee;
  final double deliveryFee;
  final double totalPrice;

  // Timestamps
  final DateTime createdAt;
  final DateTime? scheduledPickupAt;
  final DateTime? scheduledDeliveryBy;
  final DateTime? pickupCompletedAt;
  final DateTime? refillCompletedAt;
  final DateTime? deliveredAt;
  final DateTime? cancelledAt;

  // Payment
  final String paymentMethod;
  final bool requiresReceipt;
  final String? receiptEmail;

  // Ratings
  final double? passengerRating;
  final double? driverRating;

  // OTP for delivery confirmation
  final String? deliveryOtp;
  // Extra
  final Map<String, dynamic> metadata;

  const GasRefillRequest({
    required this.id,
    required this.passengerId,
    this.driverId,
    this.driverName,
    this.driverPhone,
    this.driverVehicle,
    this.driverLocation,
    required this.refillType,
    required this.cylinderSize,
    this.preferredBrand,
    required this.quantity,
    required this.status,
    required this.pickupLocation,
    required this.deliveryLocation,
    this.driverHeading,
    this.preferredStation,
    required this.pickupAddress,
    required this.deliveryAddress,
    this.preferredStationAddress,
    this.pickupInstructions,
    this.deliveryInstructions,
    required this.cylinderIsAvailable,
    required this.cylinderInGoodCondition,
    this.cylinderConditionNotes,
    required this.safetyChecklistCompleted,
    required this.gasAmount,
    required this.gasPrice,
    required this.serviceFee,
    required this.deliveryFee,
    required this.totalPrice,
    required this.createdAt,
    this.scheduledPickupAt,
    this.scheduledDeliveryBy,
    this.pickupCompletedAt,
    this.refillCompletedAt,
    this.deliveredAt,
    this.cancelledAt,
    required this.paymentMethod,
    required this.requiresReceipt,
    this.receiptEmail,
    this.passengerRating,
    this.driverRating,
    this.deliveryOtp,
    required this.metadata,
  });

  // ── Firestore Serialisation ──

  Map<String, dynamic> toFirestore() {
    return {
      'passengerId': passengerId,
      'driverId':       driverId,
    'driverName':     driverName,
    'driverPhone':    driverPhone,
    'driverVehicle':  driverVehicle,
    'driverLocation': driverLocation,
    'driverHeading':  driverHeading,
      'refillType': refillType.firestoreValue,
      'cylinderSize': cylinderSize.firestoreValue,
      'preferredBrand': preferredBrand?.firestoreValue,
      'quantity': quantity,
      'status': status.firestoreValue,
      'pickupLocation': pickupLocation,
      'deliveryLocation': deliveryLocation,
      'preferredStation': preferredStation,
      'pickupAddress': pickupAddress,
      'deliveryAddress': deliveryAddress,
      'preferredStationAddress': preferredStationAddress,
      'pickupInstructions': pickupInstructions,
      'deliveryInstructions': deliveryInstructions,
      'cylinderIsAvailable': cylinderIsAvailable,
      'cylinderInGoodCondition': cylinderInGoodCondition,
      'cylinderConditionNotes': cylinderConditionNotes,
      'safetyChecklistCompleted': safetyChecklistCompleted,
      'gasAmount': gasAmount,
      'gasPrice': gasPrice,
      'serviceFee': serviceFee,
      'deliveryFee': deliveryFee,
      'totalPrice': totalPrice,
      'createdAt': Timestamp.fromDate(createdAt),
      'scheduledPickupAt':
          scheduledPickupAt != null ? Timestamp.fromDate(scheduledPickupAt!) : null,
      'scheduledDeliveryBy':
          scheduledDeliveryBy != null ? Timestamp.fromDate(scheduledDeliveryBy!) : null,
      'pickupCompletedAt':
          pickupCompletedAt != null ? Timestamp.fromDate(pickupCompletedAt!) : null,
      'refillCompletedAt':
          refillCompletedAt != null ? Timestamp.fromDate(refillCompletedAt!) : null,
      'deliveredAt':
          deliveredAt != null ? Timestamp.fromDate(deliveredAt!) : null,
      'cancelledAt':
          cancelledAt != null ? Timestamp.fromDate(cancelledAt!) : null,
      'paymentMethod': paymentMethod,
      'requiresReceipt': requiresReceipt,
      'receiptEmail': receiptEmail,
      'passengerRating': passengerRating,
      'driverRating': driverRating,
      'metadata':    metadata,
      'deliveryOtp':  deliveryOtp ?? OtpUtils.generate(),
    };
  }

  factory GasRefillRequest.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data()!;
    return GasRefillRequest(
      id: doc.id,
      passengerId: d['passengerId'] as String,
      driverId:       d['driverId']       as String?,
      driverName:     d['driverName']     as String?,
      driverPhone:    d['driverPhone']    as String?,
      driverVehicle:  d['driverVehicle']  as String?,
      driverLocation: d['driverLocation'] as GeoPoint?,
      refillType: GasRefillType.fromFirestore(d['refillType'] as String),
      cylinderSize: CylinderSize.fromFirestore(d['cylinderSize'] as String),
      preferredBrand: d['preferredBrand'] != null
          ? GasBrand.fromFirestore(d['preferredBrand'] as String)
          : null,
      quantity: (d['quantity'] as num).toInt(),
      status: GasOrderStatus.fromFirestore(d['status'] as String),
      pickupLocation: d['pickupLocation'] as GeoPoint,
      deliveryLocation: d['deliveryLocation'] as GeoPoint,
      preferredStation: d['preferredStation'] as String?,
      pickupAddress: d['pickupAddress'] as String,
      deliveryAddress: d['deliveryAddress'] as String,
      preferredStationAddress: d['preferredStationAddress'] as String?,
      pickupInstructions: d['pickupInstructions'] as String?,
      deliveryInstructions: d['deliveryInstructions'] as String?,
      cylinderIsAvailable: d['cylinderIsAvailable'] as bool? ?? true,
      cylinderInGoodCondition: d['cylinderInGoodCondition'] as bool? ?? true,
      cylinderConditionNotes: d['cylinderConditionNotes'] as String?,
      safetyChecklistCompleted: d['safetyChecklistCompleted'] as bool? ?? false,
      gasAmount: (d['gasAmount'] as num).toDouble(),
      gasPrice: (d['gasPrice'] as num).toDouble(),
      serviceFee: (d['serviceFee'] as num).toDouble(),
      deliveryFee: (d['deliveryFee'] as num).toDouble(),
      totalPrice: (d['totalPrice'] as num).toDouble(),
      createdAt: (d['createdAt'] as Timestamp).toDate(),
      scheduledPickupAt:
          (d['scheduledPickupAt'] as Timestamp?)?.toDate(),
      scheduledDeliveryBy:
          (d['scheduledDeliveryBy'] as Timestamp?)?.toDate(),
      pickupCompletedAt:
          (d['pickupCompletedAt'] as Timestamp?)?.toDate(),
      refillCompletedAt:
          (d['refillCompletedAt'] as Timestamp?)?.toDate(),
      deliveredAt: (d['deliveredAt'] as Timestamp?)?.toDate(),
      cancelledAt: (d['cancelledAt'] as Timestamp?)?.toDate(),
      paymentMethod: d['paymentMethod'] as String? ?? 'wallet',
      requiresReceipt: d['requiresReceipt'] as bool? ?? false,
      receiptEmail: d['receiptEmail'] as String?,
      passengerRating: (d['passengerRating'] as num?)?.toDouble(),
      driverRating:  (d['driverRating']  as num?)?.toDouble(),
      deliveryOtp:    d['deliveryOtp']    as String?,
      metadata: Map<String, dynamic>.from(d['metadata'] as Map? ?? {}),
    );
  }

  GasRefillRequest copyWith({
    String? id,
    String? passengerId,
    String? driverId,
    String?   driverName,
    String?   driverPhone,
    String?   driverVehicle,
    GeoPoint? driverLocation,
    GasRefillType? refillType,
    CylinderSize? cylinderSize,
    GasBrand? preferredBrand,
    int? quantity,
    GasOrderStatus? status,
    GeoPoint? pickupLocation,
    GeoPoint? deliveryLocation,
    String? preferredStation,
    String? pickupAddress,
    String? deliveryAddress,
    String? preferredStationAddress,
    String? pickupInstructions,
    String? deliveryInstructions,
    bool? cylinderIsAvailable,
    bool? cylinderInGoodCondition,
    String? cylinderConditionNotes,
    bool? safetyChecklistCompleted,
    double? gasAmount,
    double? gasPrice,
    double? serviceFee,
    double? deliveryFee,
    double? totalPrice,
    DateTime? createdAt,
    DateTime? scheduledPickupAt,
    DateTime? scheduledDeliveryBy,
    DateTime? pickupCompletedAt,
    DateTime? refillCompletedAt,
    DateTime? deliveredAt,
    DateTime? cancelledAt,
    String? paymentMethod,
    bool? requiresReceipt,
    String? receiptEmail,
    double? passengerRating,
    double? driverRating,
    Map<String, dynamic>? metadata,
  }) {
    return GasRefillRequest(
      id: id ?? this.id,
      passengerId: passengerId ?? this.passengerId,
      driverId:       driverId       ?? this.driverId,
      driverName:     driverName     ?? this.driverName,
      driverPhone:    driverPhone    ?? this.driverPhone,
      driverVehicle:  driverVehicle  ?? this.driverVehicle,
      driverLocation: driverLocation ?? this.driverLocation,
      refillType: refillType ?? this.refillType,
      cylinderSize: cylinderSize ?? this.cylinderSize,
      preferredBrand: preferredBrand ?? this.preferredBrand,
      quantity: quantity ?? this.quantity,
      status: status ?? this.status,
      pickupLocation: pickupLocation ?? this.pickupLocation,
      deliveryLocation: deliveryLocation ?? this.deliveryLocation,
      preferredStation: preferredStation ?? this.preferredStation,
      pickupAddress: pickupAddress ?? this.pickupAddress,
      deliveryAddress: deliveryAddress ?? this.deliveryAddress,
      preferredStationAddress:
          preferredStationAddress ?? this.preferredStationAddress,
      pickupInstructions: pickupInstructions ?? this.pickupInstructions,
      deliveryInstructions: deliveryInstructions ?? this.deliveryInstructions,
      cylinderIsAvailable: cylinderIsAvailable ?? this.cylinderIsAvailable,
      cylinderInGoodCondition:
          cylinderInGoodCondition ?? this.cylinderInGoodCondition,
      cylinderConditionNotes:
          cylinderConditionNotes ?? this.cylinderConditionNotes,
      safetyChecklistCompleted:
          safetyChecklistCompleted ?? this.safetyChecklistCompleted,
      gasAmount: gasAmount ?? this.gasAmount,
      gasPrice: gasPrice ?? this.gasPrice,
      serviceFee: serviceFee ?? this.serviceFee,
      deliveryFee: deliveryFee ?? this.deliveryFee,
      totalPrice: totalPrice ?? this.totalPrice,
      createdAt: createdAt ?? this.createdAt,
      scheduledPickupAt: scheduledPickupAt ?? this.scheduledPickupAt,
      scheduledDeliveryBy: scheduledDeliveryBy ?? this.scheduledDeliveryBy,
      pickupCompletedAt: pickupCompletedAt ?? this.pickupCompletedAt,
      refillCompletedAt: refillCompletedAt ?? this.refillCompletedAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      cancelledAt: cancelledAt ?? this.cancelledAt,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      requiresReceipt: requiresReceipt ?? this.requiresReceipt,
      receiptEmail: receiptEmail ?? this.receiptEmail,
      passengerRating: passengerRating ?? this.passengerRating,
      driverRating: driverRating ?? this.driverRating,
      metadata: metadata ?? this.metadata,
    );
  }
}