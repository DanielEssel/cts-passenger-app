// The app's delivery fare must match the server's observe-only fare check,
// case for case. Both read functions/test/fixtures/delivery_fare_parity.json.

import 'dart:convert';
import 'dart:io';

import 'package:cts_transport_app/core/services/pricing_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixture = jsonDecode(
    File('functions/test/fixtures/delivery_fare_parity.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final settings = fixture['settings'] as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  tearDown(() => PricingService.instance.debugSetSettings(null));

  for (final c in cases) {
    test(
        '${c['settings']}: ${c['vehicle']} ${c['km']} km ${c['weight']}'
        '${c['fragile'] == true ? ' fragile' : ''}'
        '${c['helpers'] == true ? ' helpers' : ''} = ${c['expected']}', () {
      PricingService.instance.debugSetSettings(
          Map<String, dynamic>.from(settings[c['settings']] as Map));
      final total = PricingService.instance.calculateDeliveryFare(
        (c['km'] as num).toDouble(),
        vehicleType: c['vehicle'] as String,
        weightTier: c['weight'] as String,
        isFragile: c['fragile'] as bool,
        requiresHelpers: c['helpers'] as bool,
      );
      expect(total, (c['expected'] as num).toDouble());
    });
  }
}
