// features/ride/providers/drivers_nearby_provider.dart

import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../domain/ride_availability.dart';
import 'ride_request_provider.dart';

class NearbyDriver {
  final String id;
  final String name;
  final LatLng location;
  final String serviceType;

  const NearbyDriver({
    required this.id,
    required this.name,
    required this.location,
    required this.serviceType,
  });
}

// Passengers may not read drivers/{id}. Map markers come from driver_map,
// which the syncDriverMap function fills with only the rounded position and
// vehicle type of online, approved, available drivers.
const _driverMapCollection = 'driver_map';
const _radiusKm = 5.0;
const _rideServiceTypes = {'okada', 'taxi', 'pragyia'};

/// Converts driver_map documents within [_radiusKm] of [pickup] to markers.
List<NearbyDriver> nearbyDriversFrom(
  Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  GeoPoint pickup, {
  bool Function(String serviceType)? includeType,
}) {
  final result = <NearbyDriver>[];
  for (final doc in docs) {
    final data = doc.data();
    final loc = data['location'];
    if (loc is! GeoPoint) continue;
    final sType = data['serviceType'] as String? ?? '';
    if (includeType != null && !includeType(sType)) continue;
    final km = _haversineKm(
      pickup.latitude,
      pickup.longitude,
      loc.latitude,
      loc.longitude,
    );
    if (km > _radiusKm) continue;
    result.add(NearbyDriver(
      id: doc.id,
      name: 'Driver',
      location: LatLng(loc.latitude, loc.longitude),
      serviceType: sType,
    ));
  }
  return result;
}

// Streams ALL nearby ride-hailing drivers (okada + taxi + pragyia) within 5km
// Used for map markers — shows all available drivers
final driversNearbyProvider =
    StreamProvider.autoDispose<List<NearbyDriver>>((ref) {
  final pickup = ref.watch(
    rideRequestProvider.select((s) => s.pickupLocation),
  );

  if (pickup == null) return Stream.value(const []);

  return FirebaseFirestore.instance
      .collection(_driverMapCollection)
      .snapshots()
      .map((snap) => nearbyDriversFrom(
            snap.docs,
            pickup,
            includeType: _rideServiceTypes.contains,
          ));
});

// Streams drivers filtered by SELECTED service type
// Used for matching — only shows drivers matching passenger selection
final driversNearbyForTypeProvider = StreamProvider.autoDispose
    .family<List<NearbyDriver>, String>((ref, serviceType) {
  final pickup = ref.watch(
    rideRequestProvider.select((s) => s.pickupLocation),
  );

  if (pickup == null) return Stream.value(const []);

  return FirebaseFirestore.instance
      .collection(_driverMapCollection)
      .where('serviceType', isEqualTo: serviceType)
      .snapshots()
      .map((snap) => nearbyDriversFrom(snap.docs, pickup));
});

/// What a ride card shows for [serviceType]: computed from the same
/// driver_map stream as the map markers, so cards and markers always agree.
/// The count is a hint only; the backend's search decides the match.
({RideAvailability status, int count}) rideAvailabilityFrom(
  AsyncValue<List<NearbyDriver>> drivers,
  String serviceType,
) {
  if (drivers.hasValue) {
    final count =
        drivers.requireValue.where((d) => d.serviceType == serviceType).length;
    return (
      status: count > 0
          ? RideAvailability.available
          : RideAvailability.unavailable,
      count: count,
    );
  }
  if (drivers.hasError) {
    return (status: RideAvailability.checkFailed, count: 0);
  }
  return (status: RideAvailability.checking, count: 0);
}

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

double _rad(double deg) => deg * pi / 180;
