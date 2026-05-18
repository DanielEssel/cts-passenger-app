import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
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
  bool _isReporting = false;

  @override
  Widget build(BuildContext context) {
    final tx = widget.tx;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Transaction details'),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // ── Amount hero ────────────────────────────────────────────
            _buildAmountCard(tx),
            const SizedBox(height: 20),

            // ── Details card ───────────────────────────────────────────
            _buildDetailsCard(context, tx),
            const SizedBox(height: 20),

            // ── Actions ────────────────────────────────────────────────
            _buildActions(context, tx),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ─── Amount Hero ───────────────────────────────────────────────────────────
  Widget _buildAmountCard(TxItem tx) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.darkNavy,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: tx.iconBg.withAlpha((0.15 * 255).toInt()),
              shape: BoxShape.circle,
            ),
            child: Icon(tx.icon,
                color: tx.isCredit ? AppColors.success : AppColors.error,
                size: 28),
          ),
          const SizedBox(height: 14),
          Text(
            tx.amount,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: tx.isCredit ? AppColors.success : AppColors.error,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(tx.label,
              style:
                  AppTextStyles.heading4.copyWith(color: AppColors.background)),
          const SizedBox(height: 4),
          Text(tx.fullDate,
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textOnDarkMuted)),
          const SizedBox(height: 12),
          // Status badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha((0.15 * 255).toInt()),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle_rounded,
                    color: AppColors.success, size: 14),
                const SizedBox(width: 6),
                Text(tx.status,
                    style: AppTextStyles.labelMedium
                        .copyWith(color: AppColors.success)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Details Card ──────────────────────────────────────────────────────────
  Widget _buildDetailsCard(BuildContext context, TxItem tx) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _DetailRow(
            label: 'Transaction type',
            value: tx.isCredit ? 'Credit' : 'Debit',
            valueColor: tx.isCredit ? AppColors.success : AppColors.error,
          ),
          const _RowDivider(),
          _DetailRow(label: 'Category', value: tx.type),
          const _RowDivider(),
          _DetailRow(
              label: 'Description',
              value: tx.note.isNotEmpty ? tx.note : 'No description provided'),
          const _RowDivider(),
          _DetailRow(label: 'Date & time', value: tx.fullDate),
          const _RowDivider(),
          _DetailRow(
            label: 'Status',
            value: tx.status,
            valueColor: tx.status == 'Completed'
                ? AppColors.success
                : AppColors.warning,
          ),
          const _RowDivider(),
          // Reference with copy
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Reference',
                          style: AppTextStyles.bodySmall
                              .copyWith(color: AppColors.textSecondary)),
                      const SizedBox(height: 3),
                      Text(tx.ref,
                          style: AppTextStyles.labelLarge
                              .copyWith(fontFamily: 'monospace')),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: tx.ref));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Reference copied to clipboard'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha((0.1 * 255).toInt()),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.copy_rounded,
                            size: 13, color: AppColors.primary),
                        const SizedBox(width: 4),
                        Text('Copy',
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                            )),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Actions ───────────────────────────────────────────────────────────────
  Widget _buildActions(BuildContext context, TxItem tx) {
    return Column(
      children: [
        // Download receipt
        GestureDetector(
          onTap: () => _downloadReceipt(context, tx),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.download_rounded,
                    color: AppColors.primary, size: 18),
                SizedBox(width: 8),
                Text('Download receipt',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    )),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),

        // Share receipt
        GestureDetector(
          onTap: () => _shareReceipt(context, tx),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.share_rounded, color: AppColors.info, size: 18),
                SizedBox(width: 8),
                Text('Share receipt',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.info,
                    )),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),

        // Report issue (only for debits)
        if (!tx.isCredit)
          GestureDetector(
            onTap: () => _showReportSheet(context, tx),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.errorLight,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: AppColors.error.withAlpha((0.2 * 255).toInt())),
              ),
              child: _isReporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.flag_rounded,
                            color: AppColors.error, size: 18),
                        SizedBox(width: 8),
                        Text('Report an issue',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.error,
                            )),
                      ],
                    ),
            ),
          ),
      ],
    );
  }

  void _downloadReceipt(BuildContext context, TxItem tx) async {
    // Simulate receipt generation
    await Future.delayed(const Duration(milliseconds: 500));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Receipt saved to downloads'),
          duration: Duration(seconds: 2),
        ),
      );

      // Log receipt download for analytics
      _logReceiptDownload(tx);
    }
  }

  void _shareReceipt(BuildContext context, TxItem tx) async {
    // Generate receipt text
    final receiptText = '''
RIDEGO TRANSACTION RECEIPT
━━━━━━━━━━━━━━━━━━━━━━━━━━
Reference: ${tx.ref}
Date: ${tx.fullDate}
Type: ${tx.type}
Amount: ${tx.amount}
Status: ${tx.status}
Description: ${tx.note}
━━━━━━━━━━━━━━━━━━━━━━━━━━
Thank you for riding with us!
    ''';

    // Share receipt using platform channel
    // Note: Add share_plus package for better sharing
    await Clipboard.setData(ClipboardData(text: receiptText));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Receipt copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _logReceiptDownload(TxItem tx) {
    // Analytics tracking
    print('Receipt downloaded for transaction: ${tx.ref}');
    // You can add Firebase Analytics here
    // FirebaseAnalytics.instance.logEvent(
    //   name: 'receipt_downloaded',
    //   parameters: {'reference': tx.ref, 'amount': tx.amount},
    // );
  }

  void _showReportSheet(BuildContext context, TxItem tx) {
    final ctrl = TextEditingController();
    String selectedIssue = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                      child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                              color: AppColors.border,
                              borderRadius: BorderRadius.circular(2)))),
                  const SizedBox(height: 16),
                  const Text('Report transaction issue',
                      style: AppTextStyles.heading3),
                  const SizedBox(height: 6),
                  Text('Ref: ${tx.ref}',
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      'Unauthorised charge',
                      'Wrong amount',
                      'Duplicate charge',
                      'Service not received',
                      'Other',
                    ]
                        .map((issue) => GestureDetector(
                              onTap: () =>
                                  setModalState(() => selectedIssue = issue),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 7),
                                decoration: BoxDecoration(
                                  color: selectedIssue == issue
                                      ? AppColors.primary
                                          .withAlpha((0.1 * 255).toInt())
                                      : AppColors.surfaceAlt,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: selectedIssue == issue
                                        ? AppColors.primary
                                        : AppColors.border,
                                    width: selectedIssue == issue ? 1.5 : 0.5,
                                  ),
                                ),
                                child: Text(
                                  issue,
                                  style: AppTextStyles.labelMedium.copyWith(
                                    color: selectedIssue == issue
                                        ? AppColors.primary
                                        : AppColors.textPrimary,
                                    fontWeight: selectedIssue == issue
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: TextField(
                      controller: ctrl,
                      maxLines: 3,
                      style: AppTextStyles.bodyMedium,
                      decoration: const InputDecoration(
                        hintText: 'Describe the issue…',
                        hintStyle: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            color: AppColors.textTertiary),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () async {
                      if (selectedIssue.isEmpty && ctrl.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Please select an issue or provide details'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                        return;
                      }

                      setModalState(() => _isReporting = true);

                      try {
                        // Submit report to backend
                        await _submitReport(tx, selectedIssue, ctrl.text);

                        if (mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Report submitted successfully'),
                              backgroundColor: AppColors.success,
                              duration: Duration(seconds: 3),
                            ),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Failed to submit report: $e'),
                              backgroundColor: AppColors.error,
                              duration: Duration(seconds: 3),
                            ),
                          );
                        }
                      } finally {
                        setModalState(() => _isReporting = false);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      minimumSize: const Size(double.infinity, 48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isReporting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Submit report'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _submitReport(
      TxItem tx, String issueType, String description) async {
    // Simulate API call
    await Future.delayed(const Duration(seconds: 1));

    // In production, send to backend:
    // final functions = FirebaseFunctions.instance;
    // await functions.httpsCallable('reportTransaction').call({
    //   'reference': tx.ref,
    //   'issueType': issueType,
    //   'description': description,
    // });

    print(
        'Report submitted: ${tx.ref}, Issue: $issueType, Description: $description');
  }
}

// ─── Detail row widgets ───────────────────────────────────────────────────────
class _DetailRow extends StatelessWidget {
  final String label, value;
  final Color? valueColor;
  const _DetailRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(label,
                style: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textSecondary)),
          ),
          Expanded(
            flex: 3,
            child: Text(value,
                style: AppTextStyles.labelLarge
                    .copyWith(color: valueColor ?? AppColors.textPrimary),
                textAlign: TextAlign.right,
                softWrap: true),
          ),
        ],
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();
  @override
  Widget build(BuildContext context) => const Divider(
      height: 0.5, thickness: 0.5, indent: 16, color: AppColors.borderLight);
}
