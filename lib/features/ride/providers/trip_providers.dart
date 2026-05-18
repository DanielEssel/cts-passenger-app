// lib/features/trip/providers/trip_providers.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/features/payment/models/payment_method.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../auth/providers/auth_providers.dart';
import '../models/trip_request.dart';
import '../models/service_type.dart';



part 'trip_providers.g.dart';

// ─────────────────────────────────────────────────
// COLLECTION CONSTANTS
// ─────────────────────────────────────────────────

abstract final class _Col {
  static const trips            = 'trips';
  static const driverAlerts     = 'driver_alerts';
  static const passengerWallets = 'passenger_wallets';
}

// ─────────────────────────────────────────────────
// ACTIVE TRIP STREAM PROVIDER
//
// Uses Ref (the base class) instead of the generated
// ActiveTripStreamRef so it compiles before build_runner runs.
// After generation both types are compatible — no change needed.
// ─────────────────────────────────────────────────

@riverpod
Stream<TripRequest?> activeTripStream(Ref ref) {
  // authStateProvider is StreamProvider<User?> → AsyncValue<User?>
  // .when() is available on all Riverpod versions; safer than .valueOrNull
  final User? user = ref.watch(authStateProvider).when(
    data:    (u) => u,
    loading: ()      => null,
    error:   (_, __) => null,
  );

  if (user == null) return const Stream.empty();

  return FirebaseFirestore.instance
      .collection(_Col.trips)
      .where('passengerId', isEqualTo: user.uid)
      .where('status', whereIn: [
        TripStatus.searching.name,
        TripStatus.pending.name,
        TripStatus.driverArrived.name,
        TripStatus.tripAccepted.name,
        TripStatus.tripStarted.name,
        TripStatus.inProgress.name,
      ])
      .orderBy('createdAt', descending: true)
      .limit(1)
      .snapshots()
      .map((snap) => snap.docs.isNotEmpty
          ? TripRequest.fromFirestore(snap.docs.first)
          : null);
}

// ─────────────────────────────────────────────────
// TRIP REQUEST MANAGER
// ─────────────────────────────────────────────────

@riverpod
class TripRequestManager extends _$TripRequestManager {
  String? _currentTripId;

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  @override
  FutureOr<void> build() {}

  // ── Helper — get current user or throw ────────

  User _requireUser() {
    // .when() works on all versions; avoids .valueOrNull version dependency
    final User? user = ref.read(authStateProvider).when(
      data:    (u) => u,
      loading: ()      => null,
      error:   (_, __) => null,
    );
    if (user == null) throw Exception('Passenger not authenticated');
    return user;
  }

  // ── Request a new trip ─────────────────────────

  Future<String> requestTrip({
    required GeoPoint      pickup,
    required GeoPoint      dropoff,
    required String        pickupAddress,
    required String        dropoffAddress,
    required ServiceType   serviceType,
    required PaymentType paymentMethod,
    double estimatedFare     = 0,
    double distance          = 0,
    int    estimatedDuration = 0,
  }) async {
    final user = _requireUser();

    final request = TripRequest(
      id:                '',
      passengerId:       user.uid,
      driverId:          null,
      serviceType:       serviceType,
      status:            TripStatus.searching,
      pickupLocation:    pickup,
      dropoffLocation:   dropoff,
      pickupAddress:     pickupAddress,
      dropoffAddress:    dropoffAddress,
      createdAt:         DateTime.now(),
      scheduledAt:       null,
      estimatedFare:     estimatedFare,
      actualFare:        null,
      distance:          distance,
      estimatedDuration: estimatedDuration,
      actualDuration:    null,
      promoCode:         null,
      discountAmount:    null,
      paymentMethod:     paymentMethod,
      isScheduled:       false,
      metadata:          const {},
    );

    final docRef = await _db
        .collection(_Col.trips)
        .add(request.toFirestore());

    _currentTripId = docRef.id;
    await _broadcastToDrivers(docRef.id, pickup, serviceType);
    return docRef.id;
  }

  // ── Broadcast to nearby drivers ────────────────

  Future<void> _broadcastToDrivers(
    String      tripId,
    GeoPoint    pickup,
    ServiceType serviceType,
  ) async {
    await _db.collection(_Col.driverAlerts).doc(tripId).set({
      'tripId':         tripId,
      'pickupLocation': pickup,
      'serviceType':    serviceType.name,
      'timestamp':      FieldValue.serverTimestamp(),
      'expiresAt':      Timestamp.fromDate(
                          DateTime.now().add(const Duration(seconds: 45))),
      'status':         'broadcasting',
    });
  }

  // ── Cancel ─────────────────────────────────────

  Future<void> cancelTrip(String tripId) async {
    await _db.collection(_Col.trips).doc(tripId).update({
      'status':      TripStatus.cancelled.name,
      'cancelledAt': FieldValue.serverTimestamp(),
      'cancelledBy': 'passenger',
    });
    _currentTripId = null;
  }

  // ── Confirm payment ────────────────────────────

  Future<void> confirmPayment(
    String        tripId,
    double        amount,
    PaymentType method,
  ) async {
    await _db.runTransaction((txn) async {
      final tripRef  = _db.collection(_Col.trips).doc(tripId);
      final tripSnap = await txn.get(tripRef);
      if (!tripSnap.exists) throw Exception('Trip not found');

      txn.update(tripRef, {
        'status':      TripStatus.completed.name,
        'actualFare':  amount,
        'completedAt': FieldValue.serverTimestamp(),
      });

      if (method == PaymentType.wallet) {
        final passengerId =
            tripSnap.data()!['passengerId'] as String? ?? '';
        txn.update(
          _db.collection(_Col.passengerWallets).doc(passengerId),
          {'balance': FieldValue.increment(-amount)},
        );
      }
    });

    _currentTripId = null;
  }

  // ── Read-only accessors ────────────────────────

  String? get currentTripId => _currentTripId;
}