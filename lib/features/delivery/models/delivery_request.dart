// NEW FILE: lib/features/delivery/models/delivery_request.dart
// Simplified version that works with your existing DeliveryVehicleScreen

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

enum DeliveryStatus {
  pending,
  driverAssigned,
  pickupEnroute,
  arrivedAtPickup,
  packagePicked,
  deliveryEnroute,
  arrivedAtDropoff,
  completed,
  cancelled;
  
  String get passengerDisplayName {
    switch (this) {
      case DeliveryStatus.pending:
        return 'Finding a delivery partner...';
      case DeliveryStatus.driverAssigned:
        return 'Driver assigned';
      case DeliveryStatus.pickupEnroute:
        return 'Driver coming for pickup';
      case DeliveryStatus.arrivedAtPickup:
        return 'Driver at pickup location';
      case DeliveryStatus.packagePicked:
        return 'Package picked up';
      case DeliveryStatus.deliveryEnroute:
        return 'Package on the way';
      case DeliveryStatus.arrivedAtDropoff:
        return 'Driver at delivery location';
      case DeliveryStatus.completed:
        return 'Delivery completed';
      case DeliveryStatus.cancelled:
        return 'Delivery cancelled';
    }
  }
}

class DeliveryRequest extends Equatable {
  final String id;
  final String passengerId;
  final String? driverId;
  final DeliveryStatus status;
  final GeoPoint pickupLocation;
  final GeoPoint dropoffLocation;
  final String pickupAddress;
  final String dropoffAddress;
  final String parcelType;
  final double weight;
  final bool isFragile;
  final bool requiresHelpers;
  final DateTime createdAt;
  final double totalFee;
  
  const DeliveryRequest({
    required this.id,
    required this.passengerId,
    this.driverId,
    required this.status,
    required this.pickupLocation,
    required this.dropoffLocation,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.parcelType,
    required this.weight,
    required this.isFragile,
    required this.requiresHelpers,
    required this.createdAt,
    required this.totalFee,
  });
  
  factory DeliveryRequest.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return DeliveryRequest(
      id: doc.id,
      passengerId: data['passengerId'],
      driverId: data['driverId'],
      status: DeliveryStatus.values.firstWhere((e) => e.toString() == data['status']),
      pickupLocation: data['pickupLocation'],
      dropoffLocation: data['dropoffLocation'],
      pickupAddress: data['pickupAddress'],
      dropoffAddress: data['dropoffAddress'],
      parcelType: data['parcelType'],
      weight: (data['weight'] as num).toDouble(),
      isFragile: data['isFragile'] ?? false,
      requiresHelpers: data['requiresHelpers'] ?? false,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      totalFee: (data['totalFee'] as num).toDouble(),
    );
  }
  
  @override
  List<Object?> get props => [id, passengerId, driverId, status, totalFee];
}