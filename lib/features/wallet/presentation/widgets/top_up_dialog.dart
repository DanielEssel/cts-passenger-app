// lib/features/wallet/presentation/widgets/top_up_dialog.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../widgets/buttons/cta_button.dart';
import 'bridge_momo_sheet.dart'; // ← was missing

class TopUpDialog extends ConsumerStatefulWidget {
  const TopUpDialog({super.key});

  @override
  ConsumerState<TopUpDialog> createState() => _TopUpDialogState();
}

class _TopUpDialogState extends ConsumerState<TopUpDialog> {
  int _selectedAmount = -1;
  final _customAmountController = TextEditingController();
  String? _errorMessage;

  final List<double> _quickAmounts = [20, 50, 100, 200];

  @override
  void dispose() {
    _customAmountController.dispose();
    super.dispose();
  }

  double? get _selectedAmountValue {
    if (_selectedAmount >= 0) return _quickAmounts[_selectedAmount];
    final custom = double.tryParse(_customAmountController.text);
    return (custom != null && custom > 0) ? custom : null;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Top Up Wallet', style: AppTextStyles.heading3),
                      const SizedBox(height: 2),
                      Text(
                        'Pay via Mobile Money',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                  iconSize: 20,
                ),
              ],
            ),

            const SizedBox(height: 20),
            _buildAmountSection(),
            const SizedBox(height: 16),

            // MoMo info pill — replaces the old payment method selector
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.phone_android_rounded,
                    color: AppColors.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'MTN · Telecel · AirtelTigo — you\'ll select your network '
                      'on the next screen.',
                      style: AppTextStyles.bodySmall
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Error
            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.errorLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: AppColors.error, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: AppTextStyles.bodySmall
                            .copyWith(color: AppColors.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // CTA
            CTAButton(
              onTap: _selectedAmountValue != null ? _processTopUp : null,
              text: _selectedAmountValue != null
                  ? 'Continue  →  GHS ${_selectedAmountValue!.toStringAsFixed(2)}'
                  : 'Select an amount',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAmountSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Select amount', style: AppTextStyles.labelLarge),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ..._quickAmounts.asMap().entries.map((entry) {
              final isSelected = _selectedAmount == entry.key;
              return GestureDetector(
                onTap: () => setState(() {
                  _selectedAmount = entry.key;
                  _customAmountController.clear();
                  _errorMessage = null;
                }),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color:
                        isSelected ? AppColors.primary : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? AppColors.primary : AppColors.border,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Text(
                    'GHS ${entry.value.toStringAsFixed(0)}',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isSelected ? Colors.white : AppColors.textPrimary,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              );
            }),

            // Custom amount
            SizedBox(
              width: double.infinity,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: TextField(
                  controller: _customAmountController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                        RegExp(r'^\d+\.?\d{0,2}')),
                  ],
                  onChanged: (_) => setState(() {
                    _selectedAmount = -1;
                    _errorMessage = null;
                  }),
                  decoration: InputDecoration(
                    hintText: 'Custom amount',
                    prefixText: 'GHS ',
                    hintStyle: AppTextStyles.bodySmall
                        .copyWith(color: AppColors.textTertiary),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _processTopUp() async {
    final amount = _selectedAmountValue;
    if (amount == null || amount < 1) {
      setState(() => _errorMessage = 'Minimum top-up is GHS 1.00');
      return;
    }
    if (!mounted) return;

    // Guard the pop — only dismiss if there's actually a route to pop
    if (Navigator.canPop(context)) Navigator.pop(context);

    if (!mounted) return;
    await showBridgeMomoSheet(context, amount: amount);
  }
}
