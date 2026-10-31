import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// One GPS publisher for the whole trip lifecycle. Screens only read
/// [position]; they never own the stream.
class TripTracker {
  TripTracker._();
  static final TripTracker instance = TripTracker._();

  final ValueNotifier<Position?> position = ValueNotifier(null);

  String? _tripId;
  StreamSubscription<Position>? _gps;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _statusSub;
  DateTime _lastWrite = DateTime.fromMillisecondsSinceEpoch(0);

  static const _terminal = {
    'completed',
    'cancelledByDriver',
    'cancelledByPassenger',
    'expired',
    'noDriversAvailable',
  };

  bool get isRunning => _gps != null;

  /// Returns null on success, or a message the UI can show.
  Future<String?> start(String tripId) async {
    if (_tripId == tripId && _gps != null) return null; // already tracking

    await stop();

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      return 'Location permission denied. Enable it in Settings.';
    }
    if (perm == LocationPermission.denied) {
      return 'Location permission is required.';
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Please enable location services.';
    }

    _tripId = tripId;

    // Show something immediately instead of waiting for the first GPS fix.
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) {
      position.value = last;
      _lastWrite = DateTime.now();
      unawaited(_write(last));
    }

    _gps = Geolocator.getPositionStream(locationSettings: _settings()).listen(
      _onPosition,
      onError: (Object e) => debugPrint('TripTracker GPS error: $e'),
    );

    // Self-managing: stop when the trip ends, whoever ends it.
    _statusSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(tripId)
        .snapshots()
        .listen((s) {
      final status = s.data()?['status'] as String?;
      if (status != null && _terminal.contains(status)) stop();
    });

    return null;
  }

  Future<void> stop() async {
    await _gps?.cancel();
    await _statusSub?.cancel();
    _gps = null;
    _statusSub = null;
    _tripId = null;
  }

  void _onPosition(Position p) {
    position.value = p;
    final now = DateTime.now();
    // Leading-edge throttle: always write the LATEST fix, at most every 2s.
    if (now.difference(_lastWrite).inMilliseconds < 2000) return;
    _lastWrite = now;
    _write(p);
  }

  Future<void> _write(Position p) async {
    final id = _tripId;
    if (id == null) return;
    try {
      await FirebaseFirestore.instance.collection('trips').doc(id).update({
        'driverCurrentLocation': GeoPoint(p.latitude, p.longitude),
        if (p.heading > 0) 'driverHeading': p.heading,
        'driverSpeed': p.speed,
        'lastLocationUpdate': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Never swallow: PERMISSION_DENIED here == frozen marker for the passenger.
      debugPrint('TripTracker write failed: $e');
    }
  }

  LocationSettings _settings() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
        intervalDuration: const Duration(seconds: 2),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'CTSGo',
          notificationText: 'Sharing your location for the active trip',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 3,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return const LocationSettings(
        accuracy: LocationAccuracy.high, distanceFilter: 3);
  }
}