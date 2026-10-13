// lib/core/utils/driver_location.dart
//
// Reads the assigned driver's live position from a delivery or gas order.
//
// The Driver App writes `driverCurrentLocation` (GeoPoint) on the order while
// a job is active. Older documents may only carry `driverLocation`. The
// current field wins when it is usable; anything that is not a usable
// GeoPoint is ignored rather than shown, so the map never displays a
// fabricated position.

import 'package:cloud_firestore/cloud_firestore.dart';

/// Returns the driver's position from [data], or null when none is usable.
GeoPoint? readDriverLocation(Map<String, dynamic> data) {
  return _usable(data['driverCurrentLocation']) ?? _usable(data['driverLocation']);
}

GeoPoint? _usable(Object? value) {
  if (value is! GeoPoint) return null;
  final lat = value.latitude;
  final lng = value.longitude;
  if (!lat.isFinite || !lng.isFinite) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  // (0, 0) is what an unset or failed GPS fix produces; never a real pickup
  // area for this service.
  if (lat == 0 && lng == 0) return null;
  return value;
}
