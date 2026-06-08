// lib/features/ride/services/ride_options_service.dart

import 'package:flutter/material.dart';
import '../../../core/services/pricing_service.dart';
import '../../../core/constants/app_colors.dart';
import '../models/service_type.dart';




extension ServiceTypeExtension on ServiceType {
  String get displayName {
    switch (this) {
      case ServiceType.taxi:
        return 'Taxi';
      case ServiceType.okada:
        return 'Okada';
      case ServiceType.delivery:
        return 'Delivery';
      case ServiceType.gas:
        return 'Gas';
    }
  }

  IconData get icon {
    switch (this) {
      case ServiceType.taxi:
        return Icons.directions_car_rounded;
      case ServiceType.okada:
        return Icons.two_wheeler_rounded;
      case ServiceType.delivery:
        return Icons.local_shipping_rounded;
      case ServiceType.gas:
        return Icons.local_fire_department_rounded;
    }
  }

  String get searchHint {
    switch (this) {
      case ServiceType.taxi:
        return 'Where are you going?';
      case ServiceType.okada:
        return 'Quick ride — where to?';
      case ServiceType.delivery:
        return 'Deliver a package';
      case ServiceType.gas:
        return 'Order cooking gas';
    }
  }


  String get route {
    switch (this) {
      case ServiceType.taxi:
      case ServiceType.okada:
        return '/book-ride';
      case ServiceType.delivery:
        return '/delivery';
      case ServiceType.gas:
        return '/gas-order';
    }
  }

  String get driverRole {
    switch (this) {
      case ServiceType.taxi:
      case ServiceType.okada:
        return 'driver_hailing';
      case ServiceType.delivery:
      case ServiceType.gas:
        return 'driver_delivery';
    }
  }

  double get baseFare {
    final p = PricingService.instance;
    switch (this) {
      case ServiceType.taxi:     return p.taxiBaseFare;
      case ServiceType.okada:    return p.okadaBaseFare;
      case ServiceType.delivery: return p.deliveryBaseFare;
      case ServiceType.gas:      return p.gasDeliveryFee;
    }
  }

  double get pricePerKm {
    final p = PricingService.instance;
    switch (this) {
      case ServiceType.taxi:     return p.taxiPerKmRate;
      case ServiceType.okada:    return p.okadaPerKmRate;
      case ServiceType.delivery: return p.deliveryPerKmRate;
      case ServiceType.gas:      return 0;
    }
  }

  int get maxPassengers {
    switch (this) {
      case ServiceType.taxi:
        return 4;
      case ServiceType.okada:
        return 1;
      case ServiceType.delivery:
        return 0;
      case ServiceType.gas:
        return 0;
    }
  }

  String get description {
    switch (this) {
      case ServiceType.taxi:
        return 'Comfortable · 4 seats';
      case ServiceType.okada:
        return 'Agile · 1 seat';
      case ServiceType.delivery:
        return 'Small packages';
      case ServiceType.gas:
        return 'Cooking gas delivery';
    }
  }

  String get badge {
    switch (this) {
      case ServiceType.taxi:
        return 'Most popular';
      case ServiceType.okada:
        return 'Fastest';
      case ServiceType.delivery:
        return 'Logistics';
      case ServiceType.gas:
        return 'Essential';
    }
  }

  String get eta {
    switch (this) {
      case ServiceType.taxi:
        return '3 min';
      case ServiceType.okada:
        return '1 min';
      case ServiceType.delivery:
        return '5 min';
      case ServiceType.gas:
        return '10 min';
    }
  }

  Color get etaColor {
    switch (this) {
      case ServiceType.taxi:
      case ServiceType.okada:
        return AppColors.success;
      case ServiceType.delivery:
        return AppColors.info;
      case ServiceType.gas:
        return AppColors.warning;
    }
  }

  String get duration {
    switch (this) {
      case ServiceType.taxi:
        return '~18 min';
      case ServiceType.okada:
        return '~14 min';
      case ServiceType.delivery:
        return '~25 min';
      case ServiceType.gas:
        return '~30 min';
    }
  }

