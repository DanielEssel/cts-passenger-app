import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../core/errors/location_exceptions.dart';

/// Production-grade location service for ride/delivery apps
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  // Broadcast stream for the entire app
  final StreamController<Position> _controller =
      StreamController<Position>.broadcast();

  StreamSubscription<Position>? _subscription;
  LatLng? _lastPosition;
  bool _isListening = false;

  /// Public stream
  Stream<Position> get positionStream => _controller.stream;

  // =========================================================
  // PLATFORM LOCATION SETTINGS (Geolocator v10+ compliant)
  // =========================================================
  static LocationSettings get _settings {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return  AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 10,
        intervalDuration: Duration(seconds: 3),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'CTS Go is tracking location',
          notificationText: 'Live tracking active',
          enableWakeLock: true,
        ),
      );
    }

    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return  AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 10,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
      );
    }

    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );
  }

  // =========================================================
  // PERMISSIONS
  // =========================================================
  Future<void> ensureLocationReady() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationServiceDisabledException();
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw LocationPermissionDeniedException();
    }

    if (permission == LocationPermission.deniedForever) {
      throw LocationPermissionPermanentlyDeniedException();
    }
  }

  // =========================================================
  // CURRENT LOCATION
  // =========================================================
  Future<Position> getCurrentLocation() async {
    await ensureLocationReady();

    // 1) Instant: last known fix — avoids the cold-start wait, prevents
    //    falling back to Accra while a fresh fix is still acquiring.
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
    } catch (_) {/* fall through to a fresh fix */}

    // 2) Fresh fix — `high` (not bestForNavigation) locks faster on a cold start.
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw Exception('Failed to get current location (timeout)');
    }
  }

  // =========================================================
  // START LIVE TRACKING
  // =========================================================
  Future<void> startListening({
    double minDistance = 25,
    Function(double distance)? onSignificantMove,
  }) async {
    if (_isListening) return;

    await ensureLocationReady();
    _isListening = true;

    _subscription = Geolocator.getPositionStream(
      locationSettings: _settings,
    ).listen((position) {
      final newPos = LatLng(position.latitude, position.longitude);

      // First location
      if (_lastPosition == null) {
        _lastPosition = newPos;
        _controller.add(position);
        return;
      }

      final distance = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        newPos.latitude,
        newPos.longitude,
      );

      if (distance >= minDistance) {
        _lastPosition = newPos;
        onSignificantMove?.call(distance);
        _controller.add(position);
      }
    });
  }

  // =========================================================
  // STOP LIVE TRACKING
  // =========================================================
  void stopListening() {
    _subscription?.cancel();
    _subscription = null;
    _lastPosition = null;
    _isListening = false;
  }

  // =========================================================
  // REVERSE GEOCODING
  // =========================================================
  Future<String> reverseGeocode(LatLng position) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isEmpty) return _coordsFallback(position);

      final p = placemarks.first;

      final parts = [
        p.street,
        p.subLocality,
        p.locality,
        p.administrativeArea,
      ].whereType<String>().where((e) => e.isNotEmpty);

      return parts.take(2).join(', ');
    } catch (e) {
      debugPrint('Reverse geocoding failed: $e');
      return _coordsFallback(position);
    }
  }

  String _coordsFallback(LatLng pos) =>
      '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';

  // =========================================================
  // CLEANUP
  // =========================================================
  void dispose() {
    stopListening();
    _controller.close();
  }
}