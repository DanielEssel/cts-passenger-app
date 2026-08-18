// lib/features/tracking/tracking_constants.dart - Update mapStyle


import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class TrackingConstants {
  // Polyline styling
  static const double polylineWidth = 6.5; // Reduced from 8
  static const double polylineShadowWidth = 10.0; // Reduced from 12
  static const List<PatternItem> polylinePattern = [];
  static const bool polylineGeodesic = true;

  // Bottom sheet sizing
  static const double minSheetSize = 0.18;
  static const double initialSheetSize = 0.42;
  static const double maxSheetSize = 0.88;
  static const List<double> snapSizes = [0.18, 0.42, 0.88];

  // Map padding
  static const double mapPaddingBottom = 160.0;
  static const double mapPaddingTop = 80.0;

  // Animation durations
  static const Duration animationDuration = Duration(milliseconds: 400);
  static const Duration quickAnimation = Duration(milliseconds: 200);
  static const Duration smoothAnimation = Duration(milliseconds: 600);

  // Premium Apple/Uber-style light map (desaturated, clean, minimal)
  static const String mapStyle = '''
[
  {
    "elementType": "geometry",
    "stylers": [
      {"color": "#f5f7f8"}
    ]
  },
  {
    "elementType": "geometry.fill",
    "stylers": [
      {"color": "#f0f2f4"}
    ]
  },
  {
    "elementType": "geometry.stroke",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "elementType": "labels",
    "stylers": [
      {"visibility": "on"}
    ]
  },
  {
    "elementType": "labels.icon",
    "stylers": [
      {"visibility": "off"}
    ]
  },
  {
    "elementType": "labels.text.fill",
    "stylers": [
      {"color": "#5f6368"}
    ]
  },
  {
    "elementType": "labels.text.stroke",
    "stylers": [
      {"color": "#ffffff"}
    ]
  },
  {
    "featureType": "landscape",
    "elementType": "geometry",
    "stylers": [
      {"color": "#eef0f2"}
    ]
  },
  {
    "featureType": "landscape.man_made",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "landscape.natural",
    "elementType": "geometry",
    "stylers": [
      {"color": "#dce1e6"}
    ]
  },
  {
    "featureType": "landscape.natural.landcover",
    "elementType": "geometry",
    "stylers": [
      {"color": "#dce1e6"}
    ]
  },
  {
    "featureType": "landscape.natural.terrain",
    "elementType": "geometry",
    "stylers": [
      {"color": "#dce1e6"}
    ]
  },
  {
    "featureType": "poi",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "poi",
    "elementType": "labels.text",
    "stylers": [
      {"visibility": "simplified"}
    ]
  },
  {
    "featureType": "poi.attraction",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "poi.business",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "poi.government",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "poi.medical",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "poi.park",
    "elementType": "geometry",
    "stylers": [
      {"color": "#d2e0d5"}
    ]
  },
  {
    "featureType": "poi.park",
    "elementType": "labels",
    "stylers": [
      {"visibility": "on"}
    ]
  },
  {
    "featureType": "poi.park",
    "elementType": "labels.text",
    "stylers": [
      {"color": "#4a7c59"}
    ]
  },
  {
    "featureType": "poi.place_of_worship",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "poi.school",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "poi.sports_complex",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "road",
    "elementType": "geometry",
    "stylers": [
      {"color": "#ffffff"}
    ]
  },
  {
    "featureType": "road",
    "elementType": "labels.icon",
    "stylers": [
      {"visibility": "off"}
    ]
  },
  {
    "featureType": "road",
    "elementType": "labels.text",
    "stylers": [
      {"color": "#8a8a8a"}
    ]
  },
  {
    "featureType": "road.arterial",
    "elementType": "geometry",
    "stylers": [
      {"color": "#f5f7f8"}
    ]
  },
  {
    "featureType": "road.highway",
    "elementType": "geometry",
    "stylers": [
      {"color": "#eef0f2"}
    ]
  },
  {
    "featureType": "road.highway.controlled_access",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "road.local",
    "elementType": "geometry",
    "stylers": [
      {"color": "#fafbfc"}
    ]
  },
  {
    "featureType": "transit",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "transit.station",
    "elementType": "geometry",
    "stylers": [
      {"color": "#e8eaed"}
    ]
  },
  {
    "featureType": "water",
    "elementType": "geometry",
    "stylers": [
      {"color": "#d4e3ed"}
    ]
  },
  {
    "featureType": "water",
    "elementType": "labels.text",
    "stylers": [
      {"color": "#7a9bb5"}
    ]
  }
]
''';

  static const SystemUiOverlayStyle lightStatusBar = SystemUiOverlayStyle.light;
}