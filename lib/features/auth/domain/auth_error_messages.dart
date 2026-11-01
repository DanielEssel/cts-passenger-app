// lib/features/auth/domain/auth_error_messages.dart
//
// User-facing text for Firebase phone-auth error codes (AUTH-16). Raw
// Firebase messages are never shown: they are technical, English-only and
// can change between SDK versions. Unknown codes get a generic message.

/// Set by OtpRequester when Firebase never answers a code request.
const otpRequestTimeoutCode = 'request-timeout';

String phoneAuthErrorMessage(String code) {
  switch (code) {
    case 'invalid-phone-number':
    case 'missing-phone-number':
      return "That phone number isn't valid. Check it and try again.";
    case 'too-many-requests':
      return 'Too many attempts from this device. Please wait a while, '
          'then try again.';
    case 'quota-exceeded':
      return "We can't send verification codes right now. "
          'Please try again later.';
    case 'network-request-failed':
      return 'No internet connection. Check your connection and try again.';
    case 'session-expired':
    case 'code-expired':
      return 'This code has expired. Request a new code.';
    case 'invalid-verification-code':
    case 'missing-verification-code':
      return 'That code is incorrect. Check the SMS and try again.';
    case 'invalid-verification-id':
    case 'missing-verification-id':
      return 'Your verification session has ended. Request a new code.';
    case 'app-not-authorized':
    case 'invalid-app-credential':
    case 'missing-app-credential':
    case 'missing-client-identifier':
    case 'captcha-check-failed':
      return "We couldn't verify this device. Try again; you may be asked "
          'to complete a quick security check.';
    case 'web-context-cancelled':
    case 'web-context-already-presented':
      return 'The security check was closed before it finished. '
          'Try again.';
    case 'user-disabled':
      return 'This account has been disabled. Please contact CTSGo support.';
    case 'operation-not-allowed':
      return 'Phone sign-in is unavailable right now. Please try again later.';
    case otpRequestTimeoutCode:
      return "We couldn't confirm that a code was sent. Check your "
          'connection and try again.';
    default:
      return 'Something went wrong. Please try again.';
  }
}
