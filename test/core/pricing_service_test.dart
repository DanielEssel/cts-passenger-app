// Payable flows (Gas orders, wallet-held rides) read settings/platform from
// the server before money is held or an order is created. Offline, missing
// or empty settings refuse; the built-in defaults never authorise a charge.

import 'package:cts_transport_app/core/services/pricing_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final p = PricingService.instance;

  tearDown(() {
    PricingService.debugServerReader = null;
    p.debugSetSettings(null);
  });

  test('offline: refuses and keeps what is loaded for display', () async {
    p.debugSetSettings({
      'gas': {'baseFare': 9}
    });
    PricingService.debugServerReader = () async => throw Exception(
        '[cloud_firestore/unavailable] Failed to get document because the '
        'client is offline.');
    expect(await p.fetchFromServer(), isFalse);
    expect(p.gasBaseFare, 9);
  });

  test('offline with nothing loaded: refuses; display falls back', () async {
    PricingService.debugServerReader = () async => throw Exception('offline');
    expect(await p.fetchFromServer(), isFalse);
    expect(p.hasLoadedSettings, isFalse);
  });

  test('missing or empty settings document: refuses', () async {
    PricingService.debugServerReader = () async => null;
    expect(await p.fetchFromServer(), isFalse);
    PricingService.debugServerReader = () async => {};
    expect(await p.fetchFromServer(), isFalse);
    expect(p.hasLoadedSettings, isFalse);
  });

  test('server settings: loaded and used as configured', () async {
    PricingService.debugServerReader = () async => {
          'gas': {'baseFare': 11, 'refill12kg': 160}
        };
    expect(await p.fetchFromServer(), isTrue);
    expect(p.gasBaseFare, 11);
    expect(p.gasRefill12kg, 160);
    expect(p.gasPricingProblem, isNull);
  });

  test('malformed server values load but block Gas pricing', () async {
    PricingService.debugServerReader = () async => {
          'gas': {'refill12kg': 'ask the shop'}
        };
    expect(await p.fetchFromServer(), isTrue);
    expect(p.gasPricingProblem, 'gas_config_invalid');

    PricingService.debugServerReader = () async => {'platformFeePercent': 140};
    expect(await p.fetchFromServer(), isTrue);
    expect(p.gasPricingProblem, 'platform_fee_invalid');
  });
}
