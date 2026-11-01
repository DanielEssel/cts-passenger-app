// lib/features/auth/providers/auth_providers.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../../../core/routes/app_routes.dart';
import '../data/passenger_account_store.dart';
import '../domain/auth_error_messages.dart';
import '../domain/otp_requester.dart';
import '../domain/phone_number.dart';

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

// ── Sign-in dependencies (overridden in tests) ────────────────────────────────

final passengerAccountStoreProvider = Provider<PassengerAccountStore>(
  (ref) => FirestorePassengerAccountStore(ref.watch(firestoreProvider)),
);

final passengerSessionHooksProvider =
    Provider<PassengerSessionHooks>((_) => const PassengerSessionHooks());

/// Firebase verifyPhoneNumber behind the request gate. No forced reCAPTCHA:
/// the Passenger app relies on the SDK's own fallback when Play Integrity
/// can't verify the device.
final otpRequesterProvider =
    Provider<OtpRequester<PhoneAuthCredential>>((ref) {
  final auth = ref.watch(firebaseAuthProvider);
  final requester = OtpRequester<PhoneAuthCredential>(
    start: ({
      required String phoneNumber,
      int? resendToken,
      required void Function(String, int?) codeSent,
      required void Function(PhoneAuthCredential) verificationCompleted,
      required void Function(String) verificationFailed,
    }) async {
      try {
        await auth.verifyPhoneNumber(
          phoneNumber: phoneNumber,
          forceResendingToken: resendToken,
          timeout: const Duration(seconds: 60),
          codeSent: codeSent,
          verificationCompleted: verificationCompleted,
          verificationFailed: (e) => verificationFailed(e.code),
          // Auto-retrieval stopped; the verificationId stays valid for
          // manual entry, so nothing changes here.
          codeAutoRetrievalTimeout: (_) {},
        );
      } on FirebaseAuthException catch (e) {
        verificationFailed(e.code);
      }
    },
  );
  ref.onDispose(requester.cancel);
  return requester;
});

// ── Auth notifier ─────────────────────────────────────────────────────────────
//
//   request code (OtpRequester) → codeSent → OTP screen
//   credential (auto-verified or typed) → signInWithCredential
//   → users/{uid} from the server → route (welcome or shell)
//
// Firebase Auth decides "signed in". Any failure after the Firebase sign-in
// (no profile, another role, Firestore unreachable) signs the user back out,
// so the app is never left half-authenticated. Existing profiles are never
// overwritten: signing up with a registered passenger number signs them in.

