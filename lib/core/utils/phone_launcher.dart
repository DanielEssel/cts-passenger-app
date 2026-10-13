// lib/core/utils/phone_launcher.dart
//
// Opens the phone dialer or SMS app for a number and tells the user when that
// is not possible.
//
// Uses launchUrl directly. canLaunchUrl was the old gate, but on Android 11+
// it returns false unless the scheme is declared in the manifest <queries>,
// so taps did nothing with no message. Opening the dialer does not place a
// call; the user still presses call there (no CALL_PHONE permission).

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

enum PhoneAction { call, sms }

/// What happened when opening the phone app was attempted.
enum PhoneLaunchResult { opened, noNumber, failed }

typedef UrlOpener = Future<bool> Function(Uri uri);

Future<bool> _defaultOpener(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Opens the dialer ([PhoneAction.call]) or SMS app ([PhoneAction.sms]) for
/// [number]. Shows a message on [messenger] when there is no number or the
/// app could not be opened; shows nothing when the app opened.
///
/// [label] names who is being contacted, e.g. "your driver" or "Police (191)".
Future<PhoneLaunchResult> openPhoneAction({
  required PhoneAction action,
  required String? number,
  required String label,
  required ScaffoldMessengerState? messenger,
  UrlOpener opener = _defaultOpener,
}) async {
  final cleaned = (number ?? '').replaceAll(RegExp(r'[\s\-()]'), '');
  if (cleaned.isEmpty) {
    _show(messenger, 'No phone number is available for $label.');
    return PhoneLaunchResult.noNumber;
  }

  final uri = Uri(scheme: action == PhoneAction.call ? 'tel' : 'sms', path: cleaned);
  var opened = false;
  try {
    opened = await opener(uri);
  } catch (_) {
    opened = false;
  }

  if (!opened) {
    final app = action == PhoneAction.call ? 'phone' : 'messaging';
    final verb = action == PhoneAction.call ? 'call' : 'text';
    _show(
      messenger,
      'Couldn\'t open your $app app. Please $verb $label on $cleaned yourself.',
      long: true,
    );
    return PhoneLaunchResult.failed;
  }
  return PhoneLaunchResult.opened;
}

void _show(ScaffoldMessengerState? messenger, String message, {bool long = false}) {
  messenger
    ?..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: long ? 8 : 4),
    ));
}
