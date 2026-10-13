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

  /// Bumped when icons finish loading. Map widgets can listen to this to
  /// redraw with the real icons instead of the fallback pins.
  final ValueNotifier<int> revision = ValueNotifier(0);

  static const _assets = <String, String>{
    'motorbike': 'assets/markers/marker_motorbike.png',
    'taxi': 'assets/markers/marker_taxi.png',
    'tricycle': 'assets/markers/marker_tricycle.png',
    'minitruck': 'assets/markers/marker_minitruck.png',
    'pickup': 'assets/markers/pin_pickup.png',
    'dropoff': 'assets/markers/pin_dropoff.png',
  };

  /// Logical display width (dp) per icon. Without an explicit size,
  /// BitmapDescriptor.bytes renders at the PNG's raw pixel size, which looks
  /// huge or tiny depending on the asset. Tune these two numbers to taste.
  /// (If your google_maps_flutter version rejects `width:`, use
  /// `imagePixelRatio:` instead, e.g. 3.0 for a @3x asset.)
  static const double _vehicleWidth = 44;
  static const double _pinWidth = 36;

  Future<void>? _warming;

  // Shared future: concurrent callers (e.g. booking screen pre-warm + the
  // tracking screen opening) await the same load instead of decoding the
  // assets twice, and a second caller no longer returns before icons exist.
  Future<void> warmUp(BuildContext context) => _warming ??= _load();

  Future<void> _load() async {
    if (_warmed) return;
    final failed = <String>[];
    for (final e in _assets.entries) {
      try {
        final data = await rootBundle.load(e.value);
        if (data.lengthInBytes == 0) {
          failed.add(e.key);
          continue;
        }
        final bytes = data.buffer.asUint8List();
        final isPin = e.key == 'pickup' || e.key == 'dropoff';
        _cache[e.key] = BitmapDescriptor.bytes(
          bytes,
          width: isPin ? _pinWidth : _vehicleWidth,
        );
      } catch (err) {
        // missing/bad asset -> fallback used, but say so loudly
        failed.add(e.key);
        debugPrint('❌ Failed to load marker "${e.key}" from ${e.value}: $err');
      }
    }
    _warmed = true;
    debugPrint('MarkerService warmed up. Cached: ${_cache.keys.toList()}'
        '${failed.isEmpty ? '' : ' | MISSING: $failed (check pubspec assets)'}');
    revision.value++;
  }

  BitmapDescriptor vehicle(String? type) {
    final key = _vehicleKey(type);
    // Honest fallback: a plain pin, not a different vehicle (a taxi showing
    // as a motorbike would look like a wrong-vehicle bug).
    return _cache[key] ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
  }

  String _vehicleKey(String? type) {
    switch ((type ?? '').toLowerCase().trim()) {
      case 'okada':
      case 'motorbike':
      case 'motorcycle':
      case 'delivery':
      case 'gas':
        return 'motorbike';
      case 'taxi':
        return 'taxi';
      case 'aboboyaa':
      case 'aboboya':
      case 'tricycle':
      case 'pragyia':
      case 'pragya':
      case 'pragia':
        return 'tricycle';
      case 'minitruck':
      case 'mini_truck':
      case 'mini truck':
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