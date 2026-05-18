// lib/features/gas/models/gas_order.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

enum GasOrderType {
  pickupAndRefill, // Driver picks passenger's empty, refills, returns
  exchangeEmpty, // Driver brings filled, exchanges for passenger's empty
  deliverNew, // Driver delivers new filled cylinder to passenger
  pickupAndReturn, // Driver picks up passenger's empty only
  commercialBulk; // Commercial bulk orders for businesses

  String get displayName {
    switch (this) {
      case GasOrderType.pickupAndRefill:
        return 'Pickup & Refill';
      case GasOrderType.exchangeEmpty:
        return 'Exchange Cylinder';
      case GasOrderType.deliverNew:
        return 'New Cylinder';
      case GasOrderType.pickupAndReturn:
        return 'Return Empty';
      case GasOrderType.commercialBulk:
        return 'Commercial Bulk';
    }
  }
}

enum CylinderSize {
  size3kg(3.0, 45.0),
  size5kg(5.0, 75.0),
  size6kg(6.0, 90.0),
  size12_5kg(12.5, 185.0),
  size14_5kg(14.5, 215.0);

  final double weight;
  final double basePrice;
  const CylinderSize(this.weight, this.basePrice);

  String get displayName => '${weight.toStringAsFixed(1)}kg';
}

enum GasBrand {
  gogas('GoGas'),
  shell('Shell'),
  total('Total'),
  fraga('Fraga'),
  manbah('Manbah');

  final String name;
  const GasBrand(this.name);
}

enum GasOrderStatus {
  pending, // Waiting for driver assignment
  driverAssigned, // Driver confirmed
  pickupEnroute, // Driver coming to pick up cylinder
  cylinderPicked, // Driver has passenger's cylinder
  refillingInProgress, // At gas station refilling
  refillCompleted, // Refill done, returning
  deliveryEnroute, // Driver bringing filled cylinder back
  completed, // Order completed
  cancelled, // Passenger cancelled
  failed; // Order failed

  bool get isActive => this != completed && this != cancelled && this != failed;

  String get passengerDisplayName {
    switch (this) {
      case GasOrderStatus.pending:
        return 'Finding a driver...';
      case GasOrderStatus.driverAssigned:
        return 'Driver assigned';
      case GasOrderStatus.pickupEnroute:
        return 'Driver coming for pickup';
      case GasOrderStatus.cylinderPicked:
        return 'Cylinder picked up';
      case GasOrderStatus.refillingInProgress:
        return 'Refilling in progress';
      case GasOrderStatus.refillCompleted:
        return 'Refill completed';
      case GasOrderStatus.deliveryEnroute:
        return 'Driver returning with gas';
      case GasOrderStatus.completed:
        return 'Gas delivered';
      case GasOrderStatus.cancelled:
        return 'Order cancelled';
      case GasOrderStatus.failed:
        return 'Order failed';
    }
  }
}

class GasOrder extends Equatable {
  final String id;
  final String passengerId; // Changed from userId
  final String? driverId;
  final GasOrderType orderType;
  final CylinderSize cylinderSize;
  final GasBrand? preferredBrand;
  final int quantity;
  final GasOrderStatus status;
  final GeoPoint pickupLocation; // Passenger's location for cylinder pickup
  final GeoPoint?
      refillStation; // Optional: passenger can specify preferred station
  final GeoPoint deliveryLocation; // Where to deliver filled cylinder
  final String pickupAddress;
  final String deliveryAddress;
  final String? refillStationAddress;
  final double basePrice;
  final double deliveryFee;
  final double totalPrice;
  final bool safetyChecklistCompleted;
  final DateTime createdAt;
  final DateTime? scheduledFor;
  final DateTime? completedAt;
  final Map<String, dynamic> metadata;

  const GasOrder({
    required this.id,
    required this.passengerId,
    this.driverId,
    required this.orderType,
    required this.cylinderSize,
    this.preferredBrand,
    required this.quantity,
    required this.status,
    required this.pickupLocation,
    this.refillStation,
    required this.deliveryLocation,
    required this.pickupAddress,
    required this.deliveryAddress,
    this.refillStationAddress,
    required this.basePrice,
    required this.deliveryFee,
    required this.totalPrice,
    required this.safetyChecklistCompleted,
    required this.createdAt,
    this.scheduledFor,
    this.completedAt,
    required this.metadata,
  });

  factory GasOrder.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return GasOrder(
      id: doc.id,
      passengerId: data['passengerId'],
      driverId: data['driverId'],
      orderType: GasOrderType.values
          .firstWhere((e) => e.toString() == data['orderType']),
      cylinderSize: CylinderSize.values
          .firstWhere((e) => e.toString() == data['cylinderSize']),
      preferredBrand: data['preferredBrand'] != null
          ? GasBrand.values
              .firstWhere((e) => e.toString() == data['preferredBrand'])
          : null,
      quantity: data['quantity'] ?? 1,
      status: GasOrderStatus.values
          .firstWhere((e) => e.toString() == data['status']),
      pickupLocation: data['pickupLocation'],
      refillStation: data['refillStation'],
      deliveryLocation: data['deliveryLocation'],
      pickupAddress: data['pickupAddress'],
      deliveryAddress: data['deliveryAddress'],
      refillStationAddress: data['refillStationAddress'],
      basePrice: (data['basePrice'] as num).toDouble(),
      deliveryFee: (data['deliveryFee'] as num).toDouble(),
      totalPrice: (data['totalPrice'] as num).toDouble(),
      safetyChecklistCompleted: data['safetyChecklistCompleted'] ?? false,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      scheduledFor: data['scheduledFor'] != null
          ? (data['scheduledFor'] as Timestamp).toDate()
          : null,
      completedAt: data['completedAt'] != null
          ? (data['completedAt'] as Timestamp).toDate()
          : null,
      metadata: data['metadata'] ?? {},
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'passengerId': passengerId,
      'driverId': driverId,
      'orderType': orderType.toString(),
      'cylinderSize': cylinderSize.toString(),
      'preferredBrand': preferredBrand?.toString(),
      'quantity': quantity,
      'status': status.name,
      'pickupLocation': pickupLocation,
      'refillStation': refillStation,
      'deliveryLocation': deliveryLocation,
      'pickupAddress': pickupAddress,
      'deliveryAddress': deliveryAddress,
      'refillStationAddress': refillStationAddress,
      'basePrice': basePrice,
      'deliveryFee': deliveryFee,
      'totalPrice': totalPrice,
      'safetyChecklistCompleted': safetyChecklistCompleted,
      'createdAt': Timestamp.fromDate(createdAt),
      'scheduledFor':
          scheduledFor != null ? Timestamp.fromDate(scheduledFor!) : null,
      'completedAt':
          completedAt != null ? Timestamp.fromDate(completedAt!) : null,
      'metadata': metadata,
    };
  }

  @override
  List<Object?> get props => [
        id,
        passengerId,
        driverId,
        orderType,
        cylinderSize,
        preferredBrand,
        quantity,
        status,
        pickupLocation,
        refillStation,
        deliveryLocation,
        pickupAddress,
        deliveryAddress,
        refillStationAddress,
        basePrice,
        deliveryFee,
        totalPrice,
        safetyChecklistCompleted,
        createdAt,
        scheduledFor,
        completedAt,
        metadata
      ];
}
