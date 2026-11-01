// The OTP request gate: one request at a time, stale callbacks ignored,
// watchdog, and the optional one-time reCAPTCHA retry. No Firebase, no SMS.

import 'package:cts_transport_app/features/auth/domain/auth_error_messages.dart';
import 'package:cts_transport_app/features/auth/domain/otp_requester.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records each verifyPhoneNumber call so a test can answer it later.
class FakeFirebase {
  final calls = <Call>[];

  Future<void> start({
    required String phoneNumber,
    int? resendToken,
    required void Function(String, int?) codeSent,
    required void Function(String) verificationCompleted,
    required void Function(String) verificationFailed,
  }) async {
    calls.add(Call(phoneNumber, resendToken, codeSent, verificationCompleted,
        verificationFailed));
  }
}

class Call {
  Call(
      this.phone, this.resendToken, this.codeSent, this.completed, this.failed);
  final String phone;
  final int? resendToken;
  final void Function(String, int?) codeSent;
  final void Function(String) completed;
  final void Function(String) failed;
}

class Events {
  final codeSent = <String>[];
  final autoVerified = <String>[];
  final failed = <String>[];

  bool request(OtpRequester<String> r, String phone, {int? resendToken}) =>
      r.request(
        phoneNumber: phone,
        resendToken: resendToken,
        onCodeSent: (id, _) => codeSent.add(id),
        onAutoVerified: autoVerified.add,
        onFailed: failed.add,
      );
}

void main() {
  late FakeFirebase firebase;
  late Events events;

  setUp(() {
    firebase = FakeFirebase();
    events = Events();
  });

  OtpRequester<String> requester({
    Future<void> Function()? forceRecaptcha,
    Duration watchdog = const Duration(seconds: 120),
  }) =>
      OtpRequester<String>(
        start: firebase.start,
        forceRecaptcha: forceRecaptcha,
        watchdog: watchdog,
      );

  test('success: codeSent is delivered and the lock is released', () async {
    final r = requester();
    expect(events.request(r, '+233244123456'), isTrue);
    await pumpEventQueue();
    expect(r.isWaiting, isTrue);
    firebase.calls.single.codeSent('vid-1', 7);
    expect(events.codeSent, ['vid-1']);
    expect(r.isWaiting, isFalse);
  });

  test('failure: the Firebase code is passed on', () async {
    final r = requester();
    events.request(r, '+233244123456');
    await pumpEventQueue();
    firebase.calls.single.failed('too-many-requests');
    expect(events.failed, ['too-many-requests']);
    expect(r.isWaiting, isFalse);
  });

  test('repeated taps start one request', () async {
    final r = requester();
    expect(events.request(r, '+233244123456'), isTrue);
    expect(events.request(r, '+233244123456'), isFalse);
    await pumpEventQueue();
    expect(firebase.calls, hasLength(1));
  });

  test('a resend passes the resend token', () async {
    final r = requester();
    events.request(r, '+233244123456');
    await pumpEventQueue();
    firebase.calls[0].codeSent('vid-1', 7);
    events.request(r, '+233244123456', resendToken: 7);
    await pumpEventQueue();
    expect(firebase.calls[1].resendToken, 7);
  });

  test('automatic verification is delivered before or after codeSent',
      () async {
    final r = requester();
    events.request(r, '+233244123456');
    await pumpEventQueue();
    firebase.calls.single.codeSent('vid-1', 7);
    firebase.calls.single.completed('credential');
    expect(events.autoVerified, ['credential']);
  });

  test("an older request's callbacks are ignored", () async {
    final r = requester();
    events.request(r, '+233244111111');
    await pumpEventQueue();
    firebase.calls[0].codeSent('old', 1);
    events.request(r, '+233244222222');
    await pumpEventQueue();

    // The first request's auto-retrieval fires late: it must not sign in.
    firebase.calls[0].completed('old-credential');
    firebase.calls[0].codeSent('old-again', 2);
    expect(events.autoVerified, isEmpty);
    expect(events.codeSent, ['old']);

    firebase.calls[1].codeSent('new', 3);
    expect(events.codeSent, ['old', 'new']);
  });

  test('cancel drops pending callbacks (sign-out, leaving the flow)', () async {
    final r = requester();
    events.request(r, '+233244123456');
    await pumpEventQueue();
    r.cancel();
    firebase.calls.single.completed('credential');
    firebase.calls.single.failed('session-expired');
    expect(events.autoVerified, isEmpty);
    expect(events.failed, isEmpty);
    expect(r.isWaiting, isFalse);
  });

  test('watchdog releases a request Firebase never answers', () async {
    final r = requester(watchdog: const Duration(milliseconds: 20));
    events.request(r, '+233244123456');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(events.failed, [otpRequestTimeoutCode]);
    expect(r.isWaiting, isFalse);
    // The user can try again straight away.
    expect(events.request(r, '+233244123456'), isTrue);
  });

  test('a throwing start is reported, not left waiting', () async {
    final r = OtpRequester<String>(
      start: ({
        required String phoneNumber,
        int? resendToken,
        required void Function(String, int?) codeSent,
        required void Function(String) verificationCompleted,
        required void Function(String) verificationFailed,
      }) async =>
          throw StateError('plugin missing'),
    );
    events.request(r, '+233244123456');
    await pumpEventQueue();
    expect(events.failed, ['unknown']);
    expect(r.isWaiting, isFalse);
  });

  group('reCAPTCHA fallback', () {
    test('without forceRecaptcha, app verification failures are reported',
        () async {
      final r = requester();
      events.request(r, '+233244123456');
      await pumpEventQueue();
      firebase.calls.single.failed('invalid-app-credential');
      expect(events.failed, ['invalid-app-credential']);
      expect(firebase.calls, hasLength(1));
    });

    for (final code in appVerificationFailureCodes) {
      test('$code: switches to reCAPTCHA and retries once', () async {
        var forced = 0;
        final r = requester(forceRecaptcha: () async => forced++);
        events.request(r, '+233244123456');
        await pumpEventQueue();
        firebase.calls[0].failed(code);
        await pumpEventQueue();

        expect(forced, 1);
        expect(firebase.calls, hasLength(2));
        expect(events.failed, isEmpty);
        expect(r.isWaiting, isTrue);

        firebase.calls[1].codeSent('vid-recaptcha', 1);
        expect(events.codeSent, ['vid-recaptcha']);
      });
    }

    test('a second app verification failure is reported, not retried again',
        () async {
      var forced = 0;
      final r = requester(forceRecaptcha: () async => forced++);
      events.request(r, '+233244123456');
      await pumpEventQueue();
      firebase.calls[0].failed('invalid-app-credential');
      await pumpEventQueue();
      firebase.calls[1].failed('invalid-app-credential');
      await pumpEventQueue();
      expect(forced, 1);
      expect(firebase.calls, hasLength(2));
      expect(events.failed, ['invalid-app-credential']);
    });

    test('other failures never trigger the retry', () async {
      var forced = 0;
      final r = requester(forceRecaptcha: () async => forced++);
      events.request(r, '+233244123456');
      await pumpEventQueue();
      firebase.calls[0].failed('too-many-requests');
      await pumpEventQueue();
      expect(forced, 0);
      expect(events.failed, ['too-many-requests']);
    });
  });
}
