// lib/core/utils/cedi_format.dart
//
// Ghana cedi amounts as the Gas flows show them: "GH₵ 12.00".

/// [amount] in cedis with the cedi sign: "GH₵ 12.00", or "GH₵ 150" with
/// [decimals] 0 (whole-cedi prices such as cylinder sizes).
String formatCedis(num amount, {int decimals = 2}) => 'GH₵ ${amount.toStringAsFixed(decimals)}';
