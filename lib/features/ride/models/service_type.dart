import 'package:flutter/material.dart';


enum ServiceType {
  taxi,
  okada,
  delivery,
  gas;

  String get displayName => switch (this) {
        ServiceType.taxi => 'Taxi',
        ServiceType.okada => 'Okada',
        ServiceType.delivery => 'Delivery',
        ServiceType.gas => 'Gas',
      };

  IconData get icon => switch (this) {
        ServiceType.taxi => Icons.local_taxi,
        ServiceType.okada => Icons.motorcycle,
        ServiceType.delivery => Icons.local_shipping,
        ServiceType.gas => Icons.local_fire_department,
      };
}
