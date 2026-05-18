// features/ride/services/route_service.dart
//
// ✅ Fetches a real road route from Google Directions API
// ✅ Decodes the encoded polyline into LatLng points
// ✅ Returns distance (metres) and duration (seconds) for fare calculation
// ✅ API key injected via --dart-define=MAPS_API_KEY=YOUR_KEY
// ✅ Riverpod provider for DI + testability

import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

const _apiKey = String.fromEnvironment('MAPS_API_KEY');

class RouteResult {
  final List<LatLng> points;
  final double distanceKm;
  final int durationMin;

  const RouteResult({
    required this.points,
    required this.distanceKm,
    required this.durationMin,
  });
}

class RouteService {
  final http.Client _client;
  RouteService({http.Client? client}) : _client = client ?? http.Client();

  Future<RouteResult?> getRoute(LatLng origin, LatLng destination) async {
    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/directions/json',
      {
        'origin': '${origin.latitude},${origin.longitude}',
        'destination':
            '${destination.latitude},${destination.longitude}',
        'key': _apiKey,
        'mode': 'driving',
      },
    );

    try {
      final response = await _client.get(uri);
      if (response.statusCode != 200) return null;

      final body = json.decode(response.body) as Map<String, dynamic>;
      if (body['status'] != 'OK') return null;

      final route =
          (body['routes'] as List).first as Map<String, dynamic>;
      final leg =
          (route['legs'] as List).first as Map<String, dynamic>;

      final distanceM =
          (leg['distance']['value'] as num).toDouble();
      final durationS =
          (leg['duration']['value'] as num).toInt();

      final encoded =
          route['overview_polyline']['points'] as String;
      final points = _decodePolyline(encoded);

      return RouteResult(
        points: points,
        distanceKm: distanceM / 1000,
        durationMin: (durationS / 60).ceil(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Google's encoded polyline algorithm decoder.
  List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      int shift = 0;
      int result = 0;
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }

    return points;
  }
}

final routeServiceProvider = Provider<RouteService>(
  (_) => RouteService(),
);