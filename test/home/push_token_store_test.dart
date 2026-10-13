// AUTH-03: signing in must not create a passenger profile.

import 'package:cts_transport_app/features/home/services/push_token_store.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('token save', () {
    test('writes only token fields via update', () async {
      Map<String, Object?>? written;
      final saved = await saveTokenToExistingProfile(
        update: (f) async => written = f,
        token: 't',
        platform: 'android',
        serverTimestamp: 'ts',
      );
      expect(saved, isTrue);
      expect(written!.keys.toSet(), {'fcmToken', 'fcmTokenUpdatedAt', 'platform'});
    });

    test('no profile yet: skipped, nothing created', () async {
      final saved = await saveTokenToExistingProfile(
        update: (_) async =>
            throw FirebaseException(plugin: 'cloud_firestore', code: 'not-found'),
        token: 't',
        platform: 'android',
        serverTimestamp: 'ts',
      );
      expect(saved, isFalse);
    });

    test('other errors are surfaced, not swallowed as "no profile"', () async {
      expect(
        saveTokenToExistingProfile(
          update: (_) async => throw FirebaseException(
              plugin: 'cloud_firestore', code: 'permission-denied'),
          token: 't',
          platform: 'android',
          serverTimestamp: 'ts',
        ),
        throwsA(isA<FirebaseException>()),
      );
    });
  });
}
