// lib/features/bookings/service_request_manager.dart

import 'package:cts_transport_app/features/payment/models/payment_method.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:cts_transport_app/features/ride/models/trip_request.dart';
import 'package:cts_transport_app/features/delivery/models/delivery_request.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/auth/providers/auth_providers.dart';
import '../ride/models/service_type.dart';


part 'service_request_manager.g.dart';


// ── Active service request provider (codegen) ─────────────────────────────────

@riverpod
class ActiveServiceRequest extends _$ActiveServiceRequest {
  @override
  Stream<ServiceRequestWrapper?> build() {
    final passenger = ref.watch(authStateProvider).value;
    if (passenger == null) return Stream.value(null);

    final tripsStream = FirebaseFirestore.instance
        .collection('trips')
        .where('passengerId', isEqualTo: passenger.uid)
        .where('status', whereIn: _activeTripStatuses)
        .snapshots();

    return tripsStream.asyncMap((tripsSnapshot) async {
      if (tripsSnapshot.docs.isNotEmpty) {
        return ServiceRequestWrapper.trip(
          TripRequest.fromFirestore(tripsSnapshot.docs.first),
        );
      }

      final deliveriesSnapshot = await FirebaseFirestore.instance
          .collection('deliveries')
          .where('passengerId', isEqualTo: passenger.uid)
          .where('status', whereIn: _activeDeliveryStatuses)
          .limit(1)
          .get();

      if (deliveriesSnapshot.docs.isNotEmpty) {
        return ServiceRequestWrapper.delivery(
          DeliveryRequest.fromFirestore(deliveriesSnapshot.docs.first),
        );
      }

      final gasSnapshot = await FirebaseFirestore.instance
          .collection('gas_orders')
          .where('passengerId', isEqualTo: passenger.uid)
          .where('status', whereIn: _activeGasStatuses)
          .limit(1)
          .get();

      if (gasSnapshot.docs.isNotEmpty) {
        return ServiceRequestWrapper.gasRefill(
          GasRefillRequest.fromFirestore(gasSnapshot.docs.first),
        );
      }

      return null;
    });
  }

  // ── Status lists — use .name to match Firestore strings ──────────────────
  static const _activeTripStatuses = [
    'searching',
    'pending',
    'driverArrived',
    'inProgress',
    'tripAccepted',
    'driverArrived',
    'tripStarted',
  ];

  static const _activeDeliveryStatuses = [
    'pending',
    'driverAssigned',
    'pickupEnroute',
    'arrivedAtPickup',
    'packagePicked',
    'deliveryEnroute',
    'arrivedAtDropoff',
  ];

  static const _activeGasStatuses = [
    'searchingDriver',
    'driverAssigned',
    'pickupEnroute',
    'cylinderPicked',
    'enrouteToStation',
    'refilling',
    'deliveryEnroute',
  ];
}

// ── Sealed wrapper ────────────────────────────────────────────────────────────

sealed class ServiceRequestWrapper {
  final String id;
  final String serviceType;

  const ServiceRequestWrapper({
    required this.id,
    required this.serviceType,
  });

  factory ServiceRequestWrapper.trip(TripRequest trip) = TripRequestWrapper;
  factory ServiceRequestWrapper.delivery(DeliveryRequest delivery) = DeliveryRequestWrapper;
  factory ServiceRequestWrapper.gasRefill(GasRefillRequest gasRefill) = GasRefillRequestWrapper;

  String get statusDisplayName => switch (this) {
        TripRequestWrapper(:final request) =>
          request.status.passengerDisplayName,
        DeliveryRequestWrapper(:final request) =>
          request.status.passengerDisplayName,
        GasRefillRequestWrapper(:final request) =>
          request.status.passengerDisplayName,
      };
}

class TripRequestWrapper extends ServiceRequestWrapper {
  final TripRequest request;

  TripRequestWrapper(this.request)
      : super(id: request.id, serviceType: 'trip');
}

class DeliveryRequestWrapper extends ServiceRequestWrapper {
  final DeliveryRequest request;

  DeliveryRequestWrapper(this.request)
      : super(id: request.id, serviceType: 'delivery');
}

class GasRefillRequestWrapper extends ServiceRequestWrapper {
  final GasRefillRequest request;

  GasRefillRequestWrapper(this.request)
      : super(id: request.id, serviceType: 'gas');
}

// ── Trip request creator (manual provider — no codegen needed) ────────────────

class TripRequestCreator extends Notifier<void> {
  @override
  void build() {}

  Future<String> createTripRequest({
    required ServiceType serviceType,   // ✅ matches trip_request.dart
    required String pickupAddress,
    required String dropoffAddress,
    required GeoPoint pickupLocation,
    required GeoPoint dropoffLocation,
    required double estimatedDistance,  // mapped to 'distance' in model
    required int estimatedDuration,
    required double estimatedFare,
    required PaymentType paymentMethod,
    String? promoCode,
    String? escrowId,
  }) async {
    final passenger = ref.read(authStateProvider).value;
    if (passenger == null) throw Exception('Not authenticated');

    final tripRequest = TripRequest(
  id: '',
  passengerId: passenger.uid,
  driverId: null,
  serviceType: serviceType,
  status: TripStatus.searching,
  pickupLocation: pickupLocation,
  dropoffLocation: dropoffLocation,
  pickupAddress: pickupAddress,
  dropoffAddress: dropoffAddress,
  createdAt: DateTime.now(),
  scheduledAt: null,
  estimatedFare: estimatedFare,
  actualFare: null,
  distance: estimatedDistance,
  estimatedDuration: estimatedDuration,
  actualDuration: null,
  promoCode: promoCode,
  discountAmount: null,
  paymentMethod: paymentMethod,
  isScheduled: false,
  metadata: const {},
  escrowId: escrowId,

);

    final docRef = await FirebaseFirestore.instance
        .collection('trips')
        .add(tripRequest.toFirestore());

    await _broadcastToDrivers(docRef.id, pickupLocation, serviceType);

    return docRef.id;
  }

  Future<void> _broadcastToDrivers(
    String tripId,
    GeoPoint pickup,
    ServiceType serviceType,
  ) async {
    await FirebaseFirestore.instance
        .collection('driver_alerts')
        .doc(tripId)
        .set({
      'tripId':      tripId,
      'pickupLat':   pickup.latitude,   // ← plain numbers avoid GeoPoint bug
      'pickupLng':   pickup.longitude,
      'serviceType': serviceType.name,
      'timestamp':   FieldValue.serverTimestamp(),
      'expiresAt':   Timestamp.fromDate(
                       DateTime.now().add(const Duration(seconds: 120))),
      'status':      'broadcasting',
    });
  }
}

final tripRequestCreatorProvider =
    NotifierProvider<TripRequestCreator, void>(TripRequestCreator.new);