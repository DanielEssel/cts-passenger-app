import 'dart:math' as math;
import 'package:flutter/animation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

double geoDistance(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = (b.latitude - a.latitude) * math.pi / 180;
  final dLng = (b.longitude - a.longitude) * math.pi / 180;
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(a.latitude * math.pi / 180) *
          math.cos(b.latitude * math.pi / 180) *
          math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

double geoBearing(LatLng a, LatLng b) {
  final p1 = a.latitude * math.pi / 180, p2 = b.latitude * math.pi / 180;
  final dl = (b.longitude - a.longitude) * math.pi / 180;
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) -
      math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

double _lerpAngle(double a, double b, double t) {
  final d = ((b - a + 540) % 360) - 180;
  return (a + d * t + 360) % 360;
}

class SmoothMarker {
  SmoothMarker({
    required TickerProvider vsync,
    required this.onFrame,
    Duration duration = const Duration(milliseconds: 1800),
  }) : _c = AnimationController(vsync: vsync, duration: duration) {
    _c.addListener(_tick);
  }

  final AnimationController _c;
  final void Function(LatLng position, double bearing) onFrame;

  LatLng? _from, _to, _current;
  double _bearing = 0, _fromBearing = 0, _toBearing = 0;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  LatLng? get position => _current;

  void moveTo(LatLng next, {double? heading}) {
    if (_current == null) {
      _from = _to = _current = next;
      _bearing = _fromBearing = _toBearing = heading ?? 0;
      onFrame(next, _bearing);
      return;
    }
    final meters = geoDistance(_current!, next);
    if (meters < 2) return; // ignore GPS jitter
    if (meters > 500) {
      // big gap (app resumed, long outage): snap instead of gliding across town
      _c.stop();
      _from = _to = _current = next;
      onFrame(next, _bearing);
      return;
    }
    _from = _current;
    _to = next;
    _fromBearing = _bearing;
    _toBearing = (heading != null && heading > 0)
        ? heading
        : geoBearing(_from!, next);
    _c.forward(from: 0);
  }

  void _tick() {
    final t = _c.value;
    final now = DateTime.now();
    if (t < 1 && now.difference(_lastEmit).inMilliseconds < 40) return;
    _lastEmit = now;
    final a = _from!, b = _to!;
    _current = LatLng(a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t);
    _bearing = _lerpAngle(_fromBearing, _toBearing, t);
    onFrame(_current!, _bearing);
  }

  void dispose() => _c.dispose();
}