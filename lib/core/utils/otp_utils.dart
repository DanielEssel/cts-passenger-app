// lib/core/utils/otp_utils.dart
import 'dart:math';

class OtpUtils {
  static String generate({int length = 4}) {
    final rng = Random.secure();
    return List.generate(length, (_) => rng.nextInt(10)).join();
  }

  static bool verify(String input, String actual) =>
      input.trim() == actual.trim();
}
