// lib/features/delivery/models/delivery_request.dart

import 'package:cloud_firestore/cloud_firestore.dart';

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

  String get firestoreValue => name;

  static DeliveryStatus fromFirestore(String value) =>
      DeliveryStatus.values.firstWhere(
        (e) => e.name == value,
        orElse: () => DeliveryStatus.pending,
      );

  String get passengerDisplayName => switch (this) {
        DeliveryStatus.pending          => 'Finding a delivery partner…',
        DeliveryStatus.driverAssigned   => 'Driver assigned',
        DeliveryStatus.pickupEnroute    => 'Driver heading to pickup',
        DeliveryStatus.arrivedAtPickup  => 'Driver at pickup location',
        DeliveryStatus.packagePicked    => 'Package picked up',
        DeliveryStatus.deliveryEnroute  => 'Package on the way',
        DeliveryStatus.arrivedAtDropoff => 'Driver at drop-off',
        DeliveryStatus.completed        => 'Delivery completed',
        DeliveryStatus.cancelled        => 'Delivery cancelled',
      };

  bool get isActive => switch (this) {
        DeliveryStatus.completed  => false,
        DeliveryStatus.cancelled  => false,
        _                         => true,
      };
}

class DeliveryRequest {
  final String         id;
  final String         passengerId;
  final String?        driverId;
  final String?        driverName;
  final String?        driverPhone;
  final double?        driverRating;
  final DeliveryStatus status;

  // Locations
  final GeoPoint pickupLocation;
  final GeoPoint dropoffLocation;
  final String   pickupAddress;
  final String   dropoffAddress;

  // Parcel
  final String  parcelType;
  final String  weightTier;
  final String  weightRange;
  final bool    isFragile;
  final bool    requiresHelpers;
  final String? photoUrl;
  final String? notes;

  // Vehicle
  final String vehicleType;

  // Receiver
  final String? receiverPhone;
  final String? receiverName;

  // Pricing
  final double estimatedFare;
  final double? actualFare;

  // Timestamps
  final DateTime  createdAt;
  final DateTime? assignedAt;
  final DateTime? pickedUpAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;

  // Payment
  final String paymentMethod;

  // Rating
  final double? passengerRating;

  const DeliveryRequest({
    required this.id,
    required this.passengerId,
    this.driverId,
    this.driverName,
    this.driverPhone,
    this.driverRating,
    required this.status,
    required this.pickupLocation,
    required this.dropoffLocation,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.parcelType,
    required this.weightTier,
    required this.weightRange,
    required this.isFragile,
    required this.requiresHelpers,
    this.photoUrl,
    this.notes,
    required this.vehicleType,
    this.receiverPhone,
    this.receiverName,
    required this.estimatedFare,
    this.actualFare,
    required this.createdAt,
    this.assignedAt,
    this.pickedUpAt,
    this.completedAt,
    this.cancelledAt,
    required this.paymentMethod,
    this.passengerRating,
  });

  factory DeliveryRequest.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return DeliveryRequest(
      id:             doc.id,
      passengerId:    d['passengerId']  as String,
      driverId:       d['driverId']     as String?,
      driverName:     d['driverName']   as String?,
      driverPhone:    d['driverPhone']  as String?,
      driverRating:   (d['driverRating'] as num?)?.toDouble(),
      status:         DeliveryStatus.fromFirestore(
                          d['status'] as String? ?? 'pending'),
      pickupLocation:  d['pickupLocation']  as GeoPoint,
      dropoffLocation: d['dropoffLocation'] as GeoPoint,
      pickupAddress:   d['pickupAddress']   as String,
      dropoffAddress:  d['dropoffAddress']  as String,
      parcelType:      d['parcelType']      as String,
      weightTier:      d['weightTier']      as String,
      weightRange:     d['weightRange']     as String,
      isFragile:       d['isFragile']       as bool? ?? false,
      requiresHelpers: d['requiresHelpers'] as bool? ?? false,
      photoUrl:        d['photoUrl']        as String?,
      notes:           d['notes']           as String?,
      vehicleType:     d['vehicleType']     as String,
      receiverPhone:   d['receiverPhone']   as String?,
      receiverName:    d['receiverName']    as String?,
      estimatedFare:   (d['estimatedFare']  as num).toDouble(),
      actualFare:      (d['actualFare']     as num?)?.toDouble(),
      createdAt:       (d['createdAt']      as Timestamp).toDate(),
      assignedAt:      (d['assignedAt']     as Timestamp?)?.toDate(),
      pickedUpAt:      (d['pickedUpAt']     as Timestamp?)?.toDate(),
      completedAt:     (d['completedAt']    as Timestamp?)?.toDate(),
      cancelledAt:     (d['cancelledAt']    as Timestamp?)?.toDate(),
      paymentMethod:   d['paymentMethod']   as String? ?? 'wallet',
      passengerRating: (d['passengerRating'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toFirestore() => {
    'passengerId':    passengerId,
    'driverId':       driverId,
    'driverName':     driverName,
    'driverPhone':    driverPhone,
    'driverRating':   driverRating,
    'status':         status.firestoreValue,
    'pickupLocation':  pickupLocation,
    'dropoffLocation': dropoffLocation,
    'pickupAddress':   pickupAddress,
    'dropoffAddress':  dropoffAddress,
    'parcelType':      parcelType,
    'weightTier':      weightTier,
    'weightRange':     weightRange,
    'isFragile':       isFragile,
    'requiresHelpers': requiresHelpers,
    'photoUrl':        photoUrl,
    'notes':           notes,
    'vehicleType':     vehicleType,
    'receiverPhone':   receiverPhone,
    'receiverName':    receiverName,
    'estimatedFare':   estimatedFare,
    'actualFare':      actualFare,
    'createdAt':       FieldValue.serverTimestamp(),
    'assignedAt':      null,
    'pickedUpAt':      null,
    'completedAt':     null,
    'cancelledAt':     null,
    'paymentMethod':   paymentMethod,
    'passengerRating': passengerRating,
  };
}