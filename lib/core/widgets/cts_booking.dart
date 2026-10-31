// lib/core/widgets/cts_booking.dart
//
// The CTSGo booking identity used by the Delivery and Gas booking screens:
//
//   CtsBrandHeader   deep-forest header: step, headline, supporting copy
//   CtsFormSection   numbered white section card, with an "Optional" tag
//   CtsBookingBar    pinned bottom action area with a "what's missing" hint
//   CtsPriceSummary  forest total panel; shows only the figures it is given
//
// Presentation only. Booking logic, validation and pricing stay in the
// screens and their services.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/cts_theme.dart';
import 'cts_ui.dart';

/// Light status-bar icons over the forest header.
const SystemUiOverlayStyle ctsBrandOverlay = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
);

/// Forest strip behind the status bar. Booking pages keep it fixed while
/// the [CtsBrandHeader] scrolls away with the form, so small phones with
/// large text keep room for the fields and the status icons stay legible.
class CtsStatusBarStrip extends StatelessWidget {
  const CtsStatusBarStrip({super.key});

  @override
  Widget build(BuildContext context) => Container(
        height: MediaQuery.of(context).padding.top,
        color: CtsTheme.forest,
      );
}

/// Branded header for a booking flow: back button, an optional step label,
/// a short headline, one line of supporting copy and a visual on the right.
/// Place it at the top of the page's scroll view, under a
/// [CtsStatusBarStrip]; it does not add the status-bar inset itself.
class CtsBrandHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  /// Small label above the title, e.g. "Step 1 of 2 · Route & parcel".
  final String? eyebrow;

  /// Shown on the right: an icon (in a tinted tile) or any widget.
  final IconData? icon;
  final Widget? visual;

  /// Extra action next to the back button (e.g. help).
  final Widget? trailing;

  /// Content under the title, e.g. a progress indicator.
  final Widget? footer;

  const CtsBrandHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.eyebrow,
    this.icon,
    this.visual,
    this.trailing,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final side = visual ??
        (icon == null
            ? null
            : Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.18)),
                ),
                // Light green: brand green is 2.6:1 on this tile.
                child: Icon(icon, color: CtsTheme.appleSoft, size: 30),
              ));
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: CtsTheme.forestGradient,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(ctsGutter, 6, ctsGutter, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CtsHeaderIconButton(
                    icon: Icons.arrow_back_rounded,
                    label: 'Back',
                    onTap: () => Navigator.maybePop(context),
                  ),
                  const Spacer(),
                  if (trailing != null) trailing!,
                ],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (eyebrow != null) ...[
                          Text(
                            eyebrow!.toUpperCase(),
                            style: CtsText.overline
                                .copyWith(color: CtsTheme.appleSoft),
                          ),
                          const SizedBox(height: 6),
                        ],
                        Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: CtsText.title1.copyWith(
                              color: Colors.white,
                              fontSize: 25,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          style: CtsText.body.copyWith(
                            color: CtsTheme.onForestMuted,
                            fontSize: 14.5,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (side != null) ...[
                    const SizedBox(width: 14),
                    ExcludeSemantics(child: side),
                  ],
                ],
              ),
              if (footer != null) ...[
                const SizedBox(height: 18),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 48 dp round button for use on the forest header.
class CtsHeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const CtsHeaderIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: Tooltip(
          message: label,
          child: Material(
            color: Colors.white.withValues(alpha: 0.14),
            shape: CircleBorder(
              side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Icon(icon, color: Colors.white, size: 22),
              ),
            ),
          ),
        ),
      );
}

/// Step progress for the forest header: named steps, current one bold.
class CtsHeaderProgress extends StatelessWidget {
  final List<String> steps;
  final int current;

