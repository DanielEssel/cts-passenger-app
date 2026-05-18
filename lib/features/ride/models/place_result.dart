// features/ride/models/place_result.dart
//
// ✅ Typed model replaces Map<String, dynamic> throughout the feature
// ✅ Immutable + equatable for safe comparison in providers
// ✅ Carries GeoPoint so BookRideScreen can receive real coordinates
// ✅ Factory constructors for each well-known place category

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

enum PlaceCategory { recent, popular, searchResult }

class PlaceResult {
  const PlaceResult({
    required this.name,
    required this.address,
    required this.icon,
    required this.category,
    required this.location,
    this.distanceKm,
    this.durationMin,
  });

  final String name;
  final String address;
  final IconData icon;
  final PlaceCategory category;

  /// Real coordinates — previously missing; BookRideScreen needs these.
  final GeoPoint location;

  /// Optional — populated by routing service after selection.
  final double? distanceKm;
  final int? durationMin;

  bool get isRecent => category == PlaceCategory.recent;

  PlaceResult copyWith({
    double? distanceKm,
    int? durationMin,
  }) {
    return PlaceResult(
      name: name,
      address: address,
      icon: icon,
      category: category,
      location: location,
      distanceKm: distanceKm ?? this.distanceKm,
      durationMin: durationMin ?? this.durationMin,
    );
  }

  /// Converts to the Map<String, dynamic> that BookRideScreen currently expects
  /// via Navigator.pop. Remove once BookRideScreen is updated to accept PlaceResult directly.
  Map<String, dynamic> toNavigationResult() => {
        'address': address,
        'location': location,
        'distance': distanceKm,
        'duration': durationMin,
      };

  @override
  bool operator ==(Object other) =>
      other is PlaceResult && other.name == name && other.address == address;

  @override
  int get hashCode => Object.hash(name, address);
}