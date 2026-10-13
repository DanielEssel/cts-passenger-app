// lib/features/home/services/push_token_cleanup.dart
//
// Push-token cleanup on sign-out.
//
// The backend sends pushes to the single token stored on users/{uid}.fcmToken
// (functions/notifications.js notifyPassenger). On sign-out we:
//   1. clear that field only if it still holds THIS device's token, so signing
//      out here never removes a token the same user registered on another
//      phone, and never touches another user's document;
//   2. delete this device's FCM token. Firebase then rejects that token
//      everywhere, so even a profile that still references it (for example
//      because step 1 failed offline) stops receiving pushes on this device.
// A fresh token is issued and saved on the next sign-in.

import 'dart:async';

/// How step 1 (the profile field) ended.
enum ProfileTokenStatus {
  /// The field held this device's token and was cleared.
  cleared,

  /// The field held a different token (or none); left untouched.
  notThisDevice,

  /// There was no signed-in user or no device token to compare.
  skipped,

  /// The read or write failed (offline, rules, timeout).
  failed,
}

class PushTokenCleanupResult {
  final ProfileTokenStatus profile;

  /// True when this device's FCM token was deleted.
  final bool deviceTokenDeleted;

  const PushTokenCleanupResult({
    required this.profile,
    required this.deviceTokenDeleted,
  });

  /// Pushes can no longer reach this device for the signed-out account.
  bool get deviceDetached => deviceTokenDeleted;

  @override
  String toString() =>
      'PushTokenCleanupResult(profile: ${profile.name}, deviceTokenDeleted: $deviceTokenDeleted)';
}

class PushTokenCleanup {
  /// Returns this device's current token, or null if there is none.
  final Future<String?> Function() readDeviceToken;

  /// Clears users/{uid}.fcmToken only if it equals [token]. Returns true if
  /// it cleared the field, false if it held something else.
  final Future<bool> Function(String uid, String token)
      clearProfileTokenIfMatches;

  /// Deletes this device's token with Firebase Messaging.
  final Future<void> Function() deleteDeviceToken;

  /// Upper bound for each step so sign-out is never held up for long.
  final Duration stepTimeout;

  const PushTokenCleanup({
    required this.readDeviceToken,
    required this.clearProfileTokenIfMatches,
    required this.deleteDeviceToken,
    this.stepTimeout = const Duration(seconds: 5),
  });

  /// Runs both steps for the user [uid] who is about to sign out. Never
  /// throws; the result says what actually happened.
  Future<PushTokenCleanupResult> run(String? uid) async {
    String? token;
    try {
      token = await readDeviceToken().timeout(stepTimeout);
    } catch (_) {
      token = null;
    }

    var profile = ProfileTokenStatus.skipped;
    if (uid != null && uid.isNotEmpty && token != null && token.isNotEmpty) {
      try {
        final cleared =
            await clearProfileTokenIfMatches(uid, token).timeout(stepTimeout);
        profile = cleared
            ? ProfileTokenStatus.cleared
            : ProfileTokenStatus.notThisDevice;
      } catch (_) {
        profile = ProfileTokenStatus.failed;
      }
    }

    var deleted = false;
    try {
      await deleteDeviceToken().timeout(stepTimeout);
      deleted = true;
    } catch (_) {
      deleted = false;
    }

    return PushTokenCleanupResult(
        profile: profile, deviceTokenDeleted: deleted);
  }
}
