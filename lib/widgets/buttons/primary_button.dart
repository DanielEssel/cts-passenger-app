// widgets/buttons/primary_button.dart

import 'package:flutter/material.dart';
import '../../core/theme/cts_theme.dart';

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
    // Default: vivid brand green with forest text (5.4:1). A custom
    // [color] is assumed dark and keeps white text.
    final bgColor =
        _isDisabled ? CtsTheme.surfaceAlt : (color ?? CtsTheme.vivid);
    final fgColor = _isDisabled
        ? CtsTheme.textTertiary
        : (color == null ? CtsTheme.onVivid : Colors.white);

    return Semantics(
      button: true,
      enabled: !_isDisabled && !isLoading,
      child: GestureDetector(
        onTap: _isDisabled || isLoading ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: CtsTheme.buttonHeight),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
            border: _isDisabled ? Border.all(color: CtsTheme.border) : null,
          ),
          child: isLoading
              ? Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      color: color == null ? CtsTheme.onVivid : Colors.white,
                      strokeWidth: 2.5,
                    ),
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, color: fgColor, size: 19),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: CtsText.button.copyWith(color: fgColor),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
