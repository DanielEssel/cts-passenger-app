// widgets/buttons/secondary_button.dart

import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';

class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed; // ✅ nullable now
  final double? width;
  final double? height;
  final Color? borderColor;
  final Color? textColor;
  final bool isDisabled;
  final bool isLoading;
  final IconData? icon;

  const SecondaryButton({
    super.key,
    required this.label,
    this.onPressed, // ❗ removed required
    this.width = double.infinity,
    this.height = 56,
    this.borderColor = AppColors.primaryColor,
    this.textColor = AppColors.primaryColor,
    this.isDisabled = false,
    this.isLoading = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    // Unified disabled logic (same as PrimaryButton)
    final bool disabled = isDisabled || isLoading || onPressed == null;

    return SizedBox(
      width: width,
      height: height,
      child: OutlinedButton(
        onPressed: disabled ? null : onPressed,
        style: OutlinedButton.styleFrom(
          side: BorderSide(
            color: disabled
                ? AppColors.textDisabledColor
                : borderColor!,
            width: 2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: disabled ? AppColors.textDisabledColor : textColor),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    label,
                    style: AppTextStyles.buttonLarge.copyWith(
                      color: disabled
                          ? AppColors.textDisabledColor
                          : textColor,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}