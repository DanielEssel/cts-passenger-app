import 'package:flutter/material.dart';

enum ServiceType {
  taxi,
  okada,
  pragyia,
  delivery,
  gas;

  String get displayName => switch (this) {
        ServiceType.taxi => 'Taxi',
        ServiceType.okada => 'Okada',
        ServiceType.pragyia => 'Pragyia',
        ServiceType.delivery => 'Delivery',
        ServiceType.gas => 'Gas',
      };

  IconData get icon => switch (this) {
        ServiceType.taxi => Icons.local_taxi,
        ServiceType.okada => Icons.motorcycle,
        ServiceType.pragyia => Icons.electric_bike,
        ServiceType.delivery => Icons.local_shipping,
        ServiceType.gas => Icons.local_fire_department,
      };

}
