// lib/features/auth/data/passenger_profile_check.dart
//
// Decides whether users/{uid} belongs to a registered passenger.
//
// Right after sign-in, Firestore may answer a plain get() from the local
// cache. On a fresh install that cache can hold only the push-token write
// (fcmToken, platform) and no `role`, which used to make a real passenger
// look unregistered and get signed out. Decisions that reject an account
// are therefore made only from the server copy.

import 'package:cloud_firestore/cloud_firestore.dart';

enum PassengerProfileStatus {
  /// users/{uid} exists and its role is passenger.
  passenger,

  /// The server says users/{uid} does not exist.
  notRegistered,

  /// The server says users/{uid} belongs to another role.
  otherRole,

  /// Only a cached copy was available and it does not confirm a passenger.
  /// Never treat this as "no account".
  unverified,
}

PassengerProfileStatus classifyPassengerProfile({
  required bool exists,
  required Map<String, dynamic>? data,
  required bool fromServer,
}) {
  final isPassenger = exists && data != null && data['role'] == 'passenger';
  if (isPassenger) return PassengerProfileStatus.passenger;
  if (!fromServer) return PassengerProfileStatus.unverified;
  if (!exists || data == null) return PassengerProfileStatus.notRegistered;
  return PassengerProfileStatus.otherRole;
}

class PassengerProfileRead {
  const PassengerProfileRead(this.snapshot, this.status);

  final DocumentSnapshot<Map<String, dynamic>> snapshot;
  final PassengerProfileStatus status;

  Map<String, dynamic>? get data => snapshot.data();
}

/// Reads users/{uid} from the server. When the server cannot be reached and
/// [allowCacheFallback] is true, falls back to the cached copy, which can
/// only ever confirm a passenger (see [PassengerProfileStatus.unverified]).
/// Throws when no copy can be read.
Future<PassengerProfileRead> readPassengerProfile(
  DocumentReference<Map<String, dynamic>> ref, {
  bool allowCacheFallback = false,
  Duration serverTimeout = const Duration(seconds: 10),
}) async {
  DocumentSnapshot<Map<String, dynamic>> snap;
  bool fromServer;
  try {
    snap = await ref
        .get(const GetOptions(source: Source.server))
        .timeout(serverTimeout);
    fromServer = true;
  } catch (_) {
    if (!allowCacheFallback) rethrow;
    snap = await ref.get(const GetOptions(source: Source.cache));
    fromServer = false;
  }
  return PassengerProfileRead(
    snap,
    classifyPassengerProfile(
      exists: snap.exists,
      data: snap.data(),
      fromServer: fromServer,
    ),
  );
}
