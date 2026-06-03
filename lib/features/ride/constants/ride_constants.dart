import 'package:google_maps_flutter/google_maps_flutter.dart';

class RideConstants {
  static const String defaultOrigin = 'Osu, Accra';

  static final LatLng defaultPickupCoordinates =
      LatLng(5.6037, -0.1870);

  static const double defaultDistanceKm = 8.2;
  static const int defaultDurationMin = 18;
  static const Duration driverSearchTimeout = Duration(seconds: 120);

  static const double defaultMapZoom = 14;
  static const double userLocationZoom = 15;
  static const double mapHeight = 248;

  static const Duration fabAnimationDuration =
      Duration(milliseconds: 450);

  static const Duration cardAnimationDuration =
      Duration(milliseconds: 220);

  static const Duration pageTransitionDuration =
      Duration(milliseconds: 300);

  static const String errorMissingLocations =
      'Please set both pickup and dropoff locations.';

  static const String errorCreateTrip =
      'Could not create trip. Please try again.';

  static const String errorNoDrivers =
      'No drivers available nearby. Please try again later.';

  static const String tripCreated =
      'Trip created successfully!';
}