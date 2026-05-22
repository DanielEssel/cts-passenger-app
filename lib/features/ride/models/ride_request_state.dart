// ─────────────────────────────────────────────────────────────────────────────
// lib/features/ride/models/ride_request_state.dart
// ─────────────────────────────────────────────────────────────────────────────
 
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/features/payment/models/payment_method.dart';
 
class RideRequestState {
  final String?      origin;
  final String?      destination;
  final GeoPoint?    pickupLocation;
  final GeoPoint?    dropoffLocation;
  final double?      estimatedDistance;
  final int?         estimatedDuration;
  final RideOption?  selectedRide;
  final PaymentType  paymentMethod;
  final bool         isLoading;
 
  const RideRequestState({
    this.origin,
    this.destination,
    this.pickupLocation,
    this.dropoffLocation,
    this.estimatedDistance,
    this.estimatedDuration,
    this.selectedRide,
    this.paymentMethod = PaymentType.wallet,
    this.isLoading     = false,
  });
 
  bool get isDestinationSet  => destination != null && destination!.isNotEmpty;
  bool get hasValidLocations =>
      pickupLocation != null && dropoffLocation != null;
 
  double get calculatedFare {
    if (selectedRide == null) return 0;
    final km = estimatedDistance ?? RideConstants.defaultDistanceKm;
    return selectedRide!.fareForDistance(km);
  }
 
  RideRequestState copyWith({
    String?     origin,
    String?     destination,
    GeoPoint?   pickupLocation,
    GeoPoint?   dropoffLocation,
    double?     estimatedDistance,
    int?        estimatedDuration,
    RideOption? selectedRide,
    PaymentType? paymentMethod,
    bool?       isLoading,
    bool        clearDestination = false,
  }) {
    return RideRequestState(
      origin:            origin            ?? this.origin,
      destination:       clearDestination  ? null : destination ?? this.destination,
      pickupLocation:    pickupLocation    ?? this.pickupLocation,
      dropoffLocation:   clearDestination  ? null : dropoffLocation ?? this.dropoffLocation,
      estimatedDistance: clearDestination  ? null : estimatedDistance ?? this.estimatedDistance,
      estimatedDuration: clearDestination  ? null : estimatedDuration ?? this.estimatedDuration,
      selectedRide:      selectedRide      ?? this.selectedRide,
      paymentMethod:     paymentMethod     ?? this.paymentMethod,
      isLoading:         isLoading         ?? this.isLoading,
    );
  }
 
  static RideRequestState initial() => RideRequestState(
        selectedRide: RideOption.available().first,
      );
}
 