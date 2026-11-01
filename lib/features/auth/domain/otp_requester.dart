// lib/features/auth/domain/otp_requester.dart
//
// The lifecycle of Firebase verifyPhoneNumber requests, without Firebase.
//
// - One request waits for Firebase at a time; repeated taps are ignored.
// - Only the latest request's callbacks count. Firebase keeps a request
//   alive after codeSent (auto-retrieval runs until its timeout), so an old
//   request could otherwise sign the user in, or replace the current
//   verificationId, after they have re-requested or changed the number.
// - A watchdog releases the lock if Firebase never answers (AUTH-17).
// - [forceRecaptcha], when given, is called once when app verification
//   fails (Play Integrity), and the request is retried through reCAPTCHA.
//   Without it the SDK's own reCAPTCHA fallback is relied on.

import 'dart:async';

import 'auth_error_messages.dart';

/// Starts one Firebase verification. Errors are reported through
/// [verificationFailed] with the Firebase error code.
typedef StartPhoneVerification<C> = Future<void> Function({
  required String phoneNumber,
  int? resendToken,
  required void Function(String verificationId, int? resendToken) codeSent,
  required void Function(C credential) verificationCompleted,
  required void Function(String code) verificationFailed,
});

/// Error codes Firebase returns when the app could not be verified.
const appVerificationFailureCodes = {
  'app-not-authorized',
  'invalid-app-credential'
};

class OtpRequester<C> {
  OtpRequester({
    required this.start,
    this.forceRecaptcha,
    this.watchdog = const Duration(seconds: 120),
  });

  final StartPhoneVerification<C> start;
  final Future<void> Function()? forceRecaptcha;

  /// Long enough for a user to finish a reCAPTCHA challenge in the browser.
  final Duration watchdog;

  int _generation = 0;
  bool _waiting = false;
  Timer? _timer;

  /// True while a request waits for codeSent, completion or failure.
  bool get isWaiting => _waiting;

  /// Drops every earlier request's callbacks (sign-out, leaving the flow).
  void cancel() {
    _generation++;
    _settle();
  }

  /// Requests a code for [phoneNumber]. Returns false, and does nothing,
  /// while another request is still waiting.
  ///
  /// [onAutoVerified] can arrive before or after [onCodeSent] (instant
  /// verification or auto-retrieved SMS) until a newer request starts.
  bool request({
    required String phoneNumber,
    int? resendToken,
    required void Function(String verificationId, int? resendToken) onCodeSent,
    required void Function(C credential) onAutoVerified,
    required void Function(String code) onFailed,
  }) {
    if (_waiting) return false;
    final generation = ++_generation;
    _waiting = true;
    _timer = Timer(watchdog, () {
      if (generation != _generation || !_waiting) return;
      _settle();
      onFailed(otpRequestTimeoutCode);
    });
    _start(
      generation,
      phoneNumber,
      resendToken,
      viaRecaptcha: false,
      onCodeSent: onCodeSent,
      onAutoVerified: onAutoVerified,
      onFailed: onFailed,
    );
    return true;
  }

  Future<void> _start(
    int generation,
    String phoneNumber,
    int? resendToken, {
    required bool viaRecaptcha,
    required void Function(String, int?) onCodeSent,
    required void Function(C) onAutoVerified,
    required void Function(String) onFailed,
  }) async {
    bool current() => generation == _generation;

    void fail(String code) {
      if (!current()) return;
      _settle();
      onFailed(code);
    }

    try {
      await start(
        phoneNumber: phoneNumber,
        resendToken: resendToken,
        codeSent: (verificationId, token) {
          if (!current()) return;
          _settle();
          onCodeSent(verificationId, token);
        },
        verificationCompleted: (credential) {
          if (!current()) return;
          _settle();
          onAutoVerified(credential);
        },
        verificationFailed: (code) async {
          if (!current()) return;
          final retry = forceRecaptcha;
          if (retry != null &&
              !viaRecaptcha &&
              appVerificationFailureCodes.contains(code)) {
            try {
              await retry();
            } catch (_) {
              fail(code);
              return;
            }
            if (!current()) return;
            await _start(
              generation,
              phoneNumber,
              resendToken,
              viaRecaptcha: true,
              onCodeSent: onCodeSent,
              onAutoVerified: onAutoVerified,
              onFailed: onFailed,
            );
            return;
          }
          fail(code);
        },
      );
    } catch (_) {
      fail('unknown');
    }
  }

  void _settle() {
    _waiting = false;
    _timer?.cancel();
    _timer = null;
  }
}
