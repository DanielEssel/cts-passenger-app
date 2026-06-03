// widgets/common/dialog_widget.dart

import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';
import '../buttons/primary_button.dart';

class CustomDialog extends StatelessWidget {
  final String title;
  final String message;
  final String? positiveButtonLabel;
  final String? negativeButtonLabel;
  final VoidCallback? onPositivePressed;
  final VoidCallback? onNegativePressed;
  final IconData? icon;

  const CustomDialog({
    super.key,
    required this.title,
    required this.message,
    this.positiveButtonLabel,
    this.negativeButtonLabel,
    this.onPositivePressed,
    this.onNegativePressed,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.primaryColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: AppColors.primaryColor,
                  size: 32,
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              title,
              style: AppTextStyles.heading3,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondaryColor,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (negativeButtonLabel != null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onNegativePressed ?? () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.primaryColor),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Text(
                        negativeButtonLabel!,
                        style: AppTextStyles.buttonMedium.copyWith(
                          color: AppColors.primaryColor,
                        ),
                      ),
                    ),
                  ),
                if (negativeButtonLabel != null && positiveButtonLabel != null)
                  const SizedBox(width: 12),
                if (positiveButtonLabel != null)
                  Expanded(
                    child: PrimaryButton(
                      label: positiveButtonLabel!,
                      onTap: onPositivePressed ?? () => Navigator.pop(context),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}