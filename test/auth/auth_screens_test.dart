// Login → OTP → destination through the real screens, with fakes behind
// the auth notifier. No Firebase project, no SMS.

import 'package:cts_transport_app/core/routes/app_routes.dart';
import 'package:cts_transport_app/features/auth/data/passenger_account_store.dart';
import 'package:cts_transport_app/features/auth/domain/otp_requester.dart';
import 'package:cts_transport_app/features/auth/presentation/login_screen.dart';
import 'package:cts_transport_app/features/auth/presentation/otp_verification_screen.dart';
import 'package:cts_transport_app/features/auth/providers/auth_providers.dart';
import 'package:cts_transport_app/features/auth/widgets/otp_code_field.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'auth_fakes.dart';

void main() {
  late FakeAuth auth;
  late FakeVerifier verifier;
  late FakeStore store;

  setUp(() {
    auth = FakeAuth();
    verifier = FakeVerifier();
    store = FakeStore()
      ..account = const PassengerAccount(
          exists: true,
          role: 'passenger',
          hasSeenWelcome: true,
          hasCreatedAt: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        firebaseAuthProvider.overrideWithValue(auth),
        otpRequesterProvider.overrideWithValue(
            OtpRequester<PhoneAuthCredential>(start: verifier.start)),
        passengerAccountStoreProvider.overrideWithValue(store),
        passengerSessionHooksProvider.overrideWithValue(FakeHooks()),
      ],
      child: MaterialApp(
        home: const LoginScreen(),
        routes: {
          AppRoutes.otpVerification: (_) => const OtpVerificationScreen(),
          AppRoutes.shell: (_) => const Scaffold(body: Text('SHELL')),
          AppRoutes.welcome: (_) => const Scaffold(body: Text('WELCOME')),
        },
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> requestCode(WidgetTester tester, String typed) async {
    await tester.enterText(find.byType(TextFormField).first, typed);
    await tester.tap(find.text('Continue'));
    await tester.pump();
  }

  Future<void> openOtpScreen(WidgetTester tester) async {
    await pumpApp(tester);
    await requestCode(tester, '024 412 3456');
    verifier.calls.single.codeSent('vid-1', 5);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a local Ghana number is sent to Firebase in E.164',
      (tester) async {
    await pumpApp(tester);
    await requestCode(tester, '024 412 3456');
    expect(verifier.calls.single.phone, '+233244123456');
    expect(find.textContaining('security check'), findsOneWidget,
        reason: 'request status is shown while waiting');

    // Answer the request so its watchdog timer is cancelled.
    verifier.calls.single.failed('network-request-failed');
    await tester.pump();
    expect(find.textContaining('security check'), findsNothing);
  });

  testWidgets('an invalid number is refused before Firebase', (tester) async {
    await pumpApp(tester);
    await requestCode(tester, '02441');
    expect(verifier.calls, isEmpty);
    expect(find.textContaining('valid Ghana mobile number'), findsOneWidget);
  });

  testWidgets('no OTP screen until Firebase confirms; errors are friendly',
      (tester) async {
    await pumpApp(tester);
    await requestCode(tester, '0244123456');
    verifier.calls.single.failed('too-many-requests');
    await tester.pump();
    expect(find.byType(OtpVerificationScreen), findsNothing);
    expect(find.textContaining('Too many attempts'), findsOneWidget);
  });

  testWidgets('pasted code signs in and opens the shell', (tester) async {
    await openOtpScreen(tester);
    expect(find.byType(OtpVerificationScreen), findsOneWidget);
    expect(find.textContaining('+233 24 412 3456', findRichText: true),
        findsOneWidget);

    await tester.enterText(
        find.descendant(
            of: find.byType(OtpCodeField), matching: find.byType(TextField)),
        '123456');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('SHELL'), findsOneWidget);
    expect(auth.signIns, 1);
  });

  testWidgets('a wrong code keeps the user on the OTP screen with a message',
      (tester) async {
    await openOtpScreen(tester);
    await tester.enterText(
        find.descendant(
            of: find.byType(OtpCodeField), matching: find.byType(TextField)),
        '000000');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('incorrect'), findsOneWidget);
    expect(find.byType(OtpVerificationScreen), findsOneWidget);

    // Leave the screen so its resend timer is disposed.
    await tester.enterText(
        find.descendant(
            of: find.byType(OtpCodeField), matching: find.byType(TextField)),
        '123456');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('resend is locked for 60 s, then uses the resend token',
      (tester) async {
    await openOtpScreen(tester);
    expect(find.textContaining('Resend code in', findRichText: true),
        findsOneWidget);
    expect(find.text('Resend code'), findsNothing);

    await tester.pump(const Duration(seconds: 60));
    await tester.tap(find.text('Resend code'));
    await tester.pump();
    expect(verifier.calls, hasLength(2));
    expect(verifier.calls[1].resendToken, 5);
    expect(verifier.calls[1].phone, '+233244123456');

    verifier.calls[1].codeSent('vid-2', 6);
    await tester.pump();
    expect(find.text('A new code has been sent'), findsOneWidget);
    expect(find.textContaining('Resend code in', findRichText: true),
        findsOneWidget);

    await tester.enterText(
        find.descendant(
            of: find.byType(OtpCodeField), matching: find.byType(TextField)),
        '123456');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  });
}
