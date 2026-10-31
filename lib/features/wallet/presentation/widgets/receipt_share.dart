// lib/features/wallet/presentation/widgets/receipt_share.dart
//
// CTSGo transaction receipts as plain text: shared as a message or exported
// as a .txt file through the platform share sheet (share_plus). Nothing is
// sent anywhere unless the customer picks a destination in that sheet.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../screens/wallet_screen.dart' show TxItem;

/// What the platform reported after a share or export.
enum ReceiptShareOutcome {
  /// The customer picked a destination (app, Files, Drive…).
  completed,

  /// The customer closed the share sheet.
  dismissed,

  /// The sheet opened but the platform cannot say what happened.
  unconfirmed,
}

/// Opens the platform share sheet. Replaced in tests; never sends anything
/// by itself.
class ReceiptSharer {
  const ReceiptSharer();

  Future<ReceiptShareOutcome> shareText(String text,
          {required String subject}) async =>
      _outcome(await Share.share(text, subject: subject));

  /// Writes [text] to a temporary .txt file (share_plus handles the
  /// location) and offers it to the platform: save to Files, Drive, etc.
  Future<ReceiptShareOutcome> shareFile(
    String text, {
    required String fileName,
    required String subject,
  }) async =>
      _outcome(await Share.shareXFiles(
        [
          XFile.fromData(utf8.encode(text),
              name: fileName, mimeType: 'text/plain')
        ],
        subject: subject,
        fileNameOverrides: [fileName],
      ));

  static ReceiptShareOutcome _outcome(ShareResult r) => switch (r.status) {
        ShareResultStatus.success => ReceiptShareOutcome.completed,
        ShareResultStatus.dismissed => ReceiptShareOutcome.dismissed,
        ShareResultStatus.unavailable => ReceiptShareOutcome.unconfirmed,
      };
}

final receiptSharerProvider =
    Provider<ReceiptSharer>((ref) => const ReceiptSharer());

/// Plain-text receipt from the fields the app already holds for this
/// transaction. Internal notes are left out.
String buildReceiptText(TxItem tx) {
  final figure = tx.amount
      .replaceFirst(RegExp(r'^[+\-−]'), '')
      .replaceFirst('GHS', '')
      .trim();
  final status = tx.status.isEmpty
      ? tx.status
      : tx.status[0].toUpperCase() + tx.status.substring(1).toLowerCase();
  const rule = '------------------------------';
  return [
    'CTSGo receipt',
    rule,
    tx.label,
    '${tx.isCredit ? 'Received' : 'Paid'}: GHS $figure',
    'Category: ${tx.type}',
    'Date: ${tx.fullDate}',
    'Status: $status',
    if (tx.ref.isNotEmpty) 'Reference: ${tx.ref}',
    rule,
    'Thank you for using CTSGo.',
  ].join('\n');
}

/// File name for an exported receipt, safe on every platform.
String receiptFileName(TxItem tx) {
  final ref = tx.ref.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
  return 'CTSGo-receipt${ref.isEmpty ? '' : '-$ref'}.txt';
}
