// lib/core/widgets/cts_photo_header.dart
//
// Compact, permanent header for a service booking page (Gas, Delivery):
// forest band with the back button and title on the left and the service
// photo filling the right, faded into the forest. It sits above the page's
// scroll view (it never scrolls), under a CtsStatusBarStrip.
//
//   ┌──────────────────────────────────────────┐
//   │ (←)  EYEBROW                 ░▒▓ photo ▓ │
//   │      Title                   ░▒▓       ▓ │
//   │      One or two lines        ░▒▓  (?)  ▓ │
//   │ ▬▬▬▬▬ ▬▬▬▬▬ ▬▬▬▬▬ footer (progress)      │
//   └──────────────────────────────────────────┘
//
// Presentation only.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/cts_theme.dart';
import 'cts_booking.dart';
import 'cts_ui.dart';

class CtsPhotoHeader extends StatelessWidget {
  /// The service photo (an asset), e.g. assets/images/services/gas.jpeg.
  final String image;

  /// Width ÷ height of [image]: the photo is drawn at most this wide for
  /// the header's height, so its subject is never cropped top and bottom.
  final double imageAspectRatio;

  /// Which part of the photo stays in view when it is cropped sideways.
  final Alignment imageAlignment;

  final String title;
  final String subtitle;

  /// Small label above the title, e.g. "Step 1 of 2 · Route & parcel".
  final String? eyebrow;

  /// An action (e.g. help): under the back button, at the start of the
  /// footer row (alone when there is no footer), so the controls form one
  /// rail on the left and nothing ever sits on the photo; at the end of the
  /// title row only while condensed.
  final Widget? trailing;

  /// Under the title, full width, e.g. a CtsHeaderProgress.
  final Widget? footer;

  /// Only the title row (the keyboard is open): the header stays in place
  /// but gives the form its room.
  final bool condensed;

  /// Caps the content width on tablets and in landscape; the forest still
  /// runs edge to edge.
  final double? maxContentWidth;

  const CtsPhotoHeader({
    super.key,
    required this.image,
    required this.imageAspectRatio,
    required this.title,
    required this.subtitle,
    this.imageAlignment = Alignment.center,
    this.eyebrow,
    this.trailing,
    this.footer,
    this.condensed = false,
    this.maxContentWidth,
  });

