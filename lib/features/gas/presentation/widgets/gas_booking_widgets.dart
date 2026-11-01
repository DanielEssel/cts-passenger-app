// lib/features/gas/presentation/widgets/gas_booking_widgets.dart
//
// Presentation pieces of the Gas order screens (the header is the shared
// CtsPhotoHeader):
//
//   GasSection       borderless white section card with an icon and step
//   GasGroupLabel    small label for a group of options inside a section
//   GasOptionSurface selectable surface: soft fill, green ring when chosen
//
// Presentation only. Order logic, validation and pricing stay in
// gas_order_screen.dart.

import 'package:flutter/material.dart';

import '../../../../core/theme/cts_theme.dart';

/// The CTSGo brand greens used by the Gas screen.
abstract final class GasPalette {
  static const Color green = Color(0xFF16A34A);
  static const Color greenDeep = Color(0xFF15803D);
  static const Color mint = Color(0xFFDCFCE7);
  static const Color forest = Color(0xFF0F3D24);

  /// Selected service card: forest into deep green.
  static const LinearGradient selectedGradient = LinearGradient(
    colors: [forest, greenDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Fill of an option that is not selected; no outline.
  static const Color idleFill = Color(0xFFF3F6F4);

  static List<BoxShadow> get sectionShadow => [
        BoxShadow(
          color: forest.withValues(alpha: 0.06),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
        BoxShadow(
          color: forest.withValues(alpha: 0.04),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
      ];

  static List<BoxShadow> get selectedGlow => [
        BoxShadow(
          color: greenDeep.withValues(alpha: 0.28),
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
      ];
}

/// A white, borderless section of the order form: an icon tile, a step
/// label, the title and an optional caption, then the content.
class GasSection extends StatelessWidget {
  final int step;
  final IconData icon;
  final String title;
  final String? caption;
  final Widget child;

  const GasSection({
    super.key,
    required this.step,
    required this.icon,
    required this.title,
    required this.child,
    this.caption,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        decoration: BoxDecoration(
          color: CtsTheme.surface,
          borderRadius: BorderRadius.circular(22),
          boxShadow: GasPalette.sectionShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: GasPalette.mint,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(icon, size: 21, color: GasPalette.greenDeep),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'STEP $step',
                        style: CtsText.overline.copyWith(
                          color: GasPalette.greenDeep,
                          fontSize: 11,
                          letterSpacing: 0.9,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: CtsText.section.copyWith(
                            fontSize: 17.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      if (caption != null) ...[
                        const SizedBox(height: 3),
                        Text(caption!, style: CtsText.bodySmall),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      );
}

/// Small heading for a group of options inside a [GasSection].
class GasGroupLabel extends StatelessWidget {
  final String text;
  final String? caption;

  const GasGroupLabel(this.text, {super.key, this.caption});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: CtsText.label.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: CtsTheme.textPrimary,
              ),
            ),
            if (caption != null)
              Text(caption!, style: CtsText.bodySmall.copyWith(fontSize: 13)),
          ],
        ),
      );
}

/// A selectable option: a soft fill without an outline while idle; a
/// green ring, mint fill and lift once chosen. Announced as a selectable
/// button in a group.
class GasOptionSurface extends StatelessWidget {
  final bool selected;
  final String semanticLabel;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Widget child;

  const GasOptionSurface({
    super.key,
    required this.selected,
    required this.semanticLabel,
    required this.onTap,
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      inMutuallyExclusiveGroup: true,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected ? CtsTheme.primaryTint : GasPalette.idleFill,
          borderRadius: radius,
          border: Border.all(
            color: selected ? GasPalette.green : Colors.transparent,
            width: 1.5,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: GasPalette.green.withValues(alpha: 0.14),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// Filled check shown on a selected option.
class GasCheckBadge extends StatelessWidget {
  final bool selected;
  final bool onDark;
  const GasCheckBadge({super.key, required this.selected, this.onDark = false});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected
              ? (onDark ? GasPalette.mint : GasPalette.green)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? Colors.transparent
                : (onDark
                    ? Colors.white.withValues(alpha: 0.5)
                    : CtsTheme.textDisabled),
            width: 1.5,
          ),
        ),
        child: selected
            ? Icon(Icons.check_rounded,
                size: 15, color: onDark ? GasPalette.forest : Colors.white)
            : null,
      );
}
