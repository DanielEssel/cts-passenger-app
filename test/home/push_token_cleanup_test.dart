// Push-token cleanup on sign-out: clear only this device's token from the
// profile, always detach the device, never throw.

import 'dart:async';

import 'package:cts_transport_app/features/home/services/push_token_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend {
  _FakeBackend(this.profileTokens);

  /// uid -> token stored on users/{uid}.fcmToken
  final Map<String, String?> profileTokens;
  String? deviceToken = 'device-A';
  bool deviceDeleted = false;
  bool failProfile = false;
  bool failDelete = false;
  bool hangProfile = false;

  PushTokenCleanup cleanup() => PushTokenCleanup(
        readDeviceToken: () async => deviceToken,
        clearProfileTokenIfMatches: (uid, token) async {
          if (hangProfile) await Completer<void>().future;
          if (failProfile) throw Exception('unavailable');
          if (profileTokens[uid] != token) return false;
          profileTokens[uid] = null;
          return true;
        },
        deleteDeviceToken: () async {
          if (failDelete) throw Exception('network');
          deviceDeleted = true;
          deviceToken = null;
        },
        stepTimeout: const Duration(milliseconds: 50),
      );
}

void main() {
  test('clears the profile token when it is this device, then detaches the device', () async {
    final b = _FakeBackend({'alice': 'device-A'});
    final r = await b.cleanup().run('alice');
    expect(r.profile, ProfileTokenStatus.cleared);
    expect(r.deviceTokenDeleted, isTrue);
    expect(b.profileTokens['alice'], isNull);
  });

  test("leaves the user's other phone registered", () async {
    final b = _FakeBackend({'alice': 'device-B'});
    final r = await b.cleanup().run('alice');
    expect(r.profile, ProfileTokenStatus.notThisDevice);
    expect(b.profileTokens['alice'], 'device-B');
    expect(r.deviceTokenDeleted, isTrue);
  });

  test("never touches another user's token", () async {
    final b = _FakeBackend({'alice': 'device-A', 'bob': 'device-A'});
    await b.cleanup().run('alice');
    expect(b.profileTokens['bob'], 'device-A');
  });

  test('still detaches the device when the profile write fails, and reports it', () async {
    final b = _FakeBackend({'alice': 'device-A'})..failProfile = true;
    final r = await b.cleanup().run('alice');
    expect(r.profile, ProfileTokenStatus.failed);
    expect(r.deviceTokenDeleted, isTrue);
    expect(b.profileTokens['alice'], 'device-A');
  });

  test('does not hang sign-out when the profile step stalls', () async {
    final b = _FakeBackend({'alice': 'device-A'})..hangProfile = true;
    final r = await b.cleanup().run('alice');
    expect(r.profile, ProfileTokenStatus.failed);
    expect(r.deviceTokenDeleted, isTrue);
  });

  test('reports when the device token could not be deleted', () async {
    final b = _FakeBackend({'alice': 'device-A'})..failDelete = true;
    final r = await b.cleanup().run('alice');
    expect(r.profile, ProfileTokenStatus.cleared);
    expect(r.deviceTokenDeleted, isFalse);
    expect(r.deviceDetached, isFalse);
  });

  test('skips the profile without a signed-in user or device token', () async {
    final b = _FakeBackend({'alice': 'device-A'});
    expect((await b.cleanup().run(null)).profile, ProfileTokenStatus.skipped);

    final b2 = _FakeBackend({'alice': 'device-A'})..deviceToken = null;
    final r2 = await b2.cleanup().run('alice');
    expect(r2.profile, ProfileTokenStatus.skipped);
    expect(b2.profileTokens['alice'], 'device-A');
  });
}
