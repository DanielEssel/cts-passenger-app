// widgets/buttons/primary_button.dart

import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';

class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap; // ✅ nullable now
  final IconData? icon;
  final bool isLoading;
  final Color? color;
  final bool isDisabled;

  const PrimaryButton({
    super.key,
    required this.label,
    this.onTap, // ✅ not required anymore
    this.icon,
    this.isLoading = false,
    this.color,
    this.isDisabled = false,
  });

  bool get _isDisabled => onTap == null && !isLoading;

  @override
  Widget build(BuildContext context) {
    final bgColor = _isDisabled
        ? AppColors.textDisabledColor
        : (color ?? AppColors.primary);

    return GestureDetector(
      onTap: _isDisabled || isLoading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(14),
          boxShadow: _isDisabled
              ? []
              : [
                  BoxShadow(
                    color: bgColor.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: isLoading
            ? const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: AppColors.background,
                    strokeWidth: 2,
                  ),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: AppColors.background, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Text(label, style: AppTextStyles.button),
                ],
              ),
      ),
    );
  }
}
