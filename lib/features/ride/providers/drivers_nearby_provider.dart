// features/ride/providers/drivers_nearby_provider.dart

import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
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

// Add serviceType filter — only taxi and okada for ride hailing
final driversNearbyProvider =
    StreamProvider.autoDispose<List<NearbyDriver>>((ref) {
  final pickup = ref.watch(
    rideRequestProvider.select((s) => s.pickupLocation),
  );

  if (pickup == null) return Stream.value(const []);

  return FirebaseFirestore.instance
      .collection('drivers')
      .where('isOnline',    isEqualTo: true)
      .where('isApproved',  isEqualTo: true)
      .snapshots()
      .map((snap) {
        const radiusKm = 5.0;
        return snap.docs
            .where((doc) {
              // Support both 'location' and 'currentLocation' field names
              final loc = doc.data()['location'] ?? doc.data()['currentLocation'];
              if (loc is! GeoPoint) return false;
              return _haversineKm(
                    pickup.latitude,
                    pickup.longitude,
                    loc.latitude,
                    loc.longitude,
                  ) <= radiusKm;
            })
            .map((doc) {
              final data = doc.data();
              final loc  = data['location'] as GeoPoint;
              return NearbyDriver(
                id:          doc.id,
                name:        data['displayName'] as String? ??
                             data['name']        as String? ?? 'Driver',
                location:    LatLng(loc.latitude, loc.longitude),
                serviceType: data['serviceType'] as String? ?? 'taxi',
              );
            })
            .toList();
      });
});

// Add to drivers_nearby_provider.dart

// Count per service type
final driversNearbyByTypeProvider =
    StreamProvider.autoDispose
        .family<int, String>((ref, serviceType) {
  final all = ref.watch(driversNearbyProvider);
  return all.when(
    data: (drivers) => Stream.value(
      drivers.where((d) => d.serviceType == serviceType).length,
    ),
    loading: () => Stream.value(0),
    error:   (_, __) => Stream.value(0),
  );
});

double _haversineKm(
    double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

double _rad(double deg) => deg * pi / 180;