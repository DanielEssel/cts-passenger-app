// lib/features/auth/data/passenger_account_store.dart
//
// What the sign-in flow needs from users/{uid}, behind an interface so the
// flow can be tested without Firestore. Every read that decides an account's
// fate comes from the server (see passenger_profile_check.dart).

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../home/services/notification_service.dart';

/// The server copy of users/{uid}, reduced to what sign-in decides on.
class PassengerAccount {
  const PassengerAccount({
    required this.exists,
    this.role,
    this.hasSeenWelcome = false,
    this.hasCreatedAt = false,
  });

  final bool exists;
  final String? role;
  final bool hasSeenWelcome;

  /// False for a role-less stub (an older app version's push-token write).
  final bool hasCreatedAt;

  bool get isPassenger => role == 'passenger';

  /// Belongs to someone else's role (driver, admin...). Never taken over.
  bool get isOtherRole => role != null && role!.isNotEmpty && !isPassenger;
}

class PassengerSignupDetails {
  const PassengerSignupDetails({
    required this.firstName,
    required this.lastName,
    required this.phoneNumber,
    required this.email,
  });

  final String firstName;
  final String lastName;
  final String phoneNumber;
  final String email;
}

abstract class PassengerAccountStore {
  /// Reads users/{uid} from the server. Throws when the server can't be
  /// reached: no decision is made from a cached copy.
  Future<PassengerAccount> read(String uid);

  /// Creates the passenger profile (merging into a role-less stub).
  /// [stampCreation] writes createdAt and termsAcceptedAt.
  Future<void> createPassenger(
    String uid,
    PassengerSignupDetails details, {
    required bool stampCreation,
  });

  /// Stamps lastLoginAt on an existing passenger profile.
  Future<void> recordLogin(String uid);
}

class FirestorePassengerAccountStore implements PassengerAccountStore {
  FirestorePassengerAccountStore(this._db);

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('users').doc(uid);

  @override
  Future<PassengerAccount> read(String uid) async {
    final snap = await _doc(uid)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 10));
    final data = snap.data();
    if (!snap.exists || data == null) {
      return const PassengerAccount(exists: false);
    }
    return PassengerAccount(
      exists: true,
      role: data['role'] as String?,
      hasSeenWelcome: data['hasSeenWelcome'] as bool? ?? false,
      hasCreatedAt: data['createdAt'] != null,
    );
  }

  @override
  Future<void> createPassenger(
    String uid,
    PassengerSignupDetails d, {
    required bool stampCreation,
  }) {
    return _doc(uid).set({
      'uid': uid,
      'firstName': d.firstName,
      'lastName': d.lastName,
      'displayName': '${d.firstName} ${d.lastName}',
      'phoneNumber': d.phoneNumber,
      'email': d.email.isNotEmpty ? d.email : null,
      'role': 'passenger',
      'hasSeenWelcome': false,
      if (stampCreation) 'termsAcceptedAt': FieldValue.serverTimestamp(),
      if (stampCreation) 'createdAt': FieldValue.serverTimestamp(),
      'termsVersion': '1.0',
      'lastLoginAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  @override
  Future<void> recordLogin(String uid) =>
      _doc(uid).update({'lastLoginAt': FieldValue.serverTimestamp()});
}

/// Push-token side effects of signing in and out. Neither throws.
class PassengerSessionHooks {
  const PassengerSessionHooks();

  /// Detaches this device from the account's pushes (while signed in).
  Future<void> clearPushToken() => NotificationService.instance.clearToken();

  /// Saves the token once the profile exists (the sign-in save was skipped).
  Future<void> savePushToken() async {
    try {
      await NotificationService.instance.saveCurrentToken();
    } catch (_) {}
  }
}
