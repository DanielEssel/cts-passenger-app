// lib/core/services/marker_service.dart
//
// Loads & caches custom map marker BitmapDescriptors once.
// Falls back to colored markers for any asset not yet added.
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class MarkerService {
  MarkerService._();
  static final MarkerService instance = MarkerService._();

  final Map<String, BitmapDescriptor> _cache = {};
  bool _warmed = false;

  static const _assets = <String, String>{
    'motorbike': 'assets/markers/marker_motorbike.png',
    'taxi':      'assets/markers/marker_taxi.png',
    'tricycle':  'assets/markers/marker_tricycle.png',
    'minitruck': 'assets/markers/marker_minitruck.png',
    'pickup':    'assets/markers/pin_pickup.png',
    'dropoff':   'assets/markers/pin_dropoff.png',
  };

 Future<void> warmUp(BuildContext context) async {
    if (_warmed) return;
    for (final e in _assets.entries) {
      try {
        final data = await rootBundle.load(e.value);
        if (data.lengthInBytes == 0) continue;
        final bytes = data.buffer.asUint8List();
        // BitmapDescriptor.bytes is the most reliable across SDK versions
        _cache[e.key] = BitmapDescriptor.bytes(bytes);
      } catch (_) {
        // missing/bad asset -> fallback used
      }
    }
    _warmed = true;
  }

  BitmapDescriptor vehicle(String? type) {
    final key = _vehicleKey(type);
    return _cache[key] ??
        _cache['motorbike'] ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
  }

  String _vehicleKey(String? type) {
    switch ((type ?? '').toLowerCase()) {
      case 'okada':
      case 'motorbike':
      case 'motorcycle':
      case 'delivery':
      case 'gas':
        return 'motorbike';
      case 'taxi':
        return 'taxi';
      case 'aboboyaa':
      case 'tricycle':
      case 'pragyia':
        return 'tricycle';
      case 'minitruck':
      case 'mini_truck':
        return 'minitruck';
      default:
        return 'motorbike';
    }
  }

  BitmapDescriptor pickup() =>
      _cache['pickup'] ??
      BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);

  BitmapDescriptor dropoff() =>
      _cache['dropoff'] ??
      BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
}