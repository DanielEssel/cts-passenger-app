import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_text_styles.dart';
import '../../../../wallet/presentation/screens/wallet_screen.dart'
    show TxItem;

/// Full receipt view for a single transaction.
class TransactionDetailScreen extends StatelessWidget {
  final TxItem tx;

  const TransactionDetailScreen({super.key, required this.tx});

  @override
  Widget build(BuildContext context) {
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
            _buildAmountCard(),
            const SizedBox(height: 20),

            // ── Details card ───────────────────────────────────────────
            _buildDetailsCard(context), // Pass context here
            const SizedBox(height: 20),

            // ── Actions ────────────────────────────────────────────────
            _buildActions(context),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ─── Amount Hero ───────────────────────────────────────────────────────────
  Widget _buildAmountCard() {
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
              color: tx.iconBg.withValues(alpha: 0.15),
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
              color: AppColors.success.withValues(alpha: 0.15),
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
  Widget _buildDetailsCard(BuildContext context) {
    // Added BuildContext parameter
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
          _DetailRow(label: 'Description', value: tx.note),
          const _RowDivider(),
          _DetailRow(label: 'Date & time', value: tx.fullDate),
          const _RowDivider(),
          _DetailRow(label: 'Status', value: tx.status),
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
                    // Now context is available
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
                      color: AppColors.primary.withValues(alpha: 0.1),
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
  Widget _buildActions(BuildContext context) {
    return Column(
      children: [
        // Download receipt
        GestureDetector(
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Receipt saved to downloads'),
                duration: Duration(seconds: 2),
              ),
            );
          },
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

        // Report issue (only for debits)
        if (!tx.isCredit)
          GestureDetector(
            onTap: () => _showReportSheet(context),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.errorLight,
                borderRadius: BorderRadius.circular(14),
                border:
                    Border.all(color: AppColors.error.withValues(alpha: 0.2)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.flag_rounded, color: AppColors.error, size: 18),
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

  void _showReportSheet(BuildContext context) {
    final ctrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) {
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
                    .map((t) => GestureDetector(
                          onTap: () {},
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceAlt,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Text(t, style: AppTextStyles.labelMedium),
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
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Submit report'),
              ),
            ],
          ),
        );
      },
    );
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
                textAlign: TextAlign.right),
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
