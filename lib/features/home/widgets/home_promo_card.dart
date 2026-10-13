// lib/features/home/widgets/home_promo_card.dart
//
// The home screen's promotional / editorial slot. It holds either an admin
// promotion from Firestore (promotions collection) or, when none is active,
// an editorial card for an existing service. It never states a discount on
// its own: offers come only from the promotion document.
//
// No banner artwork is bundled yet (assets/images/banners/ is empty). Pass a
// [trailing] widget, e.g. Image.asset('assets/images/banners/<file>'), once
// one exists.

import 'package:flutter/material.dart';

import '../theme/home_theme.dart';

class HomePromoCard extends StatelessWidget {
  final String? eyebrow;
  final String title;
  final String subtitle;
  final String? ctaLabel;
  final VoidCallback? onTap;
  final Color background;
  final Widget? trailing;

  const HomePromoCard({
    super.key,
    this.eyebrow,
    required this.title,
    this.subtitle = '',
    this.ctaLabel,
    this.onTap,
    this.background = HomeTheme.primaryDeep,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(22);
    return Semantics(
      button: onTap != null,
      label: [title, subtitle, ctaLabel ?? '']
          .where((s) => s.isNotEmpty)
          .join('. '),
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: background,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              // One soft highlight; no busy pattern.
              Positioned(
                right: -40,
                top: -50,
                child: Container(
                  width: 170,
                  height: 170,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.07),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
                child: Row(
                  children: [
                    Expanded(child: _text()),
                    if (trailing != null) ...[
                      const SizedBox(width: 12),
                      trailing!,
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _text() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (eyebrow != null) ...[
            Text(
              eyebrow!.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Inter',
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w800,
              height: 1.2,
              letterSpacing: -0.4,
            ),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ],
          if (ctaLabel != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      ctaLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        color: HomeTheme.primaryDeep,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_forward_rounded,
                      size: 15, color: HomeTheme.primaryDeep),
                ],
              ),
            ),
          ],
        ],
      );
}
