

/// Thrown when user denies permission
class LocationPermissionDeniedException implements Exception {
  @override
  String toString() => 'Location permission was denied.';
}

/// Thrown when user selected "Never ask again"
class LocationPermissionPermanentlyDeniedException implements Exception {
  @override
  String toString() =>
      'Location permission permanently denied. Please enable it from app settings.';
}