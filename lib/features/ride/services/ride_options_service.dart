import 'package:flutter/material.dart';
import '../models/ride_option.dart';
import '../../ride/models/service_type.dart';

class RideOptionsService {
  static const List<RideOption> availableRides = [
    RideOption(
      serviceType: ServiceType.taxi,
      icon: Icons.directions_car_rounded,
      name: 'CTSTransport Taxi',
      badge: 'Most popular',
      description: 'Comfortable · 4 seats',
      eta: '3 min',
      etaColor: Color(0xFF10B981),
      basePrice: 28.0,
      duration: '~18 min',
      perks: [
        'AC included',
        'Insured',
        'Real-time tracking',
        'Professional driver'
      ],
      maxPassengers: 4,
      hasAC: true,
      isInsured: true,
    ),
    RideOption(
      serviceType: ServiceType.okada,
      icon: Icons.two_wheeler_rounded,
      name: 'Okada',
      badge: 'Fastest',
      description: 'Agile · 1 seat',
      eta: '1 min',
      etaColor: Color(0xFF10B981),
      basePrice: 12.0,
      duration: '~14 min',
      perks: [
        'Helmet provided',
        'Skip traffic',
        'Quick pickup',
        'Cash payment'
      ],
      maxPassengers: 1,
      hasAC: false,
      isInsured: true,
    ),
    RideOption(
      serviceType: ServiceType.pragyia,
      icon: Icons.electric_rickshaw,
      name: 'Pragyia',
      badge: 'Eco-friendly',
      description: 'Electric · 3 seat',
      eta: '2 min',
      etaColor: Color(0xFF10B981),
      basePrice: 15.0,
      duration: '~16 min',
      perks: [
        'Environmentally friendly',
        'Quiet ride',
        'Cashless payment',
        'Real-time tracking'
      ],
      maxPassengers: 3,
      hasAC: false,
      isInsured: true,
    ),
  ];

  static RideOption getRideOption(ServiceType type) {
    return availableRides.firstWhere(
      (ride) => ride.serviceType == type,
      orElse: () => availableRides[0],
    );
  }

  static double calculateDynamicPrice(RideOption option, double distanceKm) {
    const pricePerKm = 2.5;
    return option.basePrice + (pricePerKm * distanceKm);
  }
}
