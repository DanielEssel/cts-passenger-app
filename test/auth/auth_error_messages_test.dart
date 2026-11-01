// Every phone-auth failure gets plain-language text; raw Firebase messages
// never reach the user.

import 'package:cts_transport_app/features/auth/domain/auth_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('specific codes get specific messages', () {
    expect(phoneAuthErrorMessage('invalid-phone-number'),
        contains('phone number'));
    expect(phoneAuthErrorMessage('too-many-requests'),
        contains('Too many attempts'));
    expect(phoneAuthErrorMessage('quota-exceeded'), contains("can't send"));
    expect(
        phoneAuthErrorMessage('network-request-failed'), contains('internet'));
    expect(phoneAuthErrorMessage('session-expired'), contains('expired'));
    expect(phoneAuthErrorMessage('invalid-verification-code'),
        contains('incorrect'));
    expect(phoneAuthErrorMessage('invalid-app-credential'),
        contains('security check'));
    expect(phoneAuthErrorMessage('app-not-authorized'),
        contains('security check'));
    expect(phoneAuthErrorMessage('user-disabled'), contains('disabled'));
    expect(phoneAuthErrorMessage(otpRequestTimeoutCode),
        contains("couldn't confirm"));
  });

  test('unknown codes are generic and never echo the code', () {
    final message = phoneAuthErrorMessage('internal-error-XYZ');
    expect(message, 'Something went wrong. Please try again.');
    expect(message, isNot(contains('XYZ')));
  });
}