  static const Radius _radius = Radius.circular(26);

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final screenWidth = screen.width;
    // Short screens (small phones, landscape) keep the photo, eyebrow and
    // title but drop the supporting line; very short ones the eyebrow too.
    final showSubtitle = !condensed && screen.height >= 700;
    final showEyebrow = !condensed && screen.height >= 460;
    final narrow = screenWidth < 360;
    final capped = maxContentWidth != null && screenWidth > maxContentWidth!;
    final showFooter = footer != null && !condensed;
    // The left rail (back, then the action under it) whenever the header is
    // not condensed, with or without a footer, so the action never covers
    // the photo.
    final railRow = !condensed && (showFooter || trailing != null);
    // A header, not body copy: it grows with the text size up to 1.3x, so
    // on a small phone with large text the form keeps most of the screen.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: CtsTheme.forest,
          borderRadius: const BorderRadius.vertical(bottom: _radius),
          boxShadow: [
            BoxShadow(
              color: CtsTheme.forest.withValues(alpha: 0.22),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(bottom: _radius),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: maxContentWidth ?? double.infinity),
              child: LayoutBuilder(builder: (context, c) {
                final w = c.maxWidth;
                // The photo takes the right ~38%; the text may run into its
                // faded left edge.
                final double photoWidth = (w * 0.38).clamp(118.0, 280.0);
                // Narrow phones need the room; elsewhere the text stops
                // before the photo's subject begins.
                final textRight = w - photoWidth * (narrow ? 0.70 : 0.76);
                return Stack(children: [
                  Positioned(
                    top: 0,
                    right: 0,
                    bottom: 0,
                    width: photoWidth,
                    child: ExcludeSemantics(
                      child: _ServicePhoto(
                        image: image,
                        aspectRatio: imageAspectRatio,
                        alignment: imageAlignment,
                        fadeRight: capped,
                        fadeBottom: railRow,
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        ctsGutter, 6, ctsGutter, condensed ? 10 : 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CtsHeaderIconButton(
                              icon: Icons.arrow_back_rounded,
                              label: 'Back',
                              onTap: () => Navigator.maybePop(context),
                            ),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: math.max(
                                  0.0, textRight - ctsGutter - 48.0 - 12.0),
                              child: Padding(
                                padding:
                                    EdgeInsets.only(top: condensed ? 12 : 4),
                                child: _titleBlock(
                                    showSubtitle: showSubtitle,
                                    showEyebrow: showEyebrow,
                                    narrow: narrow),
                              ),
                            ),
                            const Spacer(),
                            if (trailing != null && !railRow)
                              _onPhoto(trailing!),
                          ],
                        ),
                        if (railRow) ...[
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (trailing != null) ...[
                                trailing!,
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                  child: showFooter
                                      ? footer!
                                      : const SizedBox.shrink()),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ]);
              }),
            ),
          ),
        ),
      ),
    );
  }

  /// A dark disc keeps a light header button legible wherever the photo is.
  static Widget _onPhoto(Widget button) => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: CtsTheme.forest.withValues(alpha: 0.55),
        ),
        child: button,
      );

  Widget _titleBlock(
          {required bool showSubtitle,
          required bool showEyebrow,
          required bool narrow}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (eyebrow != null && showEyebrow) ...[
            Text(
              eyebrow!.toUpperCase(),
              // A step label is information: it wraps rather than being cut.
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: CtsText.overline.copyWith(
                color: CtsTheme.appleSoft,
                fontSize: 11,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Semantics(
            header: true,
            child: Text(
              title,
              maxLines: condensed ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: CtsText.title1.copyWith(
                color: Colors.white,
                fontSize: narrow ? 19 : 21,
                height: 1.15,
                letterSpacing: -0.4,
              ),
            ),
          ),
          if (showSubtitle) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: CtsText.bodySmall.copyWith(
                color: CtsTheme.onForestMuted,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ],
        ],
      );
}

/// The photo panel: drawn no wider than the photo's own proportions allow
/// for the panel's height (so nothing is cut top and bottom), right
/// aligned, and faded into the forest on the left and top, at the bottom
/// when a footer runs over it, and on the right when the content is capped
/// and the panel does not reach the screen edge.
class _ServicePhoto extends StatelessWidget {
  final String image;
  final double aspectRatio;
  final Alignment alignment;
  final bool fadeRight;
  final bool fadeBottom;

  const _ServicePhoto({
    required this.image,
    required this.aspectRatio,
    required this.alignment,
    required this.fadeRight,
    required this.fadeBottom,
  });

  static Shader _horizontal(Rect r, bool fadeRight) => LinearGradient(
        colors: [
          Colors.black.withValues(alpha: 0),
          Colors.black.withValues(alpha: 0.2),
          Colors.black.withValues(alpha: 0.65),
          Colors.black,
          Colors.black,
          Colors.black.withValues(alpha: fadeRight ? 0 : 1),
        ],
        stops: const <double>[0.0, 0.14, 0.3, 0.46, 0.82, 1.0],
      ).createShader(r);

  static Shader _vertical(Rect r, bool fadeBottom) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withValues(alpha: 0),
          Colors.black.withValues(alpha: 0.55),
          Colors.black,
          Colors.black,
          Colors.black.withValues(alpha: fadeBottom ? 0.08 : 0.85),
        ],
        // Fully faded at the top, so there is no edge under the status bar.
        stops: <double>[0.0, 0.12, 0.26, fadeBottom ? 0.62 : 0.85, 1.0],
      ).createShader(r);

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final h = c.maxHeight;
        final drawWidth = math.min(c.maxWidth, h * aspectRatio);
        final dpr = MediaQuery.devicePixelRatioOf(context);
        // Decoded near the drawn size (the photo covers drawWidth × h).
        final int decode =
            math.min(1400, math.max(200, (h * aspectRatio * dpr).ceil()));
        return Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: drawWidth,
            height: h,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => _vertical(r, fadeBottom),
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (r) => _horizontal(r, fadeRight),
                child: Image.asset(
                  image,
                  fit: BoxFit.cover,
                  alignment: alignment,
                  cacheWidth: decode,
                  filterQuality: FilterQuality.medium,
                  // No photo: the forest alone still reads as the header.
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        );
      });
}
