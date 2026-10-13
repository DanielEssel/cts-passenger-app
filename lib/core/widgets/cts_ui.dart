// lib/core/widgets/cts_ui.dart
//
// Small shared building blocks for the CTSGo service screens (Ride, Delivery,
// Gas), styled to match the Home screen. They use borders and at most one
// light shadow rather than stacked blurs, so screens stay cheap to rasterise
// during page transitions.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/cts_theme.dart';

/// Horizontal page margin shared by the service screens.
const double ctsGutter = 16;

/// 44 dp circular back button. Pops the current route by default.
class CtsBackButton extends StatelessWidget {
  final VoidCallback? onTap;
  final bool elevated;

  const CtsBackButton({super.key, this.onTap, this.elevated = false});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Back',
        excludeSemantics: true,
        onTap: onTap ?? () => Navigator.maybePop(context),
        child: Material(
          color: CtsTheme.surface,
          shape: const CircleBorder(side: BorderSide(color: CtsTheme.border)),
          elevation: elevated ? 2 : 0,
          shadowColor: Colors.black26,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap ?? () => Navigator.maybePop(context),
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.arrow_back_rounded,
                  color: CtsTheme.textPrimary, size: 20),
            ),
          ),
        ),
      );
}

/// Light page header: back button, title, optional subtitle and trailing
/// action. Handles the top safe area itself.
class CtsServiceHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const CtsServiceHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(ctsGutter, 8, ctsGutter, 8),
          child: Row(
            children: [
              const CtsBackButton(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          color: CtsTheme.textPrimary,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        )),
                    if (subtitle != null)
                      Text(subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: CtsTheme.textSecondary,
                            fontSize: 12.5,
                          )),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
      );
}

/// White rounded card with a hairline border.
class CtsCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;

  const CtsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: CtsTheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor ?? CtsTheme.border),
        ),
        child: child,
      );
}

/// Section title with optional supporting text or trailing widget.
class CtsSectionHeader extends StatelessWidget {
  final String title;
  final String? caption;
  final Widget? trailing;

