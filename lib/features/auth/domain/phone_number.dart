// lib/features/auth/domain/phone_number.dart
//
// Phone numbers for Firebase phone auth, which needs E.164 (+233244123456).
//
// Ghana (+233) is checked strictly: a 9-digit mobile number starting with
// 2 or 5, typed as 0244123456, 244123456, 233244123456 or +233 24 412 3456
// (also the common "+233 0244..." mix). Other dial codes in the picker get
// a generic E.164 length check.

const ghanaDialCode = '+233';

/// The E.164 form of [input] for [dialCode], or null when it is not valid.
String? toE164(String input, {String dialCode = ghanaDialCode}) {
  final dial = dialCode.replaceAll(RegExp(r'\D'), '');
  var digits = input.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (dial.isEmpty || digits.isEmpty) return null;

  if (dial == '233') {
    final national = _ghanaNational(digits);
    return national == null ? null : '+233$national';
  }

  // Generic: drop a typed country code (only when what remains is still a
  // plausible number), then a trunk 0.
  if (digits.startsWith(dial) && digits.length - dial.length >= 6) {
    digits = digits.substring(dial.length);
  }
  if (digits.startsWith('0')) digits = digits.substring(1);
  final total = dial.length + digits.length;
  if (digits.length < 6 || total > 15) return null;
  return '+$dial$digits';
}

String? _ghanaNational(String digits) {
  String national;
  if (digits.length == 9) {
    national = digits;
  } else if (digits.length == 10 && digits.startsWith('0')) {
    national = digits.substring(1);
  } else if (digits.length == 12 && digits.startsWith('233')) {
    national = digits.substring(3);
  } else if (digits.length == 13 && digits.startsWith('2330')) {
    national = digits.substring(4);
  } else {
    return null;
  }
  // Ghana mobile ranges (020-029, 050-059). Landlines (03x) cannot get SMS.
  return RegExp(r'^[25]\d{8}$').hasMatch(national) ? national : null;
}

/// Form validator for the phone field; null when [value] is valid.
String? validatePhoneInput(String? value, {String dialCode = ghanaDialCode}) {
  if (value == null || value.trim().isEmpty) return 'Phone number is required';
  if (toE164(value, dialCode: dialCode) != null) return null;
  return dialCode == ghanaDialCode
      ? 'Enter a valid Ghana mobile number, e.g. 024 412 3456'
      : 'Enter a valid phone number';
}

/// "+233 24 412 3456" for display. Non-Ghana numbers are returned unchanged.
String formatPhoneForDisplay(String e164) {
  final m = RegExp(r'^\+233(\d{2})(\d{3})(\d{4})$').firstMatch(e164);
  return m == null ? e164 : '+233 ${m[1]} ${m[2]} ${m[3]}';
}

/// "+233•••••3456" for logs: never write a full phone number to device logs.
String maskPhone(String phone) {
  final digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.length <= 4) return '•••';
  final prefix = digits.length > 11 ? '+${digits.substring(0, 3)}' : '';
  return '$prefix•••••${digits.substring(digits.length - 4)}';
}
