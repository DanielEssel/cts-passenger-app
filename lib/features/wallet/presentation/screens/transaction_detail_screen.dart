import 'package:flutter/material.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/core/theme/cts_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/routes/app_routes.dart';
import '../widgets/receipt_share.dart';
import 'wallet_screen.dart' show TxItem;

/// Full receipt view for a single transaction.
class TransactionDetailScreen extends ConsumerStatefulWidget {
  final TxItem tx;

  const TransactionDetailScreen({super.key, required this.tx});

  @override
  ConsumerState<TransactionDetailScreen> createState() =>
      _TransactionDetailScreenState();
}

class _TransactionDetailScreenState
    extends ConsumerState<TransactionDetailScreen> {
  bool _busy = false; // a share sheet is open

  @override
  Widget build(BuildContext context) {
    final tx = widget.tx;

    return Scaffold(
      backgroundColor: CtsTheme.background,
      appBar: AppBar(
        title: const Text('Transaction details'),
        backgroundColor: CtsTheme.background,
        foregroundColor: CtsTheme.textPrimary,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(ctsGutter, 8, ctsGutter,
            MediaQuery.of(context).padding.bottom + 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Amount hero ────────────────────────────────────────────
            _buildAmountCard(tx),
            const CtsGroupLabel('Details',
                padding: EdgeInsets.fromLTRB(4, 24, 4, 8)),

            // ── Details card ───────────────────────────────────────────
            _buildDetailsCard(context, tx),
            const SizedBox(height: 24),

            // ── Actions ────────────────────────────────────────────────
            _buildActions(context, tx),
          ],
        ),
      ),
    );
  }

  // Status shown with the shared tones. Stored values are lower case
  // ("completed", "pending", ...), so compare without case.
  static CtsTone _statusTone(String status) {
    final s = status.toLowerCase();
    if (s.contains('complete') || s.contains('success')) return CtsTone.success;
    if (s.contains('fail') || s.contains('cancel')) return CtsTone.error;
    if (s.contains('refund')) return CtsTone.info;
    return CtsTone.warning;
  }

  static String _statusLabel(String status) => status.isEmpty
      ? status
      : status[0].toUpperCase() + status.substring(1).toLowerCase();

  // The amount without its sign or currency ("+GHS 1,242.50" → "1,242.50").
  static String _figure(String amount) => amount
      .replaceFirst(RegExp(r'^[+\-−]'), '')
      .replaceFirst('GHS', '')
      .trim();

  // ─── Amount Hero ───────────────────────────────────────────────────────────
  // Same forest surface as the wallet balance: direction, amount, what it
  // was for, when, and its status.
  Widget _buildAmountCard(TxItem tx) {
    final figure = _figure(tx.amount);
    final direction = tx.isCredit ? 'Received' : 'Paid';
    final status = _statusLabel(tx.status);
    final big = CtsText.priceLarge.copyWith(
      fontSize: 36,
      color: Colors.white,
      letterSpacing: -1,
    );
    final small = CtsText.price.copyWith(
      fontSize: 18,
      color: CtsTheme.onForestMuted,
    );

    return Semantics(
      container: true,
      label: '$direction GHS $figure. ${tx.label}. ${tx.fullDate}. $status',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
        decoration: BoxDecoration(
          gradient: CtsTheme.forestGradient,
          borderRadius: BorderRadius.circular(CtsTheme.radiusXl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Direction and status; the status moves under the direction
            // with large text so neither word is broken.
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 10,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.10),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(tx.icon,
                            color: tx.isCredit
                                ? CtsTheme.appleSoft
                                : CtsTheme.onForestMuted,
                            size: 20),
                      ),
                      const SizedBox(width: 12),
                      Text(direction,
                          style: CtsText.label
                              .copyWith(color: CtsTheme.onForestMuted)),
                    ],
                  ),
                  CtsStatusPill(status, tone: _statusTone(tx.status)),
                ],
              ),
            ),
            const SizedBox(height: 18),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text.rich(TextSpan(children: [
                TextSpan(
                    text: tx.isCredit ? '+ ' : '− ',
                    style: small.copyWith(
                        color: tx.isCredit
                            ? CtsTheme.appleSoft
                            : CtsTheme.onForestMuted)),
                TextSpan(text: 'GHS ', style: small),
                TextSpan(text: figure, style: big),
              ])),
            ),
            const SizedBox(height: 12),
            Text(tx.label, style: CtsText.title3.copyWith(color: Colors.white)),
            const SizedBox(height: 4),
            Text(tx.fullDate,
                style:
                    CtsText.bodySmall.copyWith(color: CtsTheme.onForestMuted)),
          ],
        ),
      ),
    );
  }

  // ─── Details Card ──────────────────────────────────────────────────────────
  Widget _buildDetailsCard(BuildContext context, TxItem tx) {
    return CtsDetailCard(rows: [
      CtsDetailRow(
        'Transaction type',
        tx.isCredit ? 'Credit' : 'Debit',
        valueColor: tx.isCredit ? CtsTheme.primary : CtsTheme.textPrimary,
      ),
      CtsDetailRow('Category', tx.type),
      CtsDetailRow('Description',
          tx.note.isNotEmpty ? tx.note : 'No description provided'),
      CtsDetailRow('Date & time', tx.fullDate),
      CtsDetailRow(
        'Status',
        _statusLabel(tx.status),
        valueColor: _statusTone(tx.status).foreground,
      ),
      // Reference with copy
      CtsDetailRow(
        'Reference',
        tx.ref,
        trailing: TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: tx.ref));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Reference copied to clipboard'),
                duration: Duration(seconds: 1),
              ),
            );
          },
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: const Text('Copy', semanticsLabel: 'Copy reference'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
        ),
      ),
    ]);
  }

  // ─── Actions ───────────────────────────────────────────────────────────────
  // Each action reports only what actually happened: a confirmation appears
  // when the platform confirms it, never on assumption.
  Widget _buildActions(BuildContext context, TxItem tx) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CtsSecondaryButton(
          label: 'Save receipt',
          icon: Icons.download_rounded,
          expand: true,
          onPressed: _busy ? null : () => _saveReceipt(tx),
        ),
        const SizedBox(height: 10),
        CtsSecondaryButton(
          label: 'Share receipt',
          icon: Icons.ios_share_rounded,
          expand: true,
          onPressed: _busy ? null : () => _shareReceipt(tx),
        ),

        // Report issue (only for debits)
        if (!tx.isCredit) ...[
          const SizedBox(height: 10),
          CtsSecondaryButton(
            label: 'Report an issue',
            icon: Icons.flag_rounded,
            destructive: true,
            expand: true,
            onPressed: () => _showReportSheet(context, tx),
          ),
        ],
      ],
    );
  }

  /// Exports the receipt as a CTSGo .txt file through the platform share
  /// sheet, where the customer can save it to Files, Drive or another app.
  Future<void> _saveReceipt(TxItem tx) async {
    await _runShare(
      () => ref.read(receiptSharerProvider).shareFile(
            buildReceiptText(tx),
            fileName: receiptFileName(tx),
            subject: 'CTSGo receipt',
          ),
      completed: 'Receipt file exported',
      unconfirmed: "Your device didn't confirm where the receipt was saved. "
          'Check the app you chose.',
      unsupported: "Saving receipts isn't supported on this device.",
      failed: "Couldn't create the receipt file. Please try again.",
    );
  }

  /// Shares the receipt text through the platform share sheet.
  Future<void> _shareReceipt(TxItem tx) async {
    await _runShare(
      () => ref
          .read(receiptSharerProvider)
          .shareText(buildReceiptText(tx), subject: 'CTSGo receipt'),
      completed: 'Receipt shared',
      unsupported: "Sharing isn't supported on this device.",
      failed: "Couldn't open sharing. Please try again.",
    );
  }

  Future<void> _runShare(
    Future<ReceiptShareOutcome> Function() action, {
    required String completed,
    String? unconfirmed,
    required String unsupported,
    required String failed,
  }) async {
    setState(() => _busy = true);
    String? message;
    try {
      message = switch (await action()) {
        ReceiptShareOutcome.completed => completed,
        ReceiptShareOutcome.unconfirmed => unconfirmed,
        ReceiptShareOutcome.dismissed => null, // the customer closed it
      };
    } on MissingPluginException {
      message = unsupported;
    } on UnimplementedError {
      message = unsupported;
    } catch (e) {
      debugPrint('Receipt share failed: $e');
      message = failed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (message != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// There is no in-app channel for payment reports yet, so this sheet says
  /// so and points to Help & Support with the reference to quote. Nothing
  /// is sent from here.
  void _showReportSheet(BuildContext context, TxItem tx) {
    var copied = false;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(ctsGutter + 4, 12, ctsGutter + 4,
              MediaQuery.of(sheetContext).padding.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: CtsTheme.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Semantics(
                header: true,
                child: const Text('Report a problem with this payment',
                    style: CtsText.title3),
              ),
              const SizedBox(height: 8),
              const Text(
                "You can't send a report from the app yet. Contact CTSGo "
                'support and quote this payment’s reference so they can '
                'find it.',
                style: CtsText.bodySmall,
              ),
              if (tx.ref.isNotEmpty) ...[
                const SizedBox(height: 16),
                CtsDetailCard(rows: [
                  CtsDetailRow(
                    'Reference',
                    tx.ref,
                    trailing: TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: tx.ref));
                        setSheet(() => copied = true);
                      },
                      icon: Icon(
                          copied ? Icons.check_rounded : Icons.copy_rounded,
                          size: 16),
                      label: Text(copied ? 'Copied' : 'Copy',
                          semanticsLabel:
                              copied ? 'Reference copied' : 'Copy reference'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                  ),
                ]),
              ],
              const SizedBox(height: 20),
              CtsPrimaryButton(
                label: 'Open Help & Support',
                icon: Icons.support_agent_rounded,
                onPressed: () {
                  Navigator.pop(sheetContext);
                  Navigator.pushNamed(context, AppRoutes.helpSupport);
                },
              ),
              const SizedBox(height: 10),
              CtsSecondaryButton(
                label: 'Close',
                expand: true,
                onPressed: () => Navigator.pop(sheetContext),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
