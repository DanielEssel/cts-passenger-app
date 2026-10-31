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
                        style: CtsText.title3),
                    if (subtitle != null)
                      Text(subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CtsText.bodySmall.copyWith(fontSize: 13)),
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
          borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
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
                  Semantics(
                      header: true, child: Text(title, style: CtsText.section)),
                  if (caption != null) ...[
                    const SizedBox(height: 2),
                    Text(caption!, style: CtsText.bodySmall),
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
          color: CtsTheme.vivid,
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.check_rounded,
            color: CtsTheme.onVivid, size: size * 0.7),
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
        height: CtsTheme.buttonHeight,
        child: Material(
          color: enabled || loading ? CtsTheme.vivid : CtsTheme.surfaceAlt,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
            side: enabled || loading
                ? BorderSide.none
                : const BorderSide(color: CtsTheme.border),
          ),
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
                            strokeWidth: 2.5, color: CtsTheme.onVivid),
                      ),
                    )
                  : Row(
                      children: [
                        if (icon != null) ...[
                          Icon(icon,
                              size: 19,
                              color: enabled
                                  ? CtsTheme.onVivid
                                  : CtsTheme.textTertiary),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CtsText.button.copyWith(
                                color: enabled
                                    ? CtsTheme.onVivid
                                    : CtsTheme.textTertiary,
                              )),
                        ),
                        if (trailingText != null) ...[
                          const SizedBox(width: 8),
                          Text(trailingText!,
                              style: CtsText.button.copyWith(
                                color: enabled
                                    ? CtsTheme.onVivid
                                    : CtsTheme.textTertiary,
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
          borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
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
          style: CtsText.label,
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
          style: CtsText.body.copyWith(fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: CtsText.body.copyWith(color: CtsTheme.textTertiary),
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
                    style: CtsText.caption.copyWith(
                      fontSize: 12.5,
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

/// Pill-shaped single choice (e.g. parcel type). At least 48 dp tall.
/// Selected pills use the same vivid fill as [CtsFilterChip].
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
          color: selected ? CtsTheme.vivid : CtsTheme.surface,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? CtsTheme.vivid : CtsTheme.border,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon,
                          size: 18,
                          color: selected
                              ? CtsTheme.onVivid
                              : CtsTheme.textSecondary),
                      const SizedBox(width: 7),
                    ],
                    // Wraps instead of overflowing with large text.
                    Flexible(
                      child: Text(label,
                          style: CtsText.label.copyWith(
                            fontSize: 14,
                            color: selected
                                ? CtsTheme.onVivid
                                : CtsTheme.textPrimary,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w600,
                          )),
                    ),
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
                Text(title, textAlign: TextAlign.center, style: CtsText.title3),
                const SizedBox(height: 6),
                Text(message,
                    textAlign: TextAlign.center, style: CtsText.bodySmall),
                const SizedBox(height: 20),
                if (onRetry != null)
                  CtsPrimaryButton(label: retryLabel, onPressed: onRetry),
                if (onBack != null) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: onBack,
                    style: TextButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48)),
                    child: const Text('Back to home'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
}

// ── Shared page building blocks ─────────────────────────────────────────────
// Used by Wallet, History, Profile and the account screens so they read as
// one family. Interactive pieces pass their callback to Semantics as well as
// to the gesture handler: screen readers can activate them, and lose the
// action (and announce "disabled") when the callback is null.

/// 44 dp round close / cancel control. Shows a spinner and ignores taps
/// while [loading].
class CtsCloseButton extends StatelessWidget {
  final VoidCallback? onTap;
  final bool loading;
  final String label;

  const CtsCloseButton({
    super.key,
    required this.onTap,
    this.loading = false,
    this.label = 'Close',
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !loading;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: Material(
        color: CtsTheme.surface,
        shape: const CircleBorder(side: BorderSide(color: CtsTheme.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 44,
            height: 44,
            child: loading
                ? const Padding(
                    padding: EdgeInsets.all(11),
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: CtsTheme.error),
                  )
                : const Icon(Icons.close_rounded,
                    size: 20, color: CtsTheme.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// Title block for top-level tab pages (Trips, Wallet, Profile): a large
/// left-aligned title, optional supporting line and trailing actions.
class CtsPageTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Color color;

  const CtsPageTitle(
    this.title, {
    super.key,
    this.subtitle,
    this.trailing,
    this.color = CtsTheme.textPrimary,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(ctsGutter, 12, ctsGutter, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(title,
                        style: CtsText.title1.copyWith(color: color)),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        style: CtsText.bodySmall.copyWith(
                            color: color == CtsTheme.textPrimary
                                ? CtsTheme.textSecondary
                                : CtsTheme.onForestMuted)),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
      );
}

/// Filter chip used in a horizontal row (Wallet, Trips). Selected chips are
/// filled with the vivid brand green.
class CtsFilterChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const CtsFilterChip({
    super.key,
    required this.label,
    this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? CtsTheme.onVivid : CtsTheme.textPrimary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? CtsTheme.vivid : CtsTheme.surface,
        shape: StadiumBorder(
          side: BorderSide(color: selected ? CtsTheme.vivid : CtsTheme.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: fg),
                    const SizedBox(width: 6),
                  ],
                  Text(label,
                      style: CtsText.label.copyWith(
                        color: fg,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w600,
                      )),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Semantic colour role for pills, icon tiles and amounts.
enum CtsTone { brand, success, warning, error, info, neutral, delivery, gas }

extension CtsToneColors on CtsTone {
  Color get foreground => switch (this) {
        CtsTone.brand || CtsTone.success => CtsTheme.primaryDeep,
        CtsTone.warning => CtsTheme.warning,
        CtsTone.error => CtsTheme.errorDeep,
        CtsTone.info => CtsTheme.info,
        CtsTone.neutral => CtsTheme.textSecondary,
        CtsTone.delivery => CtsTheme.serviceDelivery,
        CtsTone.gas => CtsTheme.serviceGas,
      };

  Color get background => switch (this) {
        CtsTone.brand || CtsTone.success => CtsTheme.appleSoft,
        CtsTone.warning => CtsTheme.warningTint,
        CtsTone.error => CtsTheme.errorTint,
        CtsTone.info => CtsTheme.infoTint,
        CtsTone.neutral => CtsTheme.surfaceAlt,
        CtsTone.delivery => CtsTheme.serviceDeliveryTint,
        CtsTone.gas => CtsTheme.serviceGasTint,
      };
}

/// Small status label ("Completed", "Pending"). Colour backs up the text;
/// it never carries meaning alone.
class CtsStatusPill extends StatelessWidget {
  final String label;
  final CtsTone tone;

  const CtsStatusPill(this.label, {super.key, this.tone = CtsTone.neutral});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: tone.background,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CtsText.caption.copyWith(
              color: tone.foreground,
              fontWeight: FontWeight.w700,
            )),
      );
}

/// Rounded square holding a row or card icon.
class CtsIconTile extends StatelessWidget {
  final IconData icon;
  final CtsTone tone;
  final double size;

  const CtsIconTile(this.icon,
      {super.key, this.tone = CtsTone.brand, this.size = 40});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: tone.background,
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: Icon(icon, size: size * 0.5, color: tone.foreground),
      );
}

/// A titled group of [CtsListRow]s in one card (settings, account menus).
class CtsListGroup extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  final bool danger;

  const CtsListGroup({
    super.key,
    this.title,
    required this.children,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Semantics(
                header: true,
                child: Text(title!,
                    style: CtsText.label.copyWith(
                        color: danger
                            ? CtsTheme.errorDeep
                            : CtsTheme.textSecondary)),
              ),
            ),
          Container(
            decoration: BoxDecoration(
              color: CtsTheme.surface,
              borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
              border: Border.all(
                  color: danger ? CtsTheme.errorBorder : CtsTheme.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    const Divider(
                        height: 1, indent: 68, color: CtsTheme.borderLight),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      );
}

/// One tappable row: icon tile, title, optional subtitle and trailing
/// widget (chevron by default). [destructive] rows use the error colours.
class CtsListRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;
  final CtsTone? tone;

  const CtsListRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final t = tone ?? (destructive ? CtsTone.error : CtsTone.brand);
    return MergeSemantics(
      child: Semantics(
        button: onTap != null,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  CtsIconTile(icon, tone: t),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title,
                            style: CtsText.cardTitle.copyWith(
                              color: destructive
                                  ? CtsTheme.errorDeep
                                  : CtsTheme.textPrimary,
                            )),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(subtitle!,
                              style: CtsText.bodySmall.copyWith(fontSize: 13)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  trailing ??
                      (onTap == null
                          ? const SizedBox.shrink()
                          : Icon(Icons.chevron_right_rounded,
                              size: 22,
                              color: destructive
                                  ? CtsTheme.errorDeep
                                  : CtsTheme.textTertiary)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One figure in a [CtsStatRow].
class CtsStat {
  final String value;
  final String label;
  const CtsStat(this.value, this.label);
}

/// A white card of two to four key figures separated by hairlines.
class CtsStatRow extends StatelessWidget {
  final List<CtsStat> stats;
  const CtsStatRow({super.key, required this.stats});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: CtsTheme.surface,
          borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
          border: Border.all(color: CtsTheme.border),
        ),
        child: IntrinsicHeight(
          child: Row(
            children: [
              for (var i = 0; i < stats.length; i++) ...[
                if (i > 0)
                  const VerticalDivider(
                      width: 1, thickness: 1, color: CtsTheme.borderLight),
                Expanded(
                  child: Semantics(
                    label: '${stats[i].label}: ${stats[i].value}',
                    excludeSemantics: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Column(
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(stats[i].value, style: CtsText.price),
                          ),
                          const SizedBox(height: 2),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(stats[i].label,
                                maxLines: 1, style: CtsText.caption),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
}

/// Empty or "nothing here yet" state with an optional next step.
class CtsEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Show the action as the primary (vivid) button instead of outlined.
  final bool primaryAction;

  const CtsEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.primaryAction = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: CtsTheme.appleSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 30, color: CtsTheme.primaryDeep),
            ),
            const SizedBox(height: 14),
            Text(title, textAlign: TextAlign.center, style: CtsText.title3),
            const SizedBox(height: 6),
            Text(message,
                textAlign: TextAlign.center, style: CtsText.bodySmall),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              primaryAction
                  ? CtsPrimaryButton(label: actionLabel!, onPressed: onAction)
                  : CtsSecondaryButton(
                      label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      );
}

/// Outlined secondary action, or a destructive one when [destructive].
class CtsSecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool destructive;
  final bool expand;

  const CtsSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? CtsTheme.errorDeep : CtsTheme.textPrimary;
    final button = OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: fg,
        backgroundColor: destructive ? CtsTheme.errorTint : CtsTheme.surface,
        side: BorderSide(
            color: destructive ? CtsTheme.errorBorder : CtsTheme.border,
            width: 1.2),
        minimumSize: Size(expand ? double.infinity : 64, CtsTheme.minTouch),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 19, color: fg),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(label,
                textAlign: TextAlign.center,
                style: CtsText.button.copyWith(fontSize: 15, color: fg)),
          ),
        ],
      ),
    );
    return button;
  }
}

/// Grey placeholder block for loading skeletons.
class CtsSkeleton extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;
  const CtsSkeleton({super.key, this.width, this.height = 14, this.radius = 6});

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: CtsTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(radius),
        ),
      );
}

/// Full-height page body that keeps its Spacer-based layout when it fits
/// and scrolls instead of overflowing when it doesn't (small phones, large
/// text).
class CtsFillScrollView extends StatelessWidget {
  final Widget child;
  const CtsFillScrollView({super.key, required this.child});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (_, box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: IntrinsicHeight(child: child),
          ),
        ),
      );
}

/// Large headline text that never breaks a word across lines. It keeps the
/// user's text scale when every word fits, and steps the scale down only as
/// far as needed when one would not (large text on a narrow phone). Lines
/// still wrap between words.
///
/// Width is the screen width minus [horizontalInset] (the page padding on
/// both sides) rather than a LayoutBuilder, so it also works inside
/// intrinsic-height layouts such as [CtsFillScrollView].
class CtsWholeWordText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final TextAlign textAlign;

  /// Total horizontal padding between the screen edges and this text.
  final double horizontalInset;

  /// Lowest scale used for a single very long word (e.g. a long name).
  final double minScale;

  const CtsWholeWordText(
    this.text, {
    super.key,
    required this.style,
    this.textAlign = TextAlign.start,
    this.horizontalInset = ctsGutter * 2,
    this.minScale = 0.7,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final maxWidth =
        mq.size.width - mq.padding.left - mq.padding.right - horizontalInset;
    final base = style.fontSize ?? 14;
    final userScale = mq.textScaler.scale(base) / base;
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    double widest(double scale) => words
        .map((w) => (TextPainter(
              text: TextSpan(text: w, style: style),
              textDirection: Directionality.of(context),
              textScaler: TextScaler.linear(scale),
              maxLines: 1,
            )..layout())
                .width)
        .fold<double>(0, (a, b) => a > b ? a : b);

    var scale = userScale;
    while (scale > minScale && widest(scale) > maxWidth) {
      scale = (scale - 0.05).clamp(minScale, userScale);
    }
    return Text(
      text,
      style: style,
      textAlign: textAlign,
      textScaler: TextScaler.linear(scale),
    );
  }
}

/// Amount with thousands separators and two decimals: 1242.5 → "1,242.50".
String ctsMoney(double value) {
  final fixed = value.abs().toStringAsFixed(2);
  final whole = fixed.substring(0, fixed.length - 3);
  final grouped =
      whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${value < 0 ? '-' : ''}$grouped${fixed.substring(fixed.length - 3)}';
}

/// True when the user's text setting is large enough that side-by-side
/// row layouts should stack instead (accessibility sizes, small phones).
bool ctsLargeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(10) >= 13;

/// Small label above a group of rows ("Today", "Account"). Announced as a
/// heading.
class CtsGroupLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const CtsGroupLabel(
    this.text, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(ctsGutter + 4, 22, ctsGutter, 8),
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(text,
                    style: CtsText.overline.copyWith(letterSpacing: 0.2)),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

/// White card of [CtsDetailRow]s separated by hairlines (receipts, trip
/// details).
class CtsDetailCard extends StatelessWidget {
  final List<Widget> rows;
  const CtsDetailCard({super.key, required this.rows});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: CtsTheme.surface,
          borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
          border: Border.all(color: CtsTheme.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                const Divider(
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                    color: CtsTheme.borderLight),
              rows[i],
            ],
          ],
        ),
      );
}

/// Label on the left, value on the right; with large text the value moves
/// under the label so neither is squeezed. Read as "Label: value".
class CtsDetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  /// Optional action beside the value (e.g. a copy button). It keeps its
  /// own semantics.
  final Widget? trailing;

  const CtsDetailRow(this.label, this.value,
      {super.key, this.valueColor, this.trailing});

  @override
  Widget build(BuildContext context) {
    final large = ctsLargeText(context);
    final labelText = Text(label, style: CtsText.bodySmall);
    final valueText = Text(value,
        textAlign: large ? TextAlign.start : TextAlign.end,
        style: CtsText.label
            .copyWith(fontSize: 14, color: valueColor ?? CtsTheme.textPrimary));
    final content = Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: large
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelText, const SizedBox(height: 2), valueText],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                labelText,
                const SizedBox(width: 16),
                Expanded(child: valueText),
              ],
            ),
    );
    if (trailing != null && large) {
      // Action under the value so the value keeps the full width.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [content, trailing!],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 13, trailing == null ? 16 : 6, 13),
      child: trailing == null
          ? content
          : Row(children: [
              Expanded(child: content),
              const SizedBox(width: 4),
              trailing!,
            ]),
    );
  }
}
