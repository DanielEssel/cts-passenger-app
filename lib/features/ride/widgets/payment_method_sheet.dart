// features/ride/widgets/payment_method_sheet.dart

import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../payment/models/payment_method.dart';
import '../services/payment_method_service.dart';

class PaymentMethodSheet extends StatelessWidget {
  final PaymentType selectedType;
  final double walletBalance;
  final ValueChanged<PaymentMethod> onMethodSelected;

  const PaymentMethodSheet({
    super.key,
    required this.selectedType,
    required this.walletBalance,
    required this.onMethodSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).padding.bottom +
            16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SheetHandle(),
          const Text('Payment Method', style: AppTextStyles.heading3),
          const SizedBox(height: 20),
          ...PaymentMethodService.availableMethods.map(
            (method) => _PaymentMethodTile(
              method: method,
              isSelected: selectedType == method.type,
              walletBalance: walletBalance,
              onTap: () {
                onMethodSelected(method);
                Navigator.pop(context);
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 4,
      margin: const EdgeInsets.only(top: 12, bottom: 20),
      decoration: BoxDecoration(
        color: AppColors.border,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _PaymentMethodTile extends StatelessWidget {
  final PaymentMethod method;
  final bool isSelected;
  final double walletBalance;
  final VoidCallback onTap;

  const _PaymentMethodTile({
    required this.method,
    required this.isSelected,
    required this.walletBalance,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primaryDim : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: isSelected ? 1.5 : 0.5,
          ),
        ),
        child: Row(
          children: [
            _TileIcon(method: method, isSelected: isSelected),
            const SizedBox(width: 12),
            Expanded(
              child: _TileDetails(
                method: method,
                isSelected: isSelected,
                walletBalance: walletBalance,
              ),
            ),
            if (isSelected) const _SelectedIndicator(),
          ],
        ),
      ),
    );
  }
}

class _TileIcon extends StatelessWidget {
  final PaymentMethod method;
  final bool isSelected;
  const _TileIcon({required this.method, required this.isSelected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: isSelected
            ? AppColors.primary.withValues(alpha: 0.15)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        method.icon,
        color: isSelected ? AppColors.primary : AppColors.textSecondary,
        size: 20,
      ),
    );
  }
}

class _TileDetails extends StatelessWidget {
  final PaymentMethod method;
  final bool isSelected;
  final double walletBalance;

  const _TileDetails({
    required this.method,
    required this.isSelected,
    required this.walletBalance,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          method.displayName,
          style: AppTextStyles.labelLarge.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          method.type == PaymentType.wallet
              ? 'Balance: ${PaymentMethodService.getFormattedBalance(walletBalance)}'
              : method.subtitle,
          style:
              AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _SelectedIndicator extends StatelessWidget {
  const _SelectedIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: const BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.check_rounded,
          color: AppColors.background, size: 14),
    );
  }
}