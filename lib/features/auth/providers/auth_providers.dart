// lib/features/auth/providers/auth_providers.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

// ── Firebase instances ────────────────────────────────────────────────────────

final firebaseAuthProvider = Provider<FirebaseAuth>(
  (_) => FirebaseAuth.instance,
);

final firestoreProvider = Provider<FirebaseFirestore>(
  (_) => FirebaseFirestore.instance,
);

// ── Auth state stream ─────────────────────────────────────────────────────────

final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(firebaseAuthProvider).authStateChanges();
});

// ── Current user from Firestore ───────────────────────────────────────────────

final currentUserProvider = FutureProvider<UserData?>((ref) async {
  final user = ref.watch(authStateProvider).value;
  if (user == null) return null;

  final doc = await ref
      .watch(firestoreProvider)
      .collection('users')
      .doc(user.uid)
      .get();

  return doc.exists ? UserData.fromFirestore(doc) : null;
});

// ── Convenience providers ─────────────────────────────────────────────────────

final isAuthenticatedProvider = Provider<bool>((ref) {
  return ref.watch(authStateProvider).value != null;
});

final userIdProvider = Provider<String?>((ref) {
  return ref.watch(authStateProvider).value?.uid;
});

final userPhoneProvider = Provider<String?>((ref) {
  return ref.watch(authStateProvider).value?.phoneNumber;
});

final userRoleProvider = Provider<String?>((ref) {
  return ref.watch(currentUserProvider).value?.role;
});

final isPassengerProvider = Provider<bool>((ref) {
  final role = ref.watch(userRoleProvider);
  return role == 'passenger' || role == null;
});

// ── Auth state ────────────────────────────────────────────────────────────────

class AuthState {
  final bool isLoading;
  final String? error;
  final User? user;
  final String? verificationId; // held between sendOtp → verifyOtp

  const AuthState({
    this.isLoading = false,
    this.error,
    this.user,
    this.verificationId,
  });

  AuthState copyWith({
    bool? isLoading,
    String? error,
    User? user,
    String? verificationId,
  }) =>
      AuthState(
        isLoading: isLoading ?? this.isLoading,
        error: error, // null clears intentionally
        user: user ?? this.user,
        verificationId: verificationId ?? this.verificationId,
      );
}