  List<String> get perks {
    switch (this) {
      case ServiceType.taxi:
        return ['AC included', 'Insured', 'Real-time tracking', 'Professional driver'];
      case ServiceType.okada:
        return ['Helmet provided', 'Skip traffic', 'Quick pickup', 'Cash payment'];
      case ServiceType.delivery:
        return ['Door-to-door', 'Secure handling', 'Live tracking'];
      case ServiceType.gas:
        return ['Safety checked', 'Installation', 'Payment on delivery'];
    }
  }

  bool get hasAC {
    switch (this) {
      case ServiceType.taxi:
        return true;
      default:
        return false;
    }
  }

  bool get isInsured {
    return true;
  }
}

/// Main ride model used across booking flow
class RideOption {
  final ServiceType serviceType;
  final IconData icon;
  final String name;
  final String badge;
  final String description;
  final String eta;
  final Color etaColor;
  final double basePrice;
  final String duration;
  final List<String> perks;
  final int maxPassengers;
  final bool hasAC;
  final bool isInsured;

  const RideOption({
    required this.serviceType,
    required this.icon,
    required this.name,
    required this.badge,
    required this.description,
    required this.eta,
    required this.etaColor,
    required this.basePrice,
    required this.duration,
    this.perks = const [],
    this.maxPassengers = 4,
    this.hasAC = true,
    this.isInsured = true,
  });

  /// Create from ServiceType
  factory RideOption.fromServiceType(ServiceType type) {
    return RideOption(
      serviceType: type,
      icon: type.icon,
      name: type.displayName == 'Taxi' ? 'CTSRide Taxi' : type.displayName,
      badge: type.badge,
      description: type.description,
      eta: type.eta,
      etaColor: type.etaColor,
      basePrice: type.baseFare + (type.pricePerKm * 8.2), // Default 8.2km
      duration: type.duration,
      perks: type.perks,
      maxPassengers: type.maxPassengers,
      hasAC: type.hasAC,
      isInsured: type.isInsured,
    );
  }
}

/// Central service that provides rides + pricing
class RideOptionsService {
  static final List<RideOption> availableRides = [
    RideOption.fromServiceType(ServiceType.taxi),
    RideOption.fromServiceType(ServiceType.okada),
    RideOption.fromServiceType(ServiceType.delivery),
  ];

  /// Get ride by type
  static RideOption getRideOption(ServiceType type) {
    return availableRides.firstWhere(
      (ride) => ride.serviceType == type,
      orElse: () => availableRides.first,
    );
  }

  /// Dynamic pricing algorithm based on distance — reads from Firestore settings
  static double calculateDynamicPrice(RideOption option, double distanceKm) {
    final pricing = PricingService.instance;
    return switch (option.serviceType) {
      ServiceType.taxi     => pricing.calculateRideFare('taxi',     distanceKm),
      ServiceType.okada    => pricing.calculateRideFare('okada',    distanceKm),
      ServiceType.delivery => pricing.calculateDeliveryFare(distanceKm),
      ServiceType.gas      => pricing.gasDeliveryFee,
    };
  }

  /// Calculate price with surge — surge is already applied inside PricingService
  static double calculatePriceWithSurge(RideOption option, double distanceKm, double surgeMultiplier) {
    return calculateDynamicPrice(option, distanceKm);
  }

  /// Get estimated time based on distance and service type
  static int getEstimatedTime(RideOption option, double distanceKm) {
    final speedPerMinute = switch (option.serviceType) {
      ServiceType.taxi => 0.5,  // 500m per minute
      ServiceType.okada => 0.7, // 700m per minute
      ServiceType.delivery => 0.4, // 400m per minute
      ServiceType.gas => 0.3, // 300m per minute
    };
    return (distanceKm / speedPerMinute).round();
  }

  /// Check if service is available at given time
  static bool isServiceAvailable(ServiceType type, [int? hour]) {
    final currentHour = hour ?? DateTime.now().hour;
    
    switch (type) {
      case ServiceType.taxi:
        return true; // 24/7
      case ServiceType.okada:
        return currentHour >= 6 && currentHour <= 22; // 6 AM to 10 PM
      case ServiceType.delivery:
        return currentHour >= 8 && currentHour <= 20; // 8 AM to 8 PM
      case ServiceType.gas:
        return currentHour >= 9 && currentHour <= 18; // 9 AM to 6 PM
    }
  }
}