// lib/features/ride/models/trip_request.dart
//
// CANONICAL trip model. This is the single source of truth.
// Delete features/trip/models/trip_request.dart and repoint imports here.
//
// Wire format is unchanged from the previous version EXCEPT that passenger
// identity fields (passengerName / passengerPhotoUrl / passengerRating) are
// now actually written and read. They were declared but silently dropped
// before, which is why drivers saw blank passenger info.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/features/payment/models/payment_method.dart';
import 'package:equatable/equatable.dart';
import 'service_type.dart';

// ─────────────────────────────────────────────────
// TRIP STATUS
//
// NOTE: values kept exactly as before for wire compatibility. The lifecycle
// has known redundancy (pending≈tripAccepted, tripStarted≈inProgress) — that
// is a deliberate, separate migration that needs driver-app coordination, so
// it is intentionally NOT changed here.
// ─────────────────────────────────────────────────

enum TripStatus {
  searching,
  pending,
  driverArrived,
  tripAccepted,
  tripStarted,
  inProgress,
  completed,
  cancelled,
  noDrivers;

  String get passengerDisplayName => switch (this) {
        TripStatus.searching     => 'Finding a driver...',
        TripStatus.pending       => 'Driver on the way',
        TripStatus.driverArrived => 'Driver has arrived',
        TripStatus.tripAccepted  => 'Trip accepted',
        TripStatus.tripStarted   => 'Trip started',
        TripStatus.inProgress    => 'On your trip',
        TripStatus.completed     => 'Trip completed',
        TripStatus.cancelled     => 'Trip cancelled',
        TripStatus.noDrivers     => 'No drivers available',
      };

  /// True while the trip is live (not finished/abandoned).
  bool get isActive => activeStatuses.contains(this);

  /// SINGLE source of truth for "active" status queries.
  /// Use this everywhere instead of hand-written whereIn lists, so the lists
  /// can never drift or contain duplicates again.
  static const List<TripStatus> activeStatuses = [
    TripStatus.searching,
    TripStatus.pending,
    TripStatus.tripAccepted,
    TripStatus.driverArrived,
    TripStatus.tripStarted,
    TripStatus.inProgress,
  ];

  /// Convenience for Firestore `whereIn` clauses.
  static List<String> get activeStatusNames =>
      activeStatuses.map((s) => s.name).toList();
}

// ─────────────────────────────────────────────────
// ENUM PARSERS
// ─────────────────────────────────────────────────

ServiceType _serviceTypeFromString(String? value) {
  if (value == null) return ServiceType.taxi;
  return ServiceType.values.firstWhere(
    (e) => e.name == value,
    orElse: () => ServiceType.taxi,
  );
}

TripStatus _tripStatusFromString(String? value) {
  if (value == null) return TripStatus.searching;
  return TripStatus.values.firstWhere(
    (e) => e.name == value,
    orElse: () => TripStatus.searching,
  );
}

PaymentType _paymentMethodFromString(String? value) {
  if (value == null) return PaymentType.cash;
  return PaymentType.values.firstWhere(
    (e) => e.name == value,
    orElse: () => PaymentType.cash,
  );
}

// ─────────────────────────────────────────────────
// MODEL
// ─────────────────────────────────────────────────

class TripRequest extends Equatable {
  final String id;
  final String passengerId;
  final String passengerName;
  final String passengerPhotoUrl;
  final double passengerRating;
  final String? driverId;
  final ServiceType serviceType;
  final TripStatus status;
  final GeoPoint pickupLocation;
  final GeoPoint dropoffLocation;
  final String pickupAddress;
  final String dropoffAddress;
  final DateTime createdAt;
  final DateTime? scheduledAt;
  final double estimatedFare;
  final double? actualFare;
  final double distance;
  final int estimatedDuration;
  final int? actualDuration;
  final String? promoCode;
  final double? discountAmount;
  final PaymentType paymentMethod;
  final bool isScheduled;
  final String? escrowId;
  final Map<String, dynamic> metadata;

  const TripRequest({
    required this.id,
    required this.passengerId,
    this.passengerName = '',
    this.passengerPhotoUrl = '',
    this.passengerRating = 5.0,
    this.driverId,
    required this.serviceType,
    required this.status,
    required this.pickupLocation,
    required this.dropoffLocation,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.createdAt,
    this.scheduledAt,
    required this.estimatedFare,
    this.actualFare,
    required this.distance,
    required this.estimatedDuration,
    this.actualDuration,
    this.promoCode,
    this.discountAmount,
    required this.paymentMethod,
    required this.isScheduled,
    this.escrowId,
    required this.metadata,
  });

  // ── Firestore ────────────────────────────────────

  factory TripRequest.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;

