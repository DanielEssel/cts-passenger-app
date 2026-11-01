// Fakes for the passenger sign-in flow: FirebaseAuth, verifyPhoneNumber,
// users/{uid} and the push-token hooks. No Firebase project, no SMS.

import 'package:cts_transport_app/features/auth/data/passenger_account_store.dart';
import 'package:firebase_auth/firebase_auth.dart';

const phone = '+233244123456';
const uid = 'uid-passenger-1';

class FakeUser implements User {
  FakeUser(this.uid, this.phoneNumber);
  @override
  final String uid;
  @override
  final String? phoneNumber;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeUserCredential implements UserCredential {
  FakeUserCredential(this.user);
  @override
  final User? user;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeAuth implements FirebaseAuth {
  @override
  User? currentUser;

  /// The account a successful sign-in produces.
  User nextUser = FakeUser(uid, phone);
  String validCode = '123456';
  String? failWith;
  int signIns = 0;
  int signOuts = 0;

  @override
  Future<UserCredential> signInWithCredential(AuthCredential credential) async {
    signIns++;
    await Future<void>.delayed(Duration.zero);
    if (failWith != null) throw FirebaseAuthException(code: failWith!);
    if ((credential as PhoneAuthCredential).smsCode != validCode) {
      throw FirebaseAuthException(code: 'invalid-verification-code');
    }
    currentUser = nextUser;
    return FakeUserCredential(currentUser);
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    currentUser = null;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class VerifyCall {
  VerifyCall(
      this.phone, this.resendToken, this.codeSent, this.completed, this.failed);
  final String phone;
  final int? resendToken;
  final void Function(String, int?) codeSent;
  final void Function(PhoneAuthCredential) completed;
  final void Function(String) failed;
}

class FakeVerifier {
  final calls = <VerifyCall>[];

  Future<void> start({
    required String phoneNumber,
    int? resendToken,
    required void Function(String, int?) codeSent,
    required void Function(PhoneAuthCredential) verificationCompleted,
    required void Function(String) verificationFailed,
  }) async {
    calls.add(VerifyCall(phoneNumber, resendToken, codeSent,
        verificationCompleted, verificationFailed));
  }
}

class FakeStore implements PassengerAccountStore {
  PassengerAccount account = const PassengerAccount(exists: false);
  bool readThrows = false;
  bool createThrows = false;
  final created = <(String, PassengerSignupDetails, bool)>[];
  final logins = <String>[];

  @override
  Future<PassengerAccount> read(String uid) async {
    if (readThrows) throw Exception('unavailable');
    return account;
  }

  @override
  Future<void> createPassenger(String uid, PassengerSignupDetails details,
      {required bool stampCreation}) async {
    if (createThrows) throw Exception('unavailable');
    created.add((uid, details, stampCreation));
  }

  @override
  Future<void> recordLogin(String uid) async => logins.add(uid);
}

class FakeHooks extends PassengerSessionHooks {
  int cleared = 0;
  int saved = 0;
  @override
  Future<void> clearPushToken() async => cleared++;
  @override
  Future<void> savePushToken() async => saved++;
}