// ── Auth notifier ─────────────────────────────────────────────────────────────

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthState();

  FirebaseAuth get _auth => ref.read(firebaseAuthProvider);
  FirebaseFirestore get _firestore => ref.read(firestoreProvider);

  // ── Send OTP (login flow) ─────────────────────────────────────────────────
  // Called from LoginScreen. Stores verificationId internally; screen
  // navigates to OTP screen and calls verifyOtp() when code is entered.

  Future<void> sendOtp({
    required String phone,
    required VoidCallback onCodeSent,
    required void Function(String) onError,
  }) async {
    state = state.copyWith(isLoading: true);

    await _auth.verifyPhoneNumber(
      phoneNumber: phone,
      timeout: const Duration(seconds: 60),

      // ── Auto-retrieval (Android SMS) ───────────────────────────────────
      verificationCompleted: (PhoneAuthCredential credential) async {
        await _signInWithCredential(credential, onError: onError);
      },

      // ── Hard failure ───────────────────────────────────────────────────
      verificationFailed: (FirebaseAuthException e) {
        state = state.copyWith(
          isLoading: false,
          error: _phoneErrorMessage(e.code, e.message),
        );
        onError(_phoneErrorMessage(e.code, e.message));
      },

      // ── Code sent — navigate to OTP screen ────────────────────────────
      codeSent: (String verificationId, int? resendToken) {
        state = state.copyWith(
          isLoading: false,
          verificationId: verificationId,
        );
        onCodeSent();
      },

      codeAutoRetrievalTimeout: (_) {},
    );
  }

  // ── Sign up (new passenger) ───────────────────────────────────────────────
  // Creates a Firestore user doc after OTP verification.
  // Sends OTP first; profile data is persisted after verification.

  Future<void> signUp({
    required String firstName,
    required String lastName,
    required String phone,
    required String email,
    required VoidCallback onCodeSent,
    required void Function(String) onError,
  }) async {
    state = state.copyWith(isLoading: true);

    await _auth.verifyPhoneNumber(
      phoneNumber: phone,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (PhoneAuthCredential credential) async {
        final user = await _signInWithCredential(
          credential,
          onError: onError,
        );
        if (user != null) {
          await _createPassengerProfile(
            user: user,
            firstName: firstName,
            lastName: lastName,
            phone: phone,
            email: email,
          );
        }
      },
      verificationFailed: (FirebaseAuthException e) {
        state = state.copyWith(
          isLoading: false,
          error: _phoneErrorMessage(e.code, e.message),
        );
        onError(_phoneErrorMessage(e.code, e.message));
      },
      codeSent: (String verificationId, int? resendToken) {
        // Store profile data in state so verifyOtp can persist it after OTP
        state = state.copyWith(
          isLoading: false,
          verificationId: verificationId,
        );
        // Pass pending profile via the callback so OTP screen can forward it
        onCodeSent();
      },
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  // ── Verify OTP ────────────────────────────────────────────────────────────
  // Called from OtpVerificationScreen with the 6-digit code.
  // Pass pendingProfile only during sign-up to create the Firestore doc.

  Future<bool> verifyOtp({
    required String smsCode,
    Map<String, dynamic>? pendingProfile,
    required void Function(String) onError,
  }) async {
    final verificationId = state.verificationId;
    if (verificationId == null) {
      onError('Session expired. Please request a new code.');
      return false;
    }

    state = state.copyWith(isLoading: true);

    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode,
    );

    final user = await _signInWithCredential(credential, onError: onError);
    if (user == null) return false;

    // For sign-up: create Firestore profile if it doesn't exist yet
    if (pendingProfile != null) {
      await _createPassengerProfile(
        user: user,
        firstName: pendingProfile['firstName'] as String? ?? '',
        lastName: pendingProfile['lastName'] as String? ?? '',
        phone: pendingProfile['phone'] as String? ?? user.phoneNumber ?? '',
        email: pendingProfile['email'] as String? ?? '',
      );
    }

    return true;
  }

  // ── Sign out ──────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    state = state.copyWith(isLoading: true);
    await _auth.signOut();
    state = const AuthState();
  }

  // ── Update profile ────────────────────────────────────────────────────────

  Future<bool> updateUserProfile({
    String? displayName,
    String? photoURL,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      await user.updateDisplayName(displayName);
      await user.updatePhotoURL(photoURL);
      await _firestore.collection('users').doc(user.uid).update({
        'displayName': displayName,
        'photoURL': photoURL,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      state = state.copyWith(error: 'Failed to update profile: $e');
      return false;
    }
  }

  void clearError() => state = state.copyWith(error: null);

  // ── Private helpers ───────────────────────────────────────────────────────

  Future<User?> _signInWithCredential(
    PhoneAuthCredential credential, {
    required void Function(String) onError,
  }) async {
    try {
      final result = await _auth.signInWithCredential(credential);
      state = state.copyWith(isLoading: false, user: result.user);
      return result.user;
    } on FirebaseAuthException catch (e) {
      final msg = _phoneErrorMessage(e.code, e.message);
      state = state.copyWith(isLoading: false, error: msg);
      onError(msg);
      return null;
    } catch (e) {
      const msg = 'An unexpected error occurred';
      state = state.copyWith(isLoading: false, error: msg);
      onError(msg);
      return null;
    }
  }

  Future<void> _createPassengerProfile({
  required User user,
  required String firstName,
  required String lastName,
  required String phone,
  required String email,
}) async {
  // Reload to ensure the auth token is fully settled after OTP sign-in
  await user.reload();
  final freshUser = _auth.currentUser;
  if (freshUser == null) return;

  await _firestore.collection('users').doc(freshUser.uid).set({
    'uid':         freshUser.uid,
    'firstName':   firstName,
    'lastName':    lastName,
    'displayName': '$firstName $lastName',
    'phoneNumber': phone,
    'email':       email.isNotEmpty ? email : null,
    'role':        'passenger',
    'createdAt':   FieldValue.serverTimestamp(),
    'lastLoginAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  // Wallet is created by a Cloud Function triggered on users/{uid} onCreate.
  // Do NOT write to /wallets from the client — rules block it.


    }

  }

  String _phoneErrorMessage(String code, String? message) {
    return switch (code) {
      'invalid-phone-number' =>
        'Invalid phone number. Include country code (e.g. +233).',
      'too-many-requests' => 'Too many attempts. Please try again later.',
      'session-expired' => 'Code expired. Please request a new one.',
      'invalid-verification-code' => 'Incorrect code. Please try again.',
      'quota-exceeded' => 'SMS quota exceeded. Please try again later.',
      'missing-phone-number' => 'Please enter a phone number.',
      _ => 'Verification failed: ${message ?? code}',
    };
  }


// ── Provider ──────────────────────────────────────────────────────────────────

final authNotifierProvider =
    NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);

// Alias so screens can use either name
final authProvider = authNotifierProvider;

// ── UserData model ────────────────────────────────────────────────────────────

class UserData {
  final String uid;
  final String? email;
  final String? firstName;
  final String? lastName;
  final String? displayName;
  final String? phoneNumber;
  final String? photoURL;
  final String? role;
  final DateTime createdAt;
  final DateTime? lastLoginAt;
  final Map<String, dynamic>? metadata;

  const UserData({
    required this.uid,
    this.email,
    this.firstName,
    this.lastName,
    this.displayName,
    this.phoneNumber,
    this.photoURL,
    this.role,
    required this.createdAt,
    this.lastLoginAt,
    this.metadata,
  });

  factory UserData.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return UserData(
      uid: doc.id,
      email: data['email'] as String?,
      firstName: data['firstName'] as String?,
      lastName: data['lastName'] as String?,
      displayName: data['displayName'] as String?,
      phoneNumber: data['phoneNumber'] as String?,
      photoURL: data['photoURL'] as String?,
      role: data['role'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      lastLoginAt: (data['lastLoginAt'] as Timestamp?)?.toDate(),
      metadata: data['metadata'] != null
          ? Map<String, dynamic>.from(data['metadata'] as Map)
          : null,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'uid': uid,
        'firstName': firstName,
        'lastName': lastName,
        'displayName': displayName,
        'email': email,
        'phoneNumber': phoneNumber,
        'photoURL': photoURL,
        'role': role,
        'createdAt': Timestamp.fromDate(createdAt),
        'lastLoginAt':
            lastLoginAt != null ? Timestamp.fromDate(lastLoginAt!) : null,
        'metadata': metadata,
      };
}