    return TripRequest(
      id:                doc.id,
      passengerId:       d['passengerId'] as String? ?? '',
      // ✅ now actually read back
      passengerName:     d['passengerName'] as String? ?? '',
      passengerPhotoUrl: d['passengerPhotoUrl'] as String? ?? '',
      passengerRating:   (d['passengerRating'] as num?)?.toDouble() ?? 5.0,
      driverId:          d['driverId'] as String?,
      serviceType:       _serviceTypeFromString(d['serviceType'] as String?),
      status:            _tripStatusFromString(d['status'] as String?),
      pickupLocation:    d['pickupLocation'] as GeoPoint,
      dropoffLocation:   d['dropoffLocation'] as GeoPoint,
      pickupAddress:     d['pickupAddress'] as String? ?? '',
      dropoffAddress:    d['dropoffAddress'] as String? ?? '',
      createdAt:         (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      scheduledAt:       (d['scheduledAt'] as Timestamp?)?.toDate(),
      estimatedFare:     (d['estimatedFare'] as num?)?.toDouble() ?? 0.0,
      actualFare:        (d['actualFare'] as num?)?.toDouble(),
      distance:          (d['distance'] as num?)?.toDouble() ?? 0.0,
      estimatedDuration: (d['estimatedDuration'] as num?)?.toInt() ?? 0,
      actualDuration:    (d['actualDuration'] as num?)?.toInt(),
      promoCode:         d['promoCode'] as String?,
      discountAmount:    (d['discountAmount'] as num?)?.toDouble(),
      paymentMethod:     _paymentMethodFromString(d['paymentMethod'] as String?),
      isScheduled:       d['isScheduled'] as bool? ?? false,
      escrowId:          d['escrowId'] as String?, // ✅ now read back
      metadata:          Map<String, dynamic>.from(d['metadata'] as Map? ?? {}),
    );
  }

  /// For CREATE only. `id` is intentionally not written (it equals doc.id).
  /// Server-authored fields (actualFare, completedAt, cancelledAt) must NOT be
  /// set here — they are written by Cloud Functions / restricted update paths.
  Map<String, dynamic> toFirestore() => {
        'passengerId':       passengerId,
        // ✅ now actually written, so drivers see who they're picking up
        'passengerName':     passengerName,
        'passengerPhotoUrl': passengerPhotoUrl,
        'passengerRating':   passengerRating,
        'driverId':          driverId,
        'serviceType':       serviceType.name,
        'status':            status.name,
        'pickupLocation':    pickupLocation,
        'dropoffLocation':   dropoffLocation,
        'pickupAddress':     pickupAddress,
        'dropoffAddress':    dropoffAddress,
        'createdAt':         FieldValue.serverTimestamp(),
        'scheduledAt':
            scheduledAt != null ? Timestamp.fromDate(scheduledAt!) : null,
        'estimatedFare':     estimatedFare,
        'actualFare':        actualFare, // null on create; rules forbid setting it
        'distance':          distance,
        'estimatedDuration': estimatedDuration,
        'actualDuration':    actualDuration,
        'promoCode':         promoCode,
        'discountAmount':    discountAmount,
        'paymentMethod':     paymentMethod.name,
        'isScheduled':       isScheduled,
        'metadata':          metadata,
        'escrowId':          escrowId,
      };

  // ── copyWith ─────────────────────────────────────

  TripRequest copyWith({
    String? id,
    String? passengerId,
    String? passengerName,
    String? passengerPhotoUrl,
    double? passengerRating,
    String? driverId,
    ServiceType? serviceType,
    TripStatus? status,
    GeoPoint? pickupLocation,
    GeoPoint? dropoffLocation,
    String? pickupAddress,
    String? dropoffAddress,
    DateTime? createdAt,
    DateTime? scheduledAt,
    double? estimatedFare,
    double? actualFare,
    double? distance,
    int? estimatedDuration,
    int? actualDuration,
    String? promoCode,
    double? discountAmount,
    PaymentType? paymentMethod,
    bool? isScheduled,
    String? escrowId,
    Map<String, dynamic>? metadata,
  }) =>
      TripRequest(
        id:                id ?? this.id,
        passengerId:       passengerId ?? this.passengerId,
        passengerName:     passengerName ?? this.passengerName,
        passengerPhotoUrl: passengerPhotoUrl ?? this.passengerPhotoUrl,
        passengerRating:   passengerRating ?? this.passengerRating,
        driverId:          driverId ?? this.driverId,
        serviceType:       serviceType ?? this.serviceType,
        status:            status ?? this.status,
        pickupLocation:    pickupLocation ?? this.pickupLocation,
        dropoffLocation:   dropoffLocation ?? this.dropoffLocation,
        pickupAddress:     pickupAddress ?? this.pickupAddress,
        dropoffAddress:    dropoffAddress ?? this.dropoffAddress,
        createdAt:         createdAt ?? this.createdAt,
        scheduledAt:       scheduledAt ?? this.scheduledAt,
        estimatedFare:     estimatedFare ?? this.estimatedFare,
        actualFare:        actualFare ?? this.actualFare,
        distance:          distance ?? this.distance,
        estimatedDuration: estimatedDuration ?? this.estimatedDuration,
        actualDuration:    actualDuration ?? this.actualDuration,
        promoCode:         promoCode ?? this.promoCode,
        discountAmount:    discountAmount ?? this.discountAmount,
        paymentMethod:     paymentMethod ?? this.paymentMethod,
        isScheduled:       isScheduled ?? this.isScheduled,
        escrowId:          escrowId ?? this.escrowId,
        metadata:          metadata ?? this.metadata,
      );

  // ── Equatable ────────────────────────────────────

  @override
  List<Object?> get props => [
        id,
        passengerId,
        passengerName,
        passengerPhotoUrl,
        passengerRating,
        driverId,
        serviceType,
        status,
        pickupLocation,
        dropoffLocation,
        pickupAddress,
        dropoffAddress,
        createdAt,
        scheduledAt,
        estimatedFare,
        actualFare,
        distance,
        estimatedDuration,
        actualDuration,
        promoCode,
        discountAmount,
        paymentMethod,
        isScheduled,
        escrowId,
        metadata,
      ];
}