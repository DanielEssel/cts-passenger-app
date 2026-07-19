// Central place for legal document URLs — swap these for the real hosted
// URLs before store submission. The same URLs are used in the store listing.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class LegalUrls {
  LegalUrls._();

  // TODO: replace with real hosted URLs before launch
  static const terms   = 'https://rin.thectsafrica.com/terms';
  static const privacy = 'https://rin.thectsafrica.com/privacy';
  static const driverAgreement =
      'https://rin.thectsafrica.com/driver-agreement';

  static Future<void> open(BuildContext context, String url) async {
  final uri = Uri.parse(url);
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.inAppWebView);
    if (!ok && context.mounted) _fail(context);
  } catch (_) {
    if (context.mounted) _fail(context);
  }
}

  static void _fail(BuildContext c) =>
      ScaffoldMessenger.of(c).showSnackBar(
        const SnackBar(content: Text('Could not open the page')),
      );
}