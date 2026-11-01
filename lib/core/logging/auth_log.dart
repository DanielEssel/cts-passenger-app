// lib/core/logging/auth_log.dart
//
// Logging for sign-in, session, profile and push-token code (AUTH-11).
// debugPrint is not stripped from release builds, and Firebase exception
// messages can contain document paths with UIDs, so:
//   - authLog prints in debug builds only;
//   - describeError keeps an error's type and Firebase code, never its text.
// Never pass a phone number, UID, OTP, verification ID or token to authLog.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

void authLog(String message) {
  if (kDebugMode) debugPrint(message);
}

String describeError(Object error) => error is FirebaseException
    ? '${error.plugin}/${error.code}'
    : error.runtimeType.toString();
