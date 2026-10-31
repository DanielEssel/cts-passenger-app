// C4-A: delivery and gas tracking read the driver's live position from
// `driverCurrentLocation` (what the Driver App writes), with the legacy
// `driverLocation` as a fallback, and never show an unusable value.
//
// The models' fromFirestore factories call readDriverLocation(d) directly
// (delivery_request.dart, gas_refill_request.dart). They are not exercised
// here: DocumentSnapshot is @sealed and the project has no fake-Firestore
// test dependency.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/core/utils/driver_location.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const current = GeoPoint(5.6037, -0.1870);
  const legacy = GeoPoint(5.5500, -0.2000);

  group('readDriverLocation', () {
    test('1. only driverCurrentLocation exists', () {
      expect(readDriverLocation({'driverCurrentLocation': current}), current);
    });

    test('2. only legacy driverLocation exists', () {
      expect(readDriverLocation({'driverLocation': legacy}), legacy);
    });

    test('3. both exist: driverCurrentLocation takes precedence', () {
      expect(readDriverLocation({'driverCurrentLocation': current, 'driverLocation': legacy}), current);
    });

    test('4. neither exists, or both are null', () {
      expect(readDriverLocation({}), isNull);
      expect(readDriverLocation({'driverCurrentLocation': null, 'driverLocation': null}), isNull);
    });

    test('5. malformed current field falls back to a valid legacy field', () {
      for (final bad in <Object>[
        'not a location',
        {'latitude': 5.6, 'longitude': -0.18},
        42,
        const GeoPoint(0, 0),
      ]) {
        expect(readDriverLocation({'driverCurrentLocation': bad, 'driverLocation': legacy}), legacy,
            reason: 'bad current value: $bad');
      }
    });

    test('6. both fields unusable gives no location', () {
      expect(readDriverLocation({'driverCurrentLocation': 'x', 'driverLocation': const GeoPoint(0, 0)}), isNull);
      expect(readDriverLocation({'driverCurrentLocation': [1, 2], 'driverLocation': true}), isNull);
    });
  });
}
