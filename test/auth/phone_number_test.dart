// Ghana numbers reach Firebase in E.164, however they were typed or pasted.

import 'package:cts_transport_app/features/auth/domain/phone_number.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('toE164 (Ghana)', () {
    const expected = '+233244123456';
    for (final input in [
      '0244123456', // local, trunk 0
      '024 412 3456', // spaced
      '244123456', // without the 0
      '233244123456', // country code, no plus
      '+233244123456',
      '+233 24 412 3456',
      '+233 0244123456', // country code and trunk 0 together
      '00233244123456', // international prefix
      ' (024)-412-3456 ',
    ]) {
      test('"$input"', () => expect(toE164(input), expected));
    }

    test('050 and 059 ranges are mobile', () {
      expect(toE164('0501234567'), '+233501234567');
      expect(toE164('0591234567'), '+233591234567');
    });

    for (final input in [
      '',
      '024412345', // 9 digits with a 0: one digit short
      '02441234567', // 11 digits
      '2441234567', // 10 digits without the 0
      '0302123456', // Accra landline: cannot receive the SMS
      '0144123456',
      '+2332441234567',
      'abc',
    ]) {
      test('rejects "$input"', () => expect(toE164(input), isNull));
    }
  });

  group('toE164 (other dial codes)', () {
    test('Nigeria with trunk 0', () {
      expect(toE164('08031234567', dialCode: '+234'), '+2348031234567');
    });
    test('country code typed again is not doubled', () {
      expect(toE164('+234 803 123 4567', dialCode: '+234'), '+2348031234567');
    });
    test('too short', () => expect(toE164('123', dialCode: '+234'), isNull));
  });

  test('validatePhoneInput', () {
    expect(validatePhoneInput(''), 'Phone number is required');
    expect(validatePhoneInput('0244123456'), isNull);
    expect(validatePhoneInput('02441'), contains('Ghana mobile number'));
  });

  test('display and log formats', () {
    expect(formatPhoneForDisplay('+233244123456'), '+233 24 412 3456');
    expect(maskPhone('+233244123456'), '+233•••••3456');
    expect(maskPhone('+233244123456'), isNot(contains('244123')));
  });
}
