import 'package:flutter_riverpod/legacy.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../payment/models/payment_method.dart';
import '../../ride/models/ride_option.dart';
import '../../../core/services/pricing_service.dart';
import '../models/service_type.dart';

final rideRequestProvider =
    StateNotifierProvider<RideRequestNotifier, RideRequestState>(
  (ref) => RideRequestNotifier(),
);

class RideRequestState {
  final String? origin;
  final String? destination;

  final GeoPoint? pickupLocation;
  final GeoPoint? dropoffLocation;

  final RideOption? selectedRide;

  /// Store ONLY the enum/type in state
  final PaymentType paymentMethod;

  final bool isLoading;

  final double? estimatedDistance;
  final int? estimatedDuration;

  final String? error;

  const RideRequestState({
    this.origin,
    this.destination,
    this.pickupLocation,
    this.dropoffLocation,
    this.selectedRide,
    this.paymentMethod = PaymentType.wallet,
    this.isLoading = false,
    this.estimatedDistance,
    this.estimatedDuration,
    this.error,
  });

  RideRequestState copyWith({
  String? origin,
  String? destination,
  GeoPoint? pickupLocation,
  GeoPoint? dropoffLocation,
  RideOption? selectedRide,
  PaymentType? paymentMethod,
  bool? isLoading,
  double? estimatedDistance,
  int? estimatedDuration,
  String? error,
  // Explicit clear flags
  bool clearDestination = false,
  bool clearSelectedRide = false,
  bool clearError = false,
}) {
  return RideRequestState(
    origin: origin ?? this.origin,
    destination: clearDestination ? null : (destination ?? this.destination),
    pickupLocation: pickupLocation ?? this.pickupLocation,
    dropoffLocation: clearDestination ? null : (dropoffLocation ?? this.dropoffLocation),
    selectedRide: clearSelectedRide ? null : (selectedRide ?? this.selectedRide),
    paymentMethod: paymentMethod ?? this.paymentMethod,
    isLoading: isLoading ?? this.isLoading,
    estimatedDistance: clearDestination ? null : (estimatedDistance ?? this.estimatedDistance),
    estimatedDuration: clearDestination ? null : (estimatedDuration ?? this.estimatedDuration),
    error: clearError ? null : (error ?? this.error),
  );
}

  bool get isDestinationSet =>
    destination != null &&
    destination!.isNotEmpty &&
    dropoffLocation != null;

  bool get hasValidLocations =>
      pickupLocation != null && dropoffLocation != null;

  double get calculatedFare {
    if (selectedRide == null || estimatedDistance == null) return 0;
    if (estimatedDistance! <= 0) return 0;

    // Ensure PricingService has data — uses cached values if available
    final pricing = PricingService.instance;
    final serviceType = selectedRide!.serviceType.name; // 'okada' or 'taxi'
    final fare = pricing.calculateRideFare(
  serviceType, estimatedDistance!,
  waitingMinutes: (estimatedDuration ?? 0).toDouble(),
);

    // Never return 0 for a valid ride — use minimum fare as floor
    final minFare = serviceType == 'okada'
        ? PricingService.instance.okadaMinFare
        : PricingService.instance.taxiMinFare;
    return fare > 0 ? (fare >= minFare ? fare : minFare) : minFare;
  }

  /// Convenient getter for full payment model
  PaymentMethod get selectedPaymentMethod {
    return PaymentMethod.fromType(paymentMethod);
  }
}

class RideRequestNotifier extends StateNotifier<RideRequestState> {
  RideRequestNotifier() : super(const RideRequestState());

  void setOrigin(
    String origin,
    GeoPoint location,
  ) {
    state = state.copyWith(
      origin: origin,
      pickupLocation: location,
    );
  }

  void preselectService(ServiceType service) {
  if (state.selectedRide != null) return;
  final match = RideOptionsService.availableRides.firstWhere(
    (o) => o.serviceType == service,
    orElse: () => RideOptionsService.availableRides.first,
  );
  state = state.copyWith(selectedRide: match);
}

  void setDestination(
    String destination,
    GeoPoint location,
    double distance,
    int duration,
  ) {
    state = state.copyWith(
      destination: destination,
      dropoffLocation: location,
      estimatedDistance: distance,
      estimatedDuration: duration,
    );
  }

  void selectRide(RideOption ride) {
    state = state.copyWith(selectedRide: ride);
  }

  /// Accept enum instead of PaymentMethod object
  void selectPaymentMethod(PaymentType method) {
    state = state.copyWith(paymentMethod: method);
  }

  void setLoading(bool loading) {
    state = state.copyWith(isLoading: loading);
  }

  void setError(String? error) {
    state = state.copyWith(error: error);
  }

  void clearError() {
    state = state.copyWith(error: null);
  }

  void reset() {
    state = const RideRequestState();
  }
}