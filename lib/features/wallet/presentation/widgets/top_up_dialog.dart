import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../widgets/buttons/cta_button.dart';
import '../providers/wallet_controller.dart';

class TopUpDialog extends ConsumerStatefulWidget {
  const TopUpDialog({super.key});

  @override
  ConsumerState<TopUpDialog> createState() => _TopUpDialogState();
}

class _TopUpDialogState extends ConsumerState<TopUpDialog> {
  int _selectedAmount = -1;
  int _selectedMethod = 0;
  final _customAmountController = TextEditingController();
  bool _isProcessing = false;
  String? _errorMessage;

  final List<double> _quickAmounts = [20, 50, 100, 200];
  final List<PaymentMethodItem> _paymentMethods = [
    PaymentMethodItem(
      label: 'MTN Mobile Money',
      sub: '+233 24 123 4567',
      icon: Icons.phone_android_rounded,
      color: const Color(0xFFFFCC00),
      type: 'Mobile Money',
    ),
    PaymentMethodItem(
      label: 'Visa Card',
      sub: '•••• 4321 • Expires 08/27',
      icon: Icons.credit_card_rounded,
      color: AppColors.info,
      type: 'Card',
    ),
    PaymentMethodItem(
      label: 'Bank Transfer',
      sub: 'Direct bank transfer',
      icon: Icons.account_balance_rounded,
      color: AppColors.primary,
      type: 'Bank Transfer',
    ),
  ];

  @override
  void dispose() {
    _customAmountController.dispose();
    super.dispose();
  }

  double? get _selectedAmountValue {
    if (_selectedAmount >= 0) {
      return _quickAmounts[_selectedAmount];
    }
    final custom = double.tryParse(_customAmountController.text);
    return custom != null && custom > 0 ? custom : null;
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
                  child: Text(
                    'Top Up Wallet',
                    style: AppTextStyles.heading3,
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

            // Quick amount chips
            _buildAmountSection(),
            const SizedBox(height: 20),

            // Payment methods
            _buildPaymentMethodsSection(),
            const SizedBox(height: 24),

            // Error message
            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.errorLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: AppColors.error, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
                      ),
                    ),
                  ],
                ),
              ),

            // Action button
            CTAButton(
              onTap: _isProcessing ? null : _processTopUp,
              text: _isProcessing
                  ? 'Processing...'
                  : (_selectedAmountValue != null
                      ? 'Top up GHS ${_selectedAmountValue!.toStringAsFixed(2)}'
                      : 'Select amount'),
              isLoading: _isProcessing,
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
                onTap: () {
                  setState(() {
                    _selectedAmount = entry.key;
                    _customAmountController.clear();
                    _errorMessage = null;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.primary : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? AppColors.primary : AppColors.border,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Text(
                    'GHS ${entry.value}',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isSelected ? Colors.white : AppColors.textPrimary,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              );
            }),
            // Custom amount input
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: TextField(
                  controller: _customAmountController,
                  keyboardType: TextInputType.number,
                  onChanged: (_) {
                    setState(() {
                      _selectedAmount = -1;
                      _errorMessage = null;
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'Custom amount',
                    prefixText: 'GHS ',
                    hintStyle: AppTextStyles.bodySmall.copyWith(color: AppColors.textTertiary),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPaymentMethodsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Pay with', style: AppTextStyles.labelLarge),
        const SizedBox(height: 10),
        ..._paymentMethods.asMap().entries.map((entry) {
          final isSelected = _selectedMethod == entry.key;
          final method = entry.value;
          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedMethod = entry.key;
                _errorMessage = null;
              });
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.primary.withValues(alpha: 0.05) : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.border,
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: method.color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(method.icon, color: method.color, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(method.label, style: AppTextStyles.labelLarge),
                        Text(method.sub, style: AppTextStyles.caption),
                      ],
                    ),
                  ),
                  if (isSelected)
                    const Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 20),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Future<void> _processTopUp() async {
    final amount = _selectedAmountValue;
    if (amount == null || amount <= 0) {
      setState(() {
        _errorMessage = 'Please select or enter a valid amount';
      });
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final paymentMethod = _paymentMethods[_selectedMethod];
      
      // Call wallet controller to process top-up
      final walletController = ref.read(walletControllerProvider);
      final success = await walletController.topUp(
        amount: amount,
        paymentMethod: paymentMethod.type,
      );

      if (success && mounted) {
        Navigator.pop(context, true); // Return success
      } else if (mounted) {
        setState(() {
          _errorMessage = 'Payment failed. Please try again.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }
}

class PaymentMethodItem {
  final String label;
  final String sub;
  final IconData icon;
  final Color color;
  final String type;

  PaymentMethodItem({
    required this.label,
    required this.sub,
    required this.icon,
    required this.color,
    required this.type,
  });
}