// lib/core/utils/ghana_phone.dart
// Single source of truth for Ghana phone number handling in Flutter.
// Mirrors the logic in bridge.js toInternational() exactly.

/// Valid Ghana mobile prefixes (NCA 2024 allocations)
const _mtnPrefixes       = ['024', '025', '053', '054', '055', '059'];
const _telecelPrefixes   = ['020', '050'];
const _airteltigoPrefixes = ['023', '026', '027', '056', '057'];

const _allValidPrefixes = [
  ..._mtnPrefixes, ..._telecelPrefixes, ..._airteltigoPrefixes,
];

/// Returns true if [phone] is a valid 10-digit Ghana mobile number
/// with a known network prefix.
bool isValidGhanaPhone(String phone) {
  final digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.length != 10) return false;
  final prefix = digits.substring(0, 3);
  return _allValidPrefixes.contains(prefix);
}

/// Converts local Ghana format to Bridge international format.
/// 0244123456 → 233244123456
/// Already international → passthrough
/// Returns null if unrecognisable.
String? toInternational(String phone) {
  final cleaned = phone.replaceAll(RegExp(r'[\s\-+()]'), '');
  if (RegExp(r'^233\d{9}$').hasMatch(cleaned)) return cleaned;
  if (RegExp(r'^0\d{9}$').hasMatch(cleaned)) return '233${cleaned.substring(1)}';
  return null;
}

/// Detects network from a Ghana phone number.
/// Returns one of: 'MTN', 'TELECEL', 'AIRTELTIGO', or null.
String? detectNetwork(String phone) {
  final digits = phone.replaceAll(RegExp(r'\D'), '');
  final String prefix;

  if (digits.startsWith('233') && digits.length == 12) {
    prefix = '0${digits.substring(3, 6)}';
  } else if (digits.length == 10) {
    prefix = digits.substring(0, 3);
  } else {
    return null;
  }

  if (_mtnPrefixes.contains(prefix))       return 'MTN';
  if (_telecelPrefixes.contains(prefix))   return 'TELECEL';
  if (_airteltigoPrefixes.contains(prefix)) return 'AIRTELTIGO';
  return null;
}

/// Formats a Ghana phone number for display: 0244123456 → 024 412 3456
String formatGhanaPhone(String phone) {
  final digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.length == 10) {
    return '${digits.substring(0, 3)} ${digits.substring(3, 6)} ${digits.substring(6)}';
  }
  return phone;
}

/// Maps UI network name to Bridge API nw code
const networkToBridge = {
  'MTN':        'MTN',
  'TELECEL':    'VOD',
  'AIRTELTIGO': 'AIR',
};