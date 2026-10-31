// lib/features/ride/models/book_ride_args.dart
//
// The route arguments of AppRoutes.bookRide: the one contract between the
// screens that open booking (Home search and vehicle tiles, saved places,
// trip history) and BookRideScreen, which prefills from them. Nothing here
// books anything; the passenger still reviews and confirms.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'service_type.dart';

class BookRideArgs {
  const BookRideArgs({
    this.service,
    this.currentLocation,
    this.pickupAddress,
    this.pickupLocation,
    this.destinationAddress,
    this.destinationLocation,
    this.openSearch = false,
  });

  /// Vehicle to preselect. Only ride vehicles are kept (see [rideServices]).
  final ServiceType? service;

  /// The passenger's position as Home already resolved it.
  final LatLng? currentLocation;

  /// A pickup chosen earlier (trip history). Used instead of the current
  /// location, which is never substituted for it without saying so.
  final String? pickupAddress;
  final LatLng? pickupLocation;

  final String? destinationAddress;

  /// The destination's coordinates when known, so the address is not looked
  /// up again.
  final LatLng? destinationLocation;

  /// Open destination search as soon as the screen is ready (Home search bar
  /// and vehicle tiles).
  final bool openSearch;

  /// Vehicles BookRideScreen offers.
  static const rideServices = {
    ServiceType.taxi,
    ServiceType.okada,
    ServiceType.pragyia,
  };

  bool get hasPickup => pickupLocation != null || pickupAddress != null;
  bool get hasDestination =>
      destinationLocation != null || destinationAddress != null;

  Map<String, dynamic> toMap() => {
        if (service != null) 'service': service,
        if (currentLocation != null) 'pickup': currentLocation,
        if (pickupAddress != null) 'pickupAddress': pickupAddress,
        if (pickupLocation != null) 'pickupLocation': pickupLocation,
        if (destinationAddress != null)
          'destinationAddress': destinationAddress,
        if (destinationLocation != null)
          'destinationLocation': destinationLocation,
        if (openSearch) 'openSearch': true,
      };

  /// Reads route arguments, dropping anything unusable: an unknown or
  /// non-ride vehicle, blank or placeholder ("—") addresses, wrong types.
  factory BookRideArgs.fromRoute(Object? arguments) {
    if (arguments is! Map) return const BookRideArgs();
    final service = arguments['service'];
    return BookRideArgs(
      service: service is ServiceType && rideServices.contains(service)
          ? service
          : null,
      currentLocation: _latLng(arguments['pickup']),
      pickupAddress: _address(arguments['pickupAddress']),
      pickupLocation: _latLng(arguments['pickupLocation']),
      destinationAddress: _address(arguments['destinationAddress']),
      destinationLocation: _latLng(arguments['destinationLocation']),
      openSearch: arguments['openSearch'] == true,
    );
  }

  static LatLng? _latLng(Object? v) => v is LatLng ? v : null;

  static String? _address(Object? v) {
    if (v is! String) return null;
    final s = v.trim();
    return s.isEmpty || s == '—' ? null : s;
  }

  /// The ride vehicle a stored service name refers to, or null.
  static ServiceType? rideServiceNamed(String? name) {
    for (final s in rideServices) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// Home's search bar: destination entry straight away, no vehicle chosen.
const homeSearchArgs = BookRideArgs(openSearch: true);

/// A Home vehicle tile (Taxi / Okada / Pragyia): destination entry straight
/// away with that vehicle chosen.
BookRideArgs vehicleTileArgs(ServiceType service) =>
    BookRideArgs(service: service, openSearch: true);

/// A saved-place shortcut: the place as destination (its saved coordinates
/// when it has them) and the passenger's last vehicle. Null for a place that
/// is not set up (the Home / Work placeholders, a blank address): those open
/// Saved Places instead of booking.
BookRideArgs? savedPlaceArgs({
  required bool configured,
  required String address,
  double? lat,
  double? lng,
  ServiceType? lastVehicle,
}) {
  final destination = BookRideArgs._address(address);
  if (!configured || destination == null) return null;
  return BookRideArgs(
    service: lastVehicle != null && BookRideArgs.rideServices.contains(lastVehicle)
        ? lastVehicle
        : null,
    destinationAddress: destination,
    destinationLocation: lat != null && lng != null ? LatLng(lat, lng) : null,
  );
}

/// Rebooking a past trip (its Firestore fields): the trip's own pickup and
/// destination, with their stored coordinates, and its vehicle when that is
/// a ride vehicle this app still offers.
BookRideArgs rebookArgsFromTrip(Map<String, dynamic> trip) => BookRideArgs(
      service: BookRideArgs.rideServiceNamed(trip['serviceType'] as String?),
      pickupAddress: BookRideArgs._address(trip['pickupAddress']),
      pickupLocation: _fromGeoPoint(trip['pickupLocation']),
      destinationAddress: BookRideArgs._address(trip['dropoffAddress']),
      destinationLocation: _fromGeoPoint(trip['dropoffLocation']),
    );

LatLng? _fromGeoPoint(Object? v) =>
    v is GeoPoint ? LatLng(v.latitude, v.longitude) : null;