  const CtsHeaderProgress({
    super.key,
    required this.steps,
    required this.current,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Step ${current + 1} of ${steps.length}, ${steps[current]}',
        excludeSemantics: true,
        child: Row(
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: i <= current
                            ? CtsTheme.appleSoft
                            : Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      steps[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CtsText.caption.copyWith(
                        fontSize: 12.5,
                        fontWeight:
                            i == current ? FontWeight.w800 : FontWeight.w600,
                        color: i <= current
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
}

/// A numbered white section of a booking form.
class CtsFormSection extends StatelessWidget {
  final String title;
  final String? caption;

  /// Section number shown in a badge ("1"), or null for none.
  final String? number;

  /// Marks the whole section as optional.
  final bool optional;

  final Widget child;

  const CtsFormSection({
    super.key,
    required this.title,
    required this.child,
    this.caption,
    this.number,
    this.optional = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: CtsTheme.surface,
        borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
        border: Border.all(color: CtsTheme.cardEdge),
        boxShadow: optional ? null : CtsTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (number != null) ...[
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: CtsTheme.mint,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    number!,
                    style: CtsText.label.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: CtsTheme.primaryDeep,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: CtsText.section.copyWith(fontSize: 17),
                      ),
                    ),
                    if (caption != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        caption!,
                        style: CtsText.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              if (optional) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: CtsTheme.mint,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: CtsTheme.mintBorder),
                  ),
                  child: Text(
                    'Optional',
                    style: CtsText.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: CtsTheme.primaryDeep,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// A smaller heading inside a [CtsFormSection].
class CtsSubheading extends StatelessWidget {
  final String text;
  final String? caption;

  const CtsSubheading(this.text, {super.key, this.caption});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: CtsText.cardTitle.copyWith(fontWeight: FontWeight.w700),
            ),
            if (caption != null)
              Text(
                caption!,
                style: CtsText.bodySmall.copyWith(fontSize: 13),
              ),
          ],
        ),
      );
}

/// Pinned bottom action area. Sits in the page column (not over it), so it
/// never covers fields or their errors, and rises above the keyboard.
class CtsBookingBar extends StatelessWidget {
  /// What is still missing; shown above the button and announced.
  final String? hint;
  final Widget action;

  const CtsBookingBar({super.key, this.hint, required this.action});

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          color: CtsTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          boxShadow: [
            BoxShadow(
              color: Color(0x1417211B),
              blurRadius: 20,
              offset: Offset(0, -6),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(ctsGutter, 14, ctsGutter, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hint != null && hint!.isNotEmpty) ...[
                  Semantics(
                    liveRegion: true,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 1),
                          child: Icon(Icons.info_outline_rounded,
                              size: 18, color: CtsTheme.primary),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            hint!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: CtsText.bodySmall.copyWith(
                              color: CtsTheme.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                action,
              ],
            ),
          ),
        ),
      );
}

/// One line of a price summary.
class CtsPriceLine {
  final String label;
  final String value;
  const CtsPriceLine(this.label, this.value);
}

/// Forest panel with the price lines and a prominent total. Shows only the
/// figures it is given: pass [total] as null while a price is not known.
class CtsPriceSummary extends StatelessWidget {
  final List<CtsPriceLine> lines;
  final String totalLabel;
  final String? total;

  /// Shown instead of the total while it is not known yet.
  final String pendingText;

  /// A note under the total, e.g. "Final fare may vary".
  final String? note;

  const CtsPriceSummary({
    super.key,
    required this.lines,
    this.totalLabel = 'Total',
    required this.total,
    this.pendingText = 'Calculating…',
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    const muted = CtsTheme.onForestMuted;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: CtsTheme.forestGradient,
        borderRadius: BorderRadius.circular(CtsTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in lines) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(l.label,
                      style: CtsText.bodySmall
                          .copyWith(fontSize: 14, color: muted)),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    l.value,
                    textAlign: TextAlign.end,
                    style: CtsText.price.copyWith(
                      fontSize: 14.5,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Divider(height: 18, color: Colors.white.withValues(alpha: 0.18)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  totalLabel,
                  style: CtsText.cardTitle.copyWith(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  total ?? pendingText,
                  textAlign: TextAlign.end,
                  style: CtsText.priceLarge.copyWith(
                    fontSize: total == null ? 15 : 26,
                    color: total == null ? muted : Colors.white,
                  ),
                ),
              ),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded, size: 16, color: muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(note!,
                      style: CtsText.bodySmall
                          .copyWith(fontSize: 13, color: muted)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