/// Called with the route to open once the passenger is signed in.
typedef AuthenticatedCallback = void Function(String route);

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthState();

  FirebaseAuth get _auth => ref.read(firebaseAuthProvider);
  FirebaseFirestore get _firestore => ref.read(firestoreProvider);
  PassengerAccountStore get _accounts =>
      ref.read(passengerAccountStoreProvider);
  PassengerSessionHooks get _hooks => ref.read(passengerSessionHooksProvider);
  OtpRequester<PhoneAuthCredential> get _requester =>
      ref.read(otpRequesterProvider);

  /// E.164 number being verified. A Firebase user only counts as this
  /// sign-in when its phone number matches.
  String? _phone;

  /// Set by signUp; null for a login.
  PassengerSignupDetails? _signup;

  // ── Request a code ────────────────────────────────────────────────────────

  /// Login. [phone] must be E.164.
  Future<void> sendOtp({
    required String phone,
    required VoidCallback onCodeSent,
    required AuthenticatedCallback onAuthenticated,
    required void Function(String) onError,
  }) async {
    _request(
      phone: phone,
      signup: null,
      isResend: false,
      onCodeSent: onCodeSent,
      onAuthenticated: onAuthenticated,
      onError: onError,
    );
  }

  /// New passenger. The profile is created after the phone is verified.
  Future<void> signUp({
    required String firstName,
    required String lastName,
    required String phone,
    required String email,
    required VoidCallback onCodeSent,
    required AuthenticatedCallback onAuthenticated,
    required void Function(String) onError,
  }) async {
    _request(
      phone: phone,
      signup: PassengerSignupDetails(
        firstName: firstName,
        lastName: lastName,
        phoneNumber: phone,
        email: email,
      ),
      isResend: false,
      onCodeSent: onCodeSent,
      onAuthenticated: onAuthenticated,
      onError: onError,
    );
  }

  /// Resends to the number being verified, with Firebase's resend token.
  Future<void> resendOtp({
    required String phone,
    required VoidCallback onCodeSent,
    required AuthenticatedCallback onAuthenticated,
    required void Function(String) onError,
  }) async {
    _request(
      phone: _phone ?? phone,
      signup: _signup,
      isResend: true,
      onCodeSent: onCodeSent,
      onAuthenticated: onAuthenticated,
      onError: onError,
    );
  }

  void _request({
    required String phone,
    required PassengerSignupDetails? signup,
    required bool isResend,
    required VoidCallback onCodeSent,
    required AuthenticatedCallback onAuthenticated,
    required void Function(String) onError,
  }) {
    if (state.isLoading || state.verificationInProgress) {
      _log('request ignored: another one is running');
      return;
    }
    _phone = phone;
    _signup = signup;
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearVerificationId: !isResend,
      clearResendToken: !isResend,
    );
    _log('${isResend ? 'resending' : 'requesting'} code for ${maskPhone(phone)}');

    final started = _requester.request(
      phoneNumber: phone,
      resendToken: isResend ? state.resendToken : null,
      onCodeSent: (verificationId, resendToken) {
        _log('code sent');
        state = state.copyWith(
          isLoading: false,
          verificationId: verificationId,
          resendToken: resendToken,
        );
        onCodeSent();
      },
      onAutoVerified: (credential) {
        _log('verified automatically');
        _complete(
          credential,
          onAuthenticated: onAuthenticated,
          onError: onError,
        );
      },
      onFailed: (code) {
        _log('code request failed: $code');
        final message = phoneAuthErrorMessage(code);
        // A failed resend keeps the earlier session: its code still works.
        state = state.copyWith(
          isLoading: false,
          error: message,
          clearVerificationId: !isResend,
          clearResendToken: !isResend,
        );
        onError(message);
      },
    );
    if (!started) state = state.copyWith(isLoading: false);
  }

  // ── Verify a typed code ───────────────────────────────────────────────────

  Future<bool> verifyOtp({
    required String smsCode,
    required AuthenticatedCallback onAuthenticated,
    required void Function(String) onError,
  }) async {
    final code = smsCode.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      onError('Enter the 6-digit code from the SMS.');
      return false;
    }

    final verificationId = state.verificationId;
    if (verificationId == null || verificationId.isEmpty) {
      // Automatic verification may already have used this session.
      final user = _auth.currentUser;
      if (user != null && _isThisSignIn(user) && !state.verificationInProgress) {
        state = state.copyWith(isLoading: true, verificationInProgress: true);
        return _finishSignedIn(user,
            onAuthenticated: onAuthenticated, onError: onError);
      }
      onError(phoneAuthErrorMessage('invalid-verification-id'));
      return false;
    }

    return _complete(
      PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: code,
      ),
      onAuthenticated: onAuthenticated,
      onError: onError,
    );
  }

  // ── Completion (automatic and manual share it) ────────────────────────────

  Future<bool> _complete(
    PhoneAuthCredential credential, {
    required AuthenticatedCallback onAuthenticated,
    required void Function(String) onError,
  }) async {
    // One completion at a time: auto-verification and a typed code must not
    // consume the same session twice.
    if (state.verificationInProgress) {
      _log('verification ignored: another one is running');
      return false;
    }
    state = state.copyWith(
      isLoading: true,
      verificationInProgress: true,
      clearError: true,
    );

    User? user;
    try {
      user = (await _auth.signInWithCredential(credential)).user;
    } on FirebaseAuthException catch (e) {
      // When both paths race, the loser gets session-expired although the
      // winner has signed this number in.
      final current = _auth.currentUser;
      if (current != null && _isThisSignIn(current)) {
        user = current;
      } else {
        _log('sign-in failed: ${e.code}');
        return _failBeforeSignIn(phoneAuthErrorMessage(e.code), onError);
      }
    } catch (_) {
      return _failBeforeSignIn(phoneAuthErrorMessage('unknown'), onError);
    }
    if (user == null) {
      return _failBeforeSignIn(phoneAuthErrorMessage('unknown'), onError);
    }
    return _finishSignedIn(user,
        onAuthenticated: onAuthenticated, onError: onError);
  }

  /// Wrong or expired code: nothing is signed in and the session is kept,
  /// so the user can correct the code or request a new one.
  bool _failBeforeSignIn(String message, void Function(String) onError) {
    state = state.copyWith(
      isLoading: false,
      verificationInProgress: false,
      error: message,
    );
    onError(message);
    return false;
  }

  Future<bool> _finishSignedIn(
    User user, {
    required AuthenticatedCallback onAuthenticated,
    required void Function(String) onError,
  }) async {
    // This request is done: a late auto-retrieval must not complete it again.
    _requester.cancel();
    state = state.copyWith(
      user: user,
      clearVerificationId: true,
      clearResendToken: true,
    );

    final outcome = await _resolveAccount(user);
    final route = outcome.route;
    if (route == null) {
      _log('signed back out: ${outcome.reason}');
      await _signOutQuietly();
      _phone = null;
      _signup = null;
      state = AuthState(error: outcome.message);
      onError(outcome.message!);
      return false;
    }

    _phone = null;
    _signup = null;
    state = state.copyWith(
      isLoading: false,
      verificationInProgress: false,
      user: user,
    );
    onAuthenticated(route);
    return true;
  }

  /// Decides where a Firebase-signed-in user goes, from the server copy of
  /// users/{uid}. Creates the profile for a new sign-up.
  Future<_AccountOutcome> _resolveAccount(User user) async {
    final PassengerAccount account;
    try {
      account = await _accounts.read(user.uid);
    } catch (_) {
      return const _AccountOutcome.rejected(
        'profile unreachable',
        "We couldn't confirm your account. Check your connection and try again.",
      );
    }

    if (account.isOtherRole) {
      return const _AccountOutcome.rejected(
        'other role',
        'This number is registered to a CTSGo driver or staff account, so it '
            "can't be used in the passenger app.",
      );
    }

    if (account.isPassenger) {
      try {
        await _accounts.recordLogin(user.uid);
      } catch (_) {
        _log('lastLoginAt not recorded');
      }
      ref.invalidate(currentUserProvider);
      return _AccountOutcome.route(
          account.hasSeenWelcome ? AppRoutes.shell : AppRoutes.welcome);
    }

    final signup = _signup;
    if (signup == null) {
      return const _AccountOutcome.rejected(
        'no passenger account',
        'No passenger account found for this number. Please sign up first.',
      );
    }

    try {
      await _accounts.createPassenger(
        user.uid,
        PassengerSignupDetails(
          firstName: signup.firstName,
          lastName: signup.lastName,
          // The number Firebase verified, not just the one typed.
          phoneNumber: user.phoneNumber ?? signup.phoneNumber,
          email: signup.email,
        ),
        stampCreation: !account.hasCreatedAt,
      );
    } catch (_) {
      return const _AccountOutcome.rejected(
        'profile not created',
        "We couldn't finish creating your account. Check your connection "
            'and try again.',
      );
    }
    // currentUserProvider only re-runs on auth changes; pick up the new doc.
    ref.invalidate(currentUserProvider);
    // The sign-in token save was skipped (no profile yet); save it now.
    // Wallets are created by a Cloud Function on users/{uid} create.
    await _hooks.savePushToken();
    return const _AccountOutcome.route(AppRoutes.welcome);
  }

  bool _isThisSignIn(User user) =>
      _phone != null && user.phoneNumber == _phone;

  Future<void> _signOutQuietly() async {
    try {
      await _hooks.clearPushToken();
    } catch (_) {}
    try {
      await _auth.signOut();
    } catch (_) {}
  }

  // ── Sign out ──────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    _requester.cancel();
    _phone = null;
    _signup = null;
    state = state.copyWith(isLoading: true);
    // Detach this device from the account's pushes while still signed in;
    // never blocks sign-out (bounded, does not throw).
    await _hooks.clearPushToken();
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

  /// Debug builds only, and never a full phone number, a UID or a code
  /// (AUTH-11: debugPrint is not stripped from release builds).
  void _log(String message) {
    if (kDebugMode) debugPrint('📱 AUTH: $message');
  }
}

class _AccountOutcome {
  const _AccountOutcome.route(this.route)
      : reason = null,
        message = null;
  const _AccountOutcome.rejected(this.reason, this.message) : route = null;

  final String? route;
  final String? reason;
  final String? message;
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
