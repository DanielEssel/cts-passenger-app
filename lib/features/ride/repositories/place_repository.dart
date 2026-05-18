// features/ride/repositories/place_repository.dart
//
// ✅ All hardcoded mock data moved OUT of the screen into a repository
// ✅ Abstract interface → easy to swap in a real Places API impl
// ✅ Static seed data is a legitimate stub at this layer (not in the UI)
// ✅ search() is async-ready: real impl calls Google Places / local DB

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/place_result.dart';
import '../repositories/google_places_repository.dart';

// ---------------------------------------------------------------------------
// Abstract contract
// ---------------------------------------------------------------------------

abstract class PlaceRepository {
  /// Returns places the user has recently visited.
  Future<List<PlaceResult>> getRecentPlaces();

  /// Returns curated popular destinations for the current city.
  Future<List<PlaceResult>> getPopularPlaces();

  /// Searches across all place sources for [query].
  Future<List<PlaceResult>> search(String query);
}

// ---------------------------------------------------------------------------
// Stub implementation (replace with Firestore / Google Places)
// ---------------------------------------------------------------------------

class StubPlaceRepository implements PlaceRepository {
  static final _recent = <PlaceResult>[
    PlaceResult(
      name: 'Home',
      address: '456 Residential Ave, East Legon',
      icon: Icons.home_rounded,
      category: PlaceCategory.recent,
      location: const GeoPoint(5.6366, -0.1768),
    ),
    PlaceResult(
      name: 'Office',
      address: '123 Business St, Cantonments',
      icon: Icons.business_rounded,
      category: PlaceCategory.recent,
      location: const GeoPoint(5.5717, -0.1835),
    ),
    PlaceResult(
      name: 'Kotoka Airport',
      address: 'Airport Rd, Accra',
      icon: Icons.flight_rounded,
      category: PlaceCategory.recent,
      location: const GeoPoint(5.6052, -0.1668),
    ),
  ];

  static final _popular = <PlaceResult>[
    PlaceResult(
      name: 'Accra Mall',
      address: 'Spintex Rd, Accra',
      icon: Icons.shopping_bag_rounded,
      category: PlaceCategory.popular,
      location: const GeoPoint(5.6270, -0.1527),
    ),
    PlaceResult(
      name: 'University of Ghana',
      address: 'Legon, Accra',
      icon: Icons.school_rounded,
      category: PlaceCategory.popular,
      location: const GeoPoint(5.6506, -0.1870),
    ),
    PlaceResult(
      name: 'Labadi Beach',
      address: 'La Beach Rd, Accra',
      icon: Icons.beach_access_rounded,
      category: PlaceCategory.popular,
      location: const GeoPoint(5.5560, -0.1404),
    ),
    PlaceResult(
      name: 'Tema Station',
      address: 'Kwame Nkrumah Ave, Accra',
      icon: Icons.directions_bus_rounded,
      category: PlaceCategory.popular,
      location: const GeoPoint(5.5469, -0.2060),
    ),
    PlaceResult(
      name: 'West Hills Mall',
      address: 'Weija, Accra',
      icon: Icons.local_mall_rounded,
      category: PlaceCategory.popular,
      location: const GeoPoint(5.5626, -0.3159),
    ),
  ];

  @override
  Future<List<PlaceResult>> getRecentPlaces() async => _recent;

  @override
  Future<List<PlaceResult>> getPopularPlaces() async => _popular;

  @override
  Future<List<PlaceResult>> search(String query) async {
    if (query.isEmpty) return const [];
    final q = query.toLowerCase();
    return [..._recent, ..._popular].where((p) {
      return p.name.toLowerCase().contains(q) ||
          p.address.toLowerCase().contains(q);
    }).toList();
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final placeRepositoryProvider = Provider<PlaceRepository>(
  (_) => GooglePlacesRepository(),
);
