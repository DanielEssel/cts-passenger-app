// The delivery vehicles offered per weight tier stay within each vehicle's
// shown capacity, and match the table the backend enforces, so the app
// never offers a vehicle that dispatch and the rules would refuse.

import 'dart:io';

import 'package:cts_transport_app/features/delivery/domain/delivery_vehicle_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shown capacities (delivery_vehicle_screen.dart), in kg: [min, max].
const _capacity = {
  'Okada': [0, 5],
  'Aboboya': [5, 100],
  'Mini Truck': [100, double.infinity],
};

/// Tier ranges (delivery_screen.dart), in kg.
const _tierRange = {
  'Small': [0, 5],
  'Medium': [5, 20],
  'Large': [20, 100],
  'Bulk': [100, double.infinity],
};

void main() {
  test('every tier has a vehicle, and only vehicles whose capacity covers it', () {
    for (final tier in _tierRange.keys) {
      final vehicles = deliveryTierVehicles[tier]!;
      expect(vehicles, isNotEmpty, reason: tier);
      for (final v in vehicles) {
        final cap = _capacity[v]!, range = _tierRange[tier]!;
        expect(cap[0] <= range[0] && range[1] <= cap[1], isTrue,
            reason: '$v ($cap kg) cannot carry $tier ($range kg)');
      }
    }
  });

  test('Medium (5–20 kg) is no longer offered on an Okada (0–5 kg)', () {
    expect(deliveryVehicleCarries('Okada', 'Medium'), isFalse);
    expect(deliveryVehicleCarries('Aboboya', 'Medium'), isTrue);
    expect(deliveryVehicleCarries('Okada', 'Small'), isTrue);
    expect(deliveryVehicleCarries('Mini Truck', 'Bulk'), isTrue);
    expect(deliveryVehicleCarries('Mini Truck', 'Small'), isFalse);
    expect(deliveryVehicleCarries('Okada', 'Unknown'), isFalse);
  });

  test('matches the backend table (functions/dispatch_policy.js)', () {
    final src = File('functions/dispatch_policy.js').readAsStringSync();
    final block = RegExp(r'DELIVERY_VEHICLE_TIERS = Object\.freeze\(\{([\s\S]*?)\}\);')
        .firstMatch(src)!
        .group(1)!;
    final backend = <String, Set<String>>{};
    for (final m in RegExp(r'(\w+): Object\.freeze\(\[([^\]]*)\]\)').allMatches(block)) {
      backend[m.group(1)!] =
          RegExp(r'"(\w+)"').allMatches(m.group(2)!).map((t) => t.group(1)!).toSet();
    }
    const key = {'Okada': 'motorcycle', 'Aboboya': 'tricycle', 'Mini Truck': 'miniTruck'};
    final app = <String, Set<String>>{};
    deliveryTierVehicles.forEach((tier, vehicles) {
      for (final v in vehicles) {
        (app[key[v]!] ??= {}).add(tier);
      }
    });
    expect(app, backend);
  });
}
