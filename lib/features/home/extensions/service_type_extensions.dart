import 'package:flutter/material.dart';
import '../../../core/routes/app_routes.dart';
import 'package:cts_transport_app/features/ride/models/service_type.dart';


extension ServiceTypeExtension on ServiceType {
  String get displayName {
    switch (this) {
      case ServiceType.taxi:
        return 'Taxi';
      case ServiceType.okada:
        return 'Okada';
      case ServiceType.pragyia:
        return 'Pragyia';
      case ServiceType.delivery:
        return 'Delivery';
      case ServiceType.gas:
        return 'Gas';
    }
  }

  IconData get icon {
    switch (this) {
      case ServiceType.taxi:
        return Icons.local_taxi_rounded;
      case ServiceType.okada:
        return Icons.electric_bike_rounded;
      case ServiceType.pragyia:
        return Icons.directions_car_rounded;
      case ServiceType.delivery:
        return Icons.inventory_2_rounded;
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
      case ServiceType.pragyia:
        return 'Short trips';
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
      case ServiceType.pragyia:
        return AppRoutes.bookRide; // Uses your existing route
      // Uses your existing route
      case ServiceType.delivery:
        return AppRoutes.delivery; // Uses your existing route
      case ServiceType.gas:
        return AppRoutes.gasOrder; // Uses your existing route
    }
  }

  String get driverRole {
    switch (this) {
      case ServiceType.taxi:
      case ServiceType.okada:
      case ServiceType.pragyia:
        return 'driver_hailing';
      case ServiceType.delivery:
      case ServiceType.gas:
        return 'driver_delivery';
    }
  }
}