  const CtsSectionHeader(this.title, {super.key, this.caption, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        color: CtsTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      )),
                  if (caption != null) ...[
                    const SizedBox(height: 2),
                    Text(caption!,
                        style: const TextStyle(
                          color: CtsTheme.textSecondary,
                          fontSize: 12.5,
                        )),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

/// A tappable option with a clear selected state: green border, green tint
/// and a check mark. Announces itself as a selectable button.
class CtsSelectableCard extends StatelessWidget {
  final bool selected;
  final VoidCallback? onTap;
  final Widget child;
  final String semanticLabel;
  final EdgeInsetsGeometry padding;
  final bool showCheck;

  const CtsSelectableCard({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
    required this.semanticLabel,
    this.padding = const EdgeInsets.all(14),
    this.showCheck = true,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? CtsTheme.primaryTint : CtsTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? CtsTheme.primary : CtsTheme.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              Padding(padding: padding, child: child),
              if (showCheck && selected)
                const Positioned(
                  top: 8,
                  right: 8,
                  child: CtsCheckDot(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small filled check used to mark a selection.
class CtsCheckDot extends StatelessWidget {
  final double size;
  const CtsCheckDot({super.key, this.size = 20});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: CtsTheme.primary,
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.check_rounded, color: Colors.white, size: size * 0.7),
      );
}

/// Full-width primary action. Disabled when [onPressed] is null; shows a
/// spinner and ignores taps while [loading].
class CtsPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;
  final String? trailingText;

  const CtsPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.icon,
    this.trailingText,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    return Semantics(
      button: true,
      enabled: enabled,
      label: [label, trailingText].whereType<String>().join(', '),
      excludeSemantics: true,
      onTap: enabled ? onPressed : null,
      child: SizedBox(
        width: double.infinity,
        height: 54,
        child: Material(
          color: enabled || loading ? CtsTheme.primary : CtsTheme.border,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: loading
                  ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white),
                      ),
                    )
                  : Row(
                      children: [
                        if (icon != null) ...[
                          Icon(icon,
                              size: 19,
                              color: enabled
                                  ? Colors.white
                                  : CtsTheme.textTertiary),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                color: enabled
                                    ? Colors.white
                                    : CtsTheme.textTertiary,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w800,
                              )),
                        ),
                        if (trailingText != null) ...[
                          const SizedBox(width: 8),
                          Text(trailingText!,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                color: enabled
                                    ? Colors.white
                                    : CtsTheme.textTertiary,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w800,
                              )),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Labelled text input with an inline error. The error is shown as text
/// with an icon, not by colour alone.
class CtsTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String label;
  final String? hint;
  final IconData? icon;
  final String? errorText;
  final String? helperText;
  final bool optional;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final int maxLines;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final Widget? suffix;
  final TextCapitalization textCapitalization;
  final Iterable<String>? autofillHints;

  const CtsTextField({
    super.key,
    this.controller,
    required this.label,
    this.hint,
    this.icon,
    this.errorText,
    this.helperText,
    this.optional = false,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.maxLines = 1,
    this.maxLength,
    this.onChanged,
    this.suffix,
    this.textCapitalization = TextCapitalization.none,
    this.autofillHints,
  });

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null;
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: c, width: w),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(children: [
            TextSpan(text: label),
            if (optional)
              const TextSpan(
                text: '  Optional',
                style: TextStyle(
                  color: CtsTheme.textTertiary,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ]),
          style: const TextStyle(
            color: CtsTheme.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          inputFormatters: inputFormatters,
          maxLines: maxLines,
          minLines: 1,
          maxLength: maxLength,
          onChanged: onChanged,
          textCapitalization: textCapitalization,
          autofillHints: autofillHints,
          style: const TextStyle(
            fontSize: 14.5,
            color: CtsTheme.textPrimary,
            fontWeight: FontWeight.w500,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle:
                const TextStyle(fontSize: 14, color: CtsTheme.textTertiary),
            counterText: '',
            isDense: true,
            filled: true,
            fillColor: CtsTheme.surface,
            prefixIcon: icon == null
                ? null
                : Icon(icon, size: 19, color: CtsTheme.textSecondary),
            suffixIcon: suffix,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            enabledBorder: border(hasError ? CtsTheme.error : CtsTheme.border),
            focusedBorder:
                border(hasError ? CtsTheme.error : CtsTheme.primary, 1.5),
            border: border(CtsTheme.border),
          ),
        ),
        if (hasError || helperText != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasError) ...[
                  const Icon(Icons.error_outline_rounded,
                      size: 15, color: CtsTheme.error),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Text(
                    errorText ?? helperText!,
                    style: TextStyle(
                      fontSize: 12,
                      color: hasError ? CtsTheme.error : CtsTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Pill-shaped single choice (e.g. parcel type). At least 44 dp tall.
class CtsChoicePill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const CtsChoicePill({
    super.key,
    required this.label,
    this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          color: selected ? CtsTheme.primaryTint : CtsTheme.surface,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? CtsTheme.primary : CtsTheme.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon,
                          size: 17,
                          color: selected
                              ? CtsTheme.primaryDeep
                              : CtsTheme.textSecondary),
                      const SizedBox(width: 7),
                    ],
                    Text(label,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w600,
                          color: CtsTheme.textPrimary,
                        )),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

/// Full-screen problem state with a plain explanation and a way forward.
/// Never shows raw exception text.
class CtsErrorState extends StatelessWidget {
  final String title;
  final String message;
  final IconData icon;
  final String retryLabel;
  final VoidCallback? onRetry;
  final VoidCallback? onBack;

  const CtsErrorState({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.wifi_off_rounded,
    this.retryLabel = 'Try again',
    this.onRetry,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: CtsTheme.surfaceAlt,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 30, color: CtsTheme.textSecondary),
                ),
                const SizedBox(height: 16),
                Text(title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: CtsTheme.textPrimary,
                    )),
                const SizedBox(height: 6),
                Text(message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.4,
                      color: CtsTheme.textSecondary,
                    )),
                const SizedBox(height: 20),
                if (onRetry != null)
                  CtsPrimaryButton(label: retryLabel, onPressed: onRetry),
                if (onBack != null) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: onBack,
                    style: TextButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48)),
                    child: const Text('Back to home',
                        style: TextStyle(
                          color: CtsTheme.primaryDeep,
                          fontWeight: FontWeight.w700,
                        )),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
}
