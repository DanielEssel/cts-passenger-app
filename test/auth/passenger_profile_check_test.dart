// A registered passenger must never be rejected because Firestore answered
// from a cache that only holds the push-token write.

import 'package:cts_transport_app/features/auth/data/passenger_profile_check.dart';
import 'package:flutter_test/flutter_test.dart';

PassengerProfileStatus _check(Map<String, dynamic>? data, {required bool fromServer}) =>
    classifyPassengerProfile(exists: data != null, data: data, fromServer: fromServer);

void main() {
  const passenger = {'role': 'passenger', 'firstName': 'A'};
  const tokenOnly = {'fcmToken': 't', 'platform': 'android'};

  test('server copy of a passenger is accepted', () {
    expect(_check(passenger, fromServer: true), PassengerProfileStatus.passenger);
  });

  test('cached copy can confirm a passenger (offline start)', () {
    expect(_check(passenger, fromServer: false), PassengerProfileStatus.passenger);
  });

  test('cached token-only copy (the login race) is unverified, not "no account"', () {
    expect(_check(tokenOnly, fromServer: false), PassengerProfileStatus.unverified);
  });

  test('missing cached copy is unverified, not "no account"', () {
    expect(_check(null, fromServer: false), PassengerProfileStatus.unverified);
  });

  test('server says missing: not registered', () {
    expect(_check(null, fromServer: true), PassengerProfileStatus.notRegistered);
  });

  test('server says another role: rejected as other role', () {
    expect(_check({'role': 'driver_hailing'}, fromServer: true), PassengerProfileStatus.otherRole);
    expect(_check(tokenOnly, fromServer: true), PassengerProfileStatus.otherRole);
  });
}
