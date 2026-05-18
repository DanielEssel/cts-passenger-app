// features/ride/repositories/google_places_repository.dart
//
// Uses Places API (New) — POST-based JSON API, not the legacy query-param API.
// Requires: http package
// Enable in Google Cloud Console: "Places API (New)"
//
// Run with: flutter run --dart-define=PLACES_API_KEY=YOUR_KEY

import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/place_result.dart';
import 'place_repository.dart';

const String _apiKey = String.fromEnvironment('PLACES_API_KEY');

// Bias results toward Accra
const double _biasLat = 5.6037;
const double _biasLng = -0.1870;
const int _biasRadiusMeters = 50000;

class GooglePlacesRepository implements PlaceRepository {
  final http.Client _client;

  GooglePlacesRepository({http.Client? client})
      : _client = client ?? http.Client();

  // ── Recent / Popular — from Firestore, not Places API ─────────────────────

  @override
  Future<List<PlaceResult>> getRecentPlaces() async => const [];

  @override
  Future<List<PlaceResult>> getPopularPlaces() async =>
      StubPlaceRepository().getPopularPlaces();

  // ── Live search ────────────────────────────────────────────────────────────

  @override
  Future<List<PlaceResult>> search(String query) async {
    if (query.trim().isEmpty) return const [];

    final suggestions = await _autocomplete(query);
    if (suggestions.isEmpty) return const [];

    final results = await Future.wait(
      suggestions.map((s) => _fetchDetails(s)),
    );

    return results.whereType<PlaceResult>().toList();
  }

  // ── Autocomplete (New) ─────────────────────────────────────────────────────
  // POST https://places.googleapis.com/v1/places:autocomplete

  Future<List<_AutocompleteSuggestion>> _autocomplete(String input) async {
    final uri = Uri.https(
      'places.googleapis.com',
      '/v1/places:autocomplete',
    );

    final body = json.encode({
      'input': input,
      'languageCode': 'en',
      'includedRegionCodes': ['gh'],
      'locationBias': {
        'circle': {
          'center': {'latitude': _biasLat, 'longitude': _biasLng},
          'radius': _biasRadiusMeters.toDouble(),
        },
      },
    });

    try {
      final response = await _client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': _apiKey,
        },
        body: body,
      );

      if (response.statusCode != 200) {
        return const [];
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final suggestions = data['suggestions'] as List<dynamic>? ?? [];

      return suggestions.map((s) {
        final place = s['placePrediction'] as Map<String, dynamic>? ?? {};
        final text  = place['structuredFormat'] as Map<String, dynamic>? ?? {};

        return _AutocompleteSuggestion(
          placeId: place['placeId'] as String? ?? '',
          name: (text['mainText']?['text'] as String?) ??
              (place['text']?['text'] as String?) ??
              '',
          address: text['secondaryText']?['text'] as String? ?? '',
        );
      }).where((s) => s.placeId.isNotEmpty).toList();
    } catch (e) {
      return const [];
    }
  }

  // ── Place Details (New) ────────────────────────────────────────────────────
  // GET https://places.googleapis.com/v1/places/{placeId}

  Future<PlaceResult?> _fetchDetails(_AutocompleteSuggestion suggestion) async {
    final uri = Uri.https(
      'places.googleapis.com',
      '/v1/places/${suggestion.placeId}',
    );

    try {
      final response = await _client.get(
        uri,
        headers: {
          'X-Goog-Api-Key': _apiKey,
          'X-Goog-FieldMask': 'location', // only fetch what we need → cheaper
        },
      );

      if (response.statusCode != 200) {
        return null;
      }

      final data     = json.decode(response.body) as Map<String, dynamic>;
      final location = data['location'] as Map<String, dynamic>?;
      if (location == null) return null;

      return PlaceResult(
        name:     suggestion.name,
        address:  suggestion.address,
        icon:     Icons.location_on_rounded,
        category: PlaceCategory.searchResult,
        location: GeoPoint(
          (location['latitude']  as num).toDouble(),
          (location['longitude'] as num).toDouble(),
        ),
      );
    } catch (e) {
      return null;
    }
  }
}

class _AutocompleteSuggestion {
  final String placeId;
  final String name;
  final String address;

  const _AutocompleteSuggestion({
    required this.placeId,
    required this.name,
    required this.address,
  });
}

// ── Provider ──────────────────────────────────────────────────────────────────

final placeRepositoryProvider = Provider<PlaceRepository>((ref) {
  return GooglePlacesRepository();
  // return StubPlaceRepository(); // for offline dev/tests
});