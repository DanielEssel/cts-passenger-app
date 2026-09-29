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

// Gated on: Auth sign-in, a Firestore profile existing, AND that profile
// being a passenger. Without the role check, a phone number that already
// has a driver doc would read as "authenticated" for a beat as soon as
// currentUserProvider resolves -- even though sendOtp/signUp are about to
// sign it back out once their own role check runs.
final isAuthenticatedProvider = Provider<bool>((ref) {
  final user = ref.watch(authStateProvider).value;
  final userData = ref.watch(currentUserProvider).value;
  return user != null && userData != null && userData.role == 'passenger';
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

  /// Firebase verification session ID returned by codeSent.
  final String? verificationId;

  /// Android-only Firebase resend token returned by codeSent.
  final int? resendToken;

  /// True while one authentication completion path is running.
  ///
  /// This prevents Android automatic verification and manual OTP entry
  /// from consuming the same Firebase verification session simultaneously.
  final bool verificationInProgress;

  const AuthState({
    this.isLoading = false,
    this.error,
    this.user,
    this.verificationId,
    this.resendToken,
    this.verificationInProgress = false,
  });

  AuthState copyWith({
    bool? isLoading,
    String? error,
    bool clearError = false,
    User? user,
    String? verificationId,
    bool clearVerificationId = false,
    int? resendToken,
    bool clearResendToken = false,
    bool? verificationInProgress,
  }) {
    return AuthState(
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      user: user ?? this.user,
      verificationId:
          clearVerificationId ? null : (verificationId ?? this.verificationId),
      resendToken: clearResendToken ? null : (resendToken ?? this.resendToken),
      verificationInProgress:
          verificationInProgress ?? this.verificationInProgress,
    );
  }
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
    required VoidCallback onAuthenticated,
    required void Function(String) onError,
  }) async {
    // Prevent accidental duplicate requests from the login UI.
    if (state.isLoading) {
      debugPrint(
          '🔥 OTP request ignored: verification request already running');
      return;
    }

    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearVerificationId: true,
      clearResendToken: true,
      verificationInProgress: false,
    );

    debugPrint('📱 FIREBASE PHONE AUTH: requesting OTP for $phone');

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phone,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential credential) async {
          debugPrint(
              '📱 FIREBASE PHONE AUTH: automatic verification completed');

          await _completeAutomaticVerification(
            credential: credential,
            onCodeSent: onCodeSent,
            onAuthenticated: onAuthenticated,
            onError: onError,
          );
        },
        verificationFailed: (FirebaseAuthException e) {
          debugPrint(
            '🔥 FIREBASE PHONE AUTH FAILED: ${e.code} - ${e.message}',
          );

          final msg = _phoneErrorMessage(e.code, e.message);

          state = state.copyWith(
            isLoading: false,
            error: msg,
            clearVerificationId: true,
            clearResendToken: true,
            verificationInProgress: false,
          );

          onError(msg);
        },
        codeSent: (String verificationId, int? resendToken) {
          debugPrint(
            '📨 FIREBASE PHONE AUTH: codeSent '
            'verificationId=${verificationId.isNotEmpty ? "received" : "EMPTY"} '
            'resendToken=$resendToken',
          );

          state = state.copyWith(
            isLoading: false,
            verificationId: verificationId,
            resendToken: resendToken,
            verificationInProgress: false,
          );

          onCodeSent();
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          debugPrint(
            '⏱️ FIREBASE PHONE AUTH: auto retrieval timeout',
          );

          // IMPORTANT:
          // Do NOT clear verificationId here.
          //
          // The timeout only means Android automatic SMS retrieval stopped.
          // The user can still manually enter the SMS code.
        },
      );
    } on FirebaseAuthException catch (e) {
      debugPrint(
        '🔥 FIREBASE PHONE AUTH REQUEST ERROR: ${e.code} - ${e.message}',
      );

      final msg = _phoneErrorMessage(e.code, e.message);

      state = state.copyWith(
        isLoading: false,
        error: msg,
        clearVerificationId: true,
        clearResendToken: true,
        verificationInProgress: false,
      );

      onError(msg);
    } catch (e) {
      debugPrint('🔥 FIREBASE PHONE AUTH REQUEST ERROR: $e');

      const msg = 'Unable to send verification code. Please try again.';

      state = state.copyWith(
        isLoading: false,
        error: msg,
        clearVerificationId: true,
        clearResendToken: true,
        verificationInProgress: false,
      );

      onError(msg);
    }
  }

  // ── Sign up (new passenger) ───────────────────────────────────────────────

  Future<void> signUp({
    required String firstName,
    required String lastName,
    required String phone,
    required String email,
    required VoidCallback onCodeSent,
    required VoidCallback onAuthenticated,
    required void Function(String) onError,
  }) async {
    if (state.isLoading) {
      debugPrint(
          '🔥 SIGN-UP OTP ignored: verification request already running');
      return;
    }

    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearVerificationId: true,
      clearResendToken: true,
      verificationInProgress: false,
    );

    debugPrint('📱 FIREBASE SIGN-UP: requesting OTP for $phone');

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phone,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential credential) async {
          debugPrint('📱 FIREBASE SIGN-UP: automatic verification completed');

          await _completeAutomaticVerification(
            credential: credential,
            pendingProfile: {
              'firstName': firstName,
              'lastName': lastName,
              'phone': phone,
              'email': email,
            },
            onCodeSent: onCodeSent,
            onAuthenticated: onAuthenticated,
            onError: onError,
          );
        },
        verificationFailed: (FirebaseAuthException e) {
          debugPrint(
            '🔥 FIREBASE SIGN-UP FAILED: ${e.code} - ${e.message}',
          );

          final msg = _phoneErrorMessage(e.code, e.message);

          state = state.copyWith(
            isLoading: false,
            error: msg,
            clearVerificationId: true,
            clearResendToken: true,
            verificationInProgress: false,
          );

          onError(msg);
        },
        codeSent: (String verificationId, int? resendToken) {
          debugPrint(
            '📨 FIREBASE SIGN-UP: codeSent '
            'resendToken=$resendToken',
          );

          state = state.copyWith(
            isLoading: false,
            verificationId: verificationId,
            resendToken: resendToken,
            verificationInProgress: false,
          );

          onCodeSent();
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          debugPrint(
            '⏱️ FIREBASE SIGN-UP: auto retrieval timeout',
          );

          // Keep verificationId. Manual OTP remains valid.
        },
      );
    } on FirebaseAuthException catch (e) {
      debugPrint(
        '🔥 FIREBASE SIGN-UP REQUEST ERROR: ${e.code} - ${e.message}',
      );

      final msg = _phoneErrorMessage(e.code, e.message);

      state = state.copyWith(
        isLoading: false,
        error: msg,
        clearVerificationId: true,
        clearResendToken: true,
        verificationInProgress: false,
      );

      onError(msg);
    } catch (e) {
      debugPrint('🔥 FIREBASE SIGN-UP REQUEST ERROR: $e');

      const msg = 'Unable to send verification code. Please try again.';

      state = state.copyWith(
        isLoading: false,
        error: msg,
        clearError: false,
        clearVerificationId: true,
        clearResendToken: true,
        verificationInProgress: false,
      );

      onError(msg);
    }
  }

  Future<void> _completeAutomaticVerification({
    required PhoneAuthCredential credential,
    Map<String, dynamic>? pendingProfile,
    required VoidCallback onCodeSent,
    required VoidCallback onAuthenticated,
    required void Function(String) onError,
  }) async {
    // Only one completion path may consume the verification session.
    if (state.verificationInProgress) {
      debugPrint(
        '⚠️ AUTO VERIFICATION ignored: another verification is already running',
      );
      return;
    }

    state = state.copyWith(
      isLoading: true,
      verificationInProgress: true,
      clearError: true,
    );

    try {
      final result = await _auth.signInWithCredential(credential);
      final user = result.user;

      if (user == null) {
        state = state.copyWith(
          isLoading: false,
          verificationInProgress: false,
        );

        onError('Authentication failed. Please try again.');
        return;
      }

      debugPrint(
        '✅ AUTO VERIFICATION: Firebase user authenticated ${user.uid}',
      );

      state = state.copyWith(
        isLoading: true,
        user: user,
        clearVerificationId: true,
        clearResendToken: true,
      );

      final success = await _finishAfterCredential(
        user,
        pendingProfile,
        onError,
      );

      if (!success) {
        state = const AuthState();
        return;
      }

      state = state.copyWith(
        isLoading: false,
        user: user,
        verificationInProgress: false,
      );

      onAuthenticated();
    } on FirebaseAuthException catch (e) {
      debugPrint(
        '🔥 AUTO VERIFICATION ERROR: ${e.code} - ${e.message}',
      );

      state = state.copyWith(
        isLoading: false,
        verificationInProgress: false,
      );

      onError(_phoneErrorMessage(e.code, e.message));
    } catch (e) {
      debugPrint('🔥 AUTO VERIFICATION ERROR: $e');

      state = state.copyWith(
        isLoading: false,
        verificationInProgress: false,
      );

      onError(
        'Unable to complete verification. Please request a new code.',
      );
    }
  }

  // ── Verify OTP ────────────────────────────────────────────────────────────

  Future<bool> verifyOtp({
    required String smsCode,
    Map<String, dynamic>? pendingProfile,
    required VoidCallback onAuthenticated,
    required void Function(String) onError,
  }) async {
    final code = smsCode.trim();

    if (code.length != 6) {
      onError('Please enter the complete 6-digit verification code.');
      return false;
    }

    // Prevent:
    //
    // final digit -> verifyOtp()
    // Verify button -> verifyOtp()
    //
    // from consuming the same verification session twice.
    if (state.verificationInProgress) {
      debugPrint(
        '⚠️ MANUAL OTP ignored: another verification is already running',
      );
      return false;
    }

    final verificationId = state.verificationId;

    if (verificationId == null || verificationId.isEmpty) {
      final currentUser = _auth.currentUser;

      if (currentUser != null) {
        debugPrint(
          '✅ MANUAL OTP: Firebase already authenticated '
          '${currentUser.uid}',
        );

        final success = await _finishAfterCredential(
          currentUser,
          pendingProfile,
          onError,
        );

        if (success) {
          state = state.copyWith(
            isLoading: false,
            user: currentUser,
            verificationInProgress: false,
          );

          onAuthenticated();
        }

        return success;
      }

      onError(
        'Your verification session is no longer available. '
        'Please request a new code.',
      );

      return false;
    }

    state = state.copyWith(
      isLoading: true,
      verificationInProgress: true,
      clearError: true,
    );

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: code,
      );

      debugPrint('📲 MANUAL OTP: submitting verification code');

      final result = await _auth.signInWithCredential(credential);
      final user = result.user;

      if (user == null) {
        state = state.copyWith(
          isLoading: false,
          verificationInProgress: false,
        );

        onError('Authentication failed. Please try again.');
        return false;
      }

      debugPrint(
        '✅ MANUAL OTP: Firebase user authenticated ${user.uid}',
      );

      state = state.copyWith(
        isLoading: true,
        user: user,
        clearVerificationId: true,
        clearResendToken: true,
      );

      final success = await _finishAfterCredential(
        user,
        pendingProfile,
        onError,
      );

      if (!success) {
        state = const AuthState();
        return false;
      }

      state = state.copyWith(
        isLoading: false,
        user: user,
        verificationInProgress: false,
      );

      onAuthenticated();

      return true;
    } on FirebaseAuthException catch (e) {
      debugPrint(
        '🔥 MANUAL OTP ERROR: ${e.code} - ${e.message}',
      );

      // Do NOT automatically sign the user out here unless Firebase
      // actually authenticated them and our post-auth flow rejected them.
      //
      // In particular, session-expired should not be treated as proof
      // that the SMS itself expired.
      final currentUser = _auth.currentUser;

      if (currentUser != null) {
        debugPrint(
          'ℹ️ MANUAL OTP error occurred but Firebase has an authenticated user. '
          'Continuing with ${currentUser.uid}',
        );

        state = state.copyWith(
          isLoading: true,
          user: currentUser,
          clearVerificationId: true,
          clearResendToken: true,
        );

        final success = await _finishAfterCredential(
          currentUser,
          pendingProfile,
          onError,
        );

        if (success) {
          state = state.copyWith(
            isLoading: false,
            user: currentUser,
            verificationInProgress: false,
          );

          onAuthenticated();
        }

        return success;
      }

      state = state.copyWith(
        isLoading: false,
        verificationInProgress: false,
      );

      onError(_phoneErrorMessage(e.code, e.message));

      return false;
    } catch (e) {
      debugPrint('🔥 MANUAL OTP ERROR: $e');

      state = state.copyWith(
        isLoading: false,
        verificationInProgress: false,
      );

      onError(
        'Unable to complete verification. Please request a new code.',
      );

      return false;
    }
  }

  Future<void> resendOtp({
    required String phone,
    Map<String, dynamic>? pendingProfile,
    required VoidCallback onCodeSent,
    required VoidCallback onAuthenticated,
    required void Function(String) onError,
  }) async {
    if (state.isLoading) {
      debugPrint('⚠️ RESEND ignored: authentication operation already running');
      return;
    }

    final previousResendToken = state.resendToken;

    state = state.copyWith(
      isLoading: true,
      clearError: true,
      verificationInProgress: false,
    );

    debugPrint(
      '🔄 FIREBASE PHONE AUTH: resending OTP '
      '(token=${previousResendToken != null ? "available" : "unavailable"})',
    );

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phone,
        timeout: const Duration(seconds: 60),
        forceResendingToken: previousResendToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          debugPrint(
            '📱 FIREBASE RESEND: automatic verification completed',
          );

          await _completeAutomaticVerification(
            credential: credential,
            pendingProfile: pendingProfile,
            onCodeSent: onCodeSent,
            onAuthenticated: onAuthenticated,
            onError: onError,
          );
        },
        verificationFailed: (FirebaseAuthException e) {
          debugPrint(
            '🔥 FIREBASE RESEND FAILED: ${e.code} - ${e.message}',
          );

          final msg = _phoneErrorMessage(e.code, e.message);

          state = state.copyWith(
            isLoading: false,
            error: msg,
            verificationInProgress: false,
          );

          onError(msg);
        },
        codeSent: (String verificationId, int? resendToken) {
          debugPrint(
            '📨 FIREBASE RESEND: new verification session received '
            '(resendToken=$resendToken)',
          );

          state = state.copyWith(
            isLoading: false,
            verificationId: verificationId,
            resendToken: resendToken,
            verificationInProgress: false,
          );

          onCodeSent();
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          debugPrint(
            '⏱️ FIREBASE RESEND: auto retrieval timeout',
          );

          // Keep the verificationId for manual entry.
        },
      );
    } on FirebaseAuthException catch (e) {
      debugPrint(
        '🔥 FIREBASE RESEND ERROR: ${e.code} - ${e.message}',
      );

      final msg = _phoneErrorMessage(e.code, e.message);

      state = state.copyWith(
        isLoading: false,
        error: msg,
        verificationInProgress: false,
      );

      onError(msg);
    } catch (e) {
      debugPrint('🔥 FIREBASE RESEND ERROR: $e');

      const msg = 'Unable to resend the code. Please try again.';

      state = state.copyWith(
        isLoading: false,
        error: msg,
        verificationInProgress: false,
      );

      onError(msg);
    }
  }

  // Shared by the manual verifyOtp path and its session-expired recovery:
  // either creates the passenger profile (signup) or checks/finishes login.
  Future<bool> _finishAfterCredential(
    User user,
    Map<String, dynamic>? pendingProfile,
    void Function(String) onError,
  ) async {
    if (pendingProfile != null) {
      return await _createPassengerProfile(
        user: user,
        firstName: pendingProfile['firstName'] as String? ?? '',
        lastName: pendingProfile['lastName'] as String? ?? '',
        phone: pendingProfile['phone'] as String? ?? user.phoneNumber ?? '',
        email: pendingProfile['email'] as String? ?? '',
        onError: onError,
      );
    }
    return _finishLogin(user, onError);
  }

  // Role-checks an existing user doc and bumps lastLoginAt. Returns false
  // (and signs out) if there's no passenger account for this number.
  Future<bool> _finishLogin(User user, void Function(String) onError) async {
    final docRef = _firestore.collection('users').doc(user.uid);
    final userDoc = await docRef.get();
    final data = userDoc.data();

    if (!userDoc.exists || data == null || data['role'] != 'passenger') {
      await _auth.signOut();
      state = const AuthState();
      onError(
          'No passenger account found for this number. Please sign up first.');
      return false;
    }

    await docRef.update({'lastLoginAt': FieldValue.serverTimestamp()});
    ref.invalidate(currentUserProvider);

    state = state.copyWith(isLoading: false, user: user);
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
      if (displayName != null) await user.updateDisplayName(displayName);
      if (photoURL != null) await user.updatePhotoURL(photoURL);

      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (displayName != null) updates['displayName'] = displayName;
      if (photoURL != null) updates['photoURL'] = photoURL;

      await _firestore.collection('users').doc(user.uid).update(updates);
      ref.invalidate(currentUserProvider);
      return true;
    } catch (e) {
      state = state.copyWith(error: 'Failed to update profile: $e');
      return false;
    }
  }

  void clearError() => state = state.copyWith(clearError: true);

  // Returns false (and calls onError) instead of throwing, so callers can
  // decide whether to sign the half-created user back out.
  Future<bool> _createPassengerProfile({
    required User user,
    required String firstName,
    required String lastName,
    required String phone,
    required String email,
    required void Function(String) onError,
  }) async {
    // Reload to ensure the auth token is fully settled after OTP sign-in
    await user.reload();
    final freshUser = _auth.currentUser;
    if (freshUser == null) return false;

    final docRef = _firestore.collection('users').doc(freshUser.uid);
    final docSnap = await docRef.get();

    if (docSnap.exists) {
      final existingRole = docSnap.data()?['role'];
      if (existingRole != null && existingRole != 'passenger') {
        onError('This phone number is already registered as a driver.');
        return false;
      }
    }
    final isNewDoc = !docSnap.exists;

    await docRef.set({
      'uid': freshUser.uid,
      'firstName': firstName,
      'lastName': lastName,
      'displayName': '$firstName $lastName',
      'phoneNumber': phone,
      'email': email.isNotEmpty ? email : null,
      'role': 'passenger',
      'hasSeenWelcome': false,
      // Only stamp these on first creation -- merge:true on a retry or a
      // second auto-verify callback would otherwise silently reset the
      // user's original signup date every time this runs.
      if (isNewDoc) 'termsAcceptedAt': FieldValue.serverTimestamp(),
      if (isNewDoc) 'createdAt': FieldValue.serverTimestamp(),
      'termsVersion': '1.0',
      'lastLoginAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // currentUserProvider only re-runs when authStateProvider changes; the
    // Firestore doc just written wouldn't otherwise be picked up until the
    // next auth state change, so nudge it explicitly.
    ref.invalidate(currentUserProvider);

    state = state.copyWith(isLoading: false, user: freshUser);

    // Wallet is created by a Cloud Function triggered on users/{uid} onCreate.
    // Do NOT write to /wallets from the client — rules block it.
    return true;
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
