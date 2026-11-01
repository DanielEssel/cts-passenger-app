// The passenger phone sign-in flow end to end, against fakes:
// FirebaseAuth, verifyPhoneNumber, users/{uid} and the push-token hooks.
// No Firebase project, no SMS.

import 'package:cts_transport_app/core/routes/app_routes.dart';
import 'package:cts_transport_app/features/auth/data/passenger_account_store.dart';
import 'package:cts_transport_app/features/auth/domain/otp_requester.dart';
import 'package:cts_transport_app/features/auth/providers/auth_providers.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'auth_fakes.dart';

const registered = PassengerAccount(
    exists: true, role: 'passenger', hasSeenWelcome: true, hasCreatedAt: true);

void main() {
  late FakeAuth auth;
  late FakeVerifier verifier;
  late FakeStore store;
  late FakeHooks hooks;
  late OtpRequester<PhoneAuthCredential> requester;
  late ProviderContainer container;
  late List<String> routes;
  late List<String> errors;
  late int codesSent;

  AuthNotifier notifier() => container.read(authProvider.notifier);
  AuthState state() => container.read(authProvider);

  setUp(() {
    auth = FakeAuth();
    verifier = FakeVerifier();
    store = FakeStore();
    hooks = FakeHooks();
    requester = OtpRequester<PhoneAuthCredential>(start: verifier.start);
    container = ProviderContainer(overrides: [
      firebaseAuthProvider.overrideWithValue(auth),
      otpRequesterProvider.overrideWithValue(requester),
      passengerAccountStoreProvider.overrideWithValue(store),
      passengerSessionHooksProvider.overrideWithValue(hooks),
    ]);
    routes = [];
    errors = [];
    codesSent = 0;
  });

  tearDown(() => container.dispose());

  Future<void> requestLogin() async {
    await notifier().sendOtp(
      phone: phone,
      onCodeSent: () => codesSent++,
      onAuthenticated: routes.add,
      onError: errors.add,
    );
    await pumpEventQueue();
  }

  Future<void> requestSignup() async {
    await notifier().signUp(
      firstName: 'Ama',
      lastName: 'Mensah',
      phone: phone,
      email: '',
      onCodeSent: () => codesSent++,
      onAuthenticated: routes.add,
      onError: errors.add,
    );
    await pumpEventQueue();
  }

  Future<bool> enter(String code) => notifier().verifyOtp(
      smsCode: code, onAuthenticated: routes.add, onError: errors.add);

  PhoneAuthCredential autoCredential() =>
      PhoneAuthProvider.credential(verificationId: 'vid-1', smsCode: '123456');

  group('requesting a code', () {
    test('success: the OTP screen opens only after codeSent', () async {
      await requestLogin();
      expect(verifier.calls.single.phone, phone);
      expect(codesSent, 0, reason: 'nothing was confirmed yet');
      expect(state().isLoading, isTrue);

      verifier.calls.single.codeSent('vid-1', 5);
      expect(codesSent, 1);
      expect(state().verificationId, 'vid-1');
      expect(state().isLoading, isFalse);
    });

    test('failure: a friendly message, no OTP screen', () async {
      await requestLogin();
      verifier.calls.single.failed('quota-exceeded');
      expect(codesSent, 0);
      expect(errors.single, contains("can't send verification codes"));
      expect(state().isLoading, isFalse);
      expect(state().verificationId, isNull);
    });

    test('repeated taps send one request', () async {
      await requestLogin();
      await requestLogin();
      expect(verifier.calls, hasLength(1));
    });

    test('resend uses the resend token; a failed resend keeps the session',
        () async {
      await requestLogin();
      verifier.calls[0].codeSent('vid-1', 5);

      await notifier().resendOtp(
          phone: phone,
          onCodeSent: () => codesSent++,
          onAuthenticated: routes.add,
          onError: errors.add);
      await pumpEventQueue();
      expect(verifier.calls[1].resendToken, 5);
      verifier.calls[1].failed('too-many-requests');
      expect(state().verificationId, 'vid-1');

      await notifier().resendOtp(
          phone: phone,
          onCodeSent: () => codesSent++,
          onAuthenticated: routes.add,
          onError: errors.add);
      await pumpEventQueue();
      verifier.calls[2].codeSent('vid-2', 6);
      expect(state().verificationId, 'vid-2');
      expect(codesSent, 2);
    });

    test('watchdog: Firebase never answers', () async {
      requester = OtpRequester<PhoneAuthCredential>(
          start: verifier.start, watchdog: const Duration(milliseconds: 20));
      container.dispose();
      container = ProviderContainer(overrides: [
        firebaseAuthProvider.overrideWithValue(auth),
        otpRequesterProvider.overrideWithValue(requester),
        passengerAccountStoreProvider.overrideWithValue(store),
        passengerSessionHooksProvider.overrideWithValue(hooks),
      ]);
      await requestLogin();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(state().isLoading, isFalse);
      expect(errors.single, contains("couldn't confirm that a code was sent"));
    });
  });

  group('verifying', () {
    setUp(() => store.account = registered);

    test('manual entry: existing passenger goes to the shell', () async {
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      expect(await enter('123456'), isTrue);
      expect(routes, [AppRoutes.shell]);
      expect(store.logins, [uid]);
      expect(store.created, isEmpty, reason: 'login never writes a profile');
      expect(state().verificationId, isNull);
    });

    test("existing passenger who hasn't seen the welcome goes there", () async {
      store.account = const PassengerAccount(
          exists: true, role: 'passenger', hasCreatedAt: true);
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      await enter('123456');
      expect(routes, [AppRoutes.welcome]);
    });

    test('incorrect code: message, nobody signed in, retry works', () async {
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      expect(await enter('000000'), isFalse);
      expect(errors.single, contains('incorrect'));
      expect(auth.currentUser, isNull);
      expect(auth.signOuts, 0);
      expect(state().verificationId, 'vid-1', reason: 'same session, retry');

      expect(await enter('123456'), isTrue);
      expect(routes, [AppRoutes.shell]);
    });

    test('expired code asks for a new one', () async {
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      auth.failWith = 'session-expired';
      expect(await enter('123456'), isFalse);
      expect(errors.single, contains('expired'));
      expect(routes, isEmpty);
    });

    test('a short code is refused before Firebase', () async {
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      expect(await enter('123'), isFalse);
      expect(auth.signIns, 0);
    });

    test('double submission signs in and navigates once', () async {
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      final results = await Future.wait([enter('123456'), enter('123456')]);
      expect(results.where((r) => r), hasLength(1));
      expect(auth.signIns, 1);
      expect(routes, [AppRoutes.shell]);
    });

    test('automatic verification completes the login', () async {
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      verifier.calls.single.completed(autoCredential());
      await pumpEventQueue();
      expect(routes, [AppRoutes.shell]);
      expect(auth.signIns, 1);
    });

    test('instant verification without codeSent also completes', () async {
      await requestLogin();
      verifier.calls.single.completed(autoCredential());
      await pumpEventQueue();
      expect(codesSent, 0);
      expect(routes, [AppRoutes.shell]);
    });

    test('auto-verification racing a typed code: one sign-in', () async {
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      final typed = enter('123456');
      verifier.calls.single.completed(autoCredential());
      await typed;
      await pumpEventQueue();
      expect(auth.signIns, 1);
      expect(routes, [AppRoutes.shell]);
    });

    test('a late auto-retrieval after success is ignored', () async {
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      await enter('123456');
      verifier.calls.single.completed(autoCredential());
      await pumpEventQueue();
      expect(auth.signIns, 1);
      expect(routes, hasLength(1));
    });

    test('session-expired after the other path signed this number in',
        () async {
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      auth.currentUser = FakeUser(uid, phone);
      auth.failWith = 'session-expired';
      expect(await enter('123456'), isTrue);
      expect(routes, [AppRoutes.shell]);
    });

    test('a different signed-in account is never taken as this sign-in',
        () async {
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      auth.currentUser = FakeUser('someone-else', '+233200000000');
      auth.failWith = 'session-expired';
      expect(await enter('123456'), isFalse);
      expect(routes, isEmpty);
      expect(errors.single, contains('expired'));
    });
  });

  group('account checks after Firebase sign-in', () {
    Future<void> signInWith(PassengerAccount account) async {
      store.account = account;
      await requestLogin();
      verifier.calls.single.codeSent('vid-1', 5);
      await enter('123456');
    }

    void expectSignedOut() {
      expect(routes, isEmpty);
      expect(auth.currentUser, isNull);
      expect(auth.signOuts, 1);
      expect(hooks.cleared, 1);
      expect(state().user, isNull);
      expect(state().isLoading, isFalse);
    }

    test('no passenger account: signed out, told to sign up', () async {
      await signInWith(const PassengerAccount(exists: false));
      expectSignedOut();
      expect(errors.single, contains('sign up first'));
    });

    test('a driver number cannot enter the passenger app', () async {
      await signInWith(const PassengerAccount(exists: true, role: 'driver'));
      expectSignedOut();
      expect(errors.single, contains('driver'));
    });

    test('Firestore unreachable: signed out, not half signed in', () async {
      store.readThrows = true;
      await signInWith(registered);
      expectSignedOut();
      expect(errors.single, contains('connection'));
    });
  });

  group('sign-up', () {
    Future<void> verifySignup() async {
      await requestSignup();
      verifier.calls.single.codeSent('vid-1', 5);
      await enter('123456');
    }

    test('new passenger: profile created with the verified number', () async {
      auth.nextUser = FakeUser(uid, phone);
      await verifySignup();
      final (createdUid, details, stamp) = store.created.single;
      expect(createdUid, uid);
      expect(details.phoneNumber, phone);
      expect(details.firstName, 'Ama');
      expect(stamp, isTrue);
      expect(hooks.saved, 1);
      expect(routes, [AppRoutes.welcome]);
    });

    test('existing passenger: signed in, profile not overwritten', () async {
      store.account = registered;
      await verifySignup();
      expect(store.created, isEmpty);
      expect(routes, [AppRoutes.shell]);
    });

    test('a role-less stub is completed, creation stamped once', () async {
      store.account = const PassengerAccount(exists: true);
      await verifySignup();
      expect(store.created.single.$3, isTrue);
    });

    test('a driver number cannot sign up as a passenger', () async {
      store.account = const PassengerAccount(exists: true, role: 'driver');
      await verifySignup();
      expect(store.created, isEmpty);
      expect(auth.currentUser, isNull);
      expect(routes, isEmpty);
    });

    test('profile write fails: signed out with a retry message', () async {
      store.createThrows = true;
      await verifySignup();
      expect(auth.currentUser, isNull);
      expect(errors.single, contains("couldn't finish creating"));
      expect(routes, isEmpty);
    });

    test('automatic verification also creates the profile', () async {
      await requestSignup();
      verifier.calls.single.completed(autoCredential());
      await pumpEventQueue();
      expect(store.created, hasLength(1));
      expect(routes, [AppRoutes.welcome]);
    });
  });

  test('sign-out clears the push token, signs out and drops callbacks',
      () async {
    store.account = registered;
    await requestLogin();
    verifier.calls.single.codeSent('vid-1', 5);
    await enter('123456');

    await notifier().signOut();
    expect(hooks.cleared, 1);
    expect(auth.currentUser, isNull);
    expect(state().user, isNull);

    verifier.calls.single.completed(autoCredential());
    await pumpEventQueue();
    expect(auth.signIns, 1, reason: 'no sign-in after sign-out');
  });

  test('logs never contain the phone number or the uid', () async {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
    addTearDown(() => debugPrint = original);

    store.account = registered;
    await requestLogin();
    verifier.calls.single.codeSent('vid-1', 5);
    await enter('000000');
    await enter('123456');

    expect(logs, isNotEmpty);
    for (final line in logs) {
      expect(line, isNot(contains('244123456')));
      expect(line, isNot(contains(uid)));
      expect(line, isNot(contains('123456')));
    }
  });
}
