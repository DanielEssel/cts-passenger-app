// lib/core/utils/vehicle_icons.dart
import 'package:flutter/material.dart';

IconData vehicleIcon(String? serviceType) =>
    switch (serviceType?.toLowerCase()) {
      'okada'      => Icons.two_wheeler_rounded,
      'motorcycle' => Icons.two_wheeler_rounded,
      'aboboya'    => Icons.electric_rickshaw_rounded,
      'mini_truck' => Icons.local_shipping_rounded,
      'delivery'   => Icons.inventory_2_rounded,
      _            => Icons.directions_car_rounded,
    };

String vehicleMarkerAsset(String? serviceType) =>
    switch (serviceType?.toLowerCase()) {
      'okada'      => 'assets/icons/motorcycle_marker.png',
      'motorcycle' => 'assets/icons/motorcycle_marker.png',
      _            => 'assets/icons/car_marker.png',
    };

String vehicleLabel(String? serviceType) =>
    switch (serviceType?.toLowerCase()) {
      'okada'      => 'Okada',
      'motorcycle' => 'Motorcycle',
      'aboboya'    => 'Aboboya',
      'mini_truck' => 'Mini Truck',
      'delivery'   => 'Delivery',
      _            => 'Taxi',
    };

Color vehicleColor(String? serviceType) =>
    switch (serviceType?.toLowerCase()) {
      'okada'      => const Color(0xFF16A34A),
      'motorcycle' => const Color(0xFF16A34A),
      'aboboya'    => const Color(0xFFD97706),
      'mini_truck' => const Color(0xFF2563EB),
      'delivery'   => const Color(0xFF7C3AED),
      _            => const Color(0xFF16A34A),
    };
