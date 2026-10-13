// lib/features/home/widgets/service_tile.dart
//
// Image-led service tiles for the passenger home screen.
//
// The photos in assets/images/services/ are 1024×1024 studio shots on a light
// grey background. Tiles crop them with BoxFit.cover inside a fixed aspect
// ratio (no layout shift while loading), decode them at roughly the tile's
// physical width instead of the full 1024 px, and fall back to the service
// icon if an asset fails to load.

import 'package:flutter/material.dart';

import '../../ride/models/service_type.dart';
import '../theme/home_theme.dart';

/// The bundled photo for each service.
String serviceImageAsset(ServiceType s) => switch (s) {
      ServiceType.taxi => 'assets/images/services/taxi.jpeg',
      ServiceType.okada => 'assets/images/services/okada.jpeg',
      ServiceType.pragyia => 'assets/images/services/pragya.jpeg',
      ServiceType.delivery => 'assets/images/services/delivery.jpeg',
      ServiceType.gas => 'assets/images/services/gas.jpeg',
    };

/// One short line under each service name.
String serviceTagline(ServiceType s) => switch (s) {
      ServiceType.taxi => 'Comfortable rides',
      ServiceType.okada => 'Beat the traffic',
      ServiceType.pragyia => 'Short trips',
      ServiceType.delivery => 'Send a package',
      ServiceType.gas => 'Refill at home',
    };

// Matches the studio background of the photos, so the placeholder and the
// loaded image look continuous.
const Color _photoBackground = Color(0xFFF0F0EF);

// Decode widths are bucketed so tiles of similar size share one cache entry.
const List<int> _decodeBuckets = [256, 384, 512, 768, 1024];

int _decodeWidthFor(double logicalWidth, double dpr) {
  final needed = (logicalWidth * dpr).ceil();
  return _decodeBuckets.firstWhere((b) => b >= needed,
      orElse: () => _decodeBuckets.last);
}

/// A service photo cropped to [aspectRatio], with placeholder and fallback.
class ServiceImage extends StatelessWidget {
  final ServiceType service;
  final double aspectRatio;

  const ServiceImage({
    super.key,
    required this.service,
    required this.aspectRatio,
  });

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: LayoutBuilder(
        builder: (_, c) => DecoratedBox(
          decoration: const BoxDecoration(color: _photoBackground),
          child: Image(
            image: ResizeImage(
              AssetImage(serviceImageAsset(service)),
              width: _decodeWidthFor(c.maxWidth, dpr),
              policy: ResizeImagePolicy.fit,
            ),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            excludeFromSemantics: true,
            frameBuilder: (_, child, frame, wasSyncLoaded) {
              if (wasSyncLoaded) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: child,
              );
            },
            errorBuilder: (_, __, ___) => Center(
              child:
                  Icon(service.icon, size: 32, color: HomeTheme.textTertiary),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tappable service card: photo on top, name and tagline below.
///
/// [large] tiles use a wider crop and a bigger title; both sizes keep a
/// single line of text so tiles in a row always share one height.
class ServiceTile extends StatelessWidget {
  final ServiceType service;
  final VoidCallback onTap;
  final bool large;

  const ServiceTile({
    super.key,
    required this.service,
    required this.onTap,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(large ? 20 : 16);
    return Semantics(
      button: true,
      label: '${service.displayName}, ${serviceTagline(service)}',
      excludeSemantics: true,
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: HomeTheme.cardShadow,
        ),
        child: Material(
          color: HomeTheme.surface,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1.35 keeps the full okada rider in frame; the small tiles
                // are closer to square.
                ServiceImage(
                    service: service, aspectRatio: large ? 1.35 : 1.12),
                Padding(
                  padding: large
                      ? const EdgeInsets.fromLTRB(12, 9, 10, 11)
                      : const EdgeInsets.fromLTRB(10, 7, 8, 9),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              service.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                color: HomeTheme.textPrimary,
                                fontSize: large ? 15.5 : 13.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              serviceTagline(service),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: HomeTheme.textSecondary,
                                fontSize: large ? 12 : 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (large)
                        Container(
                          width: 28,
                          height: 28,
                          margin: const EdgeInsets.only(left: 6),
                          decoration: BoxDecoration(
                            color: HomeTheme.primary.withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.arrow_forward_rounded,
                              size: 16, color: HomeTheme.primary),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The five services: the two most-used rides as large tiles, then the rest
/// in a row of three.
class HomeServicesSection extends StatelessWidget {
  final ValueChanged<ServiceType> onSelect;

  const HomeServicesSection({super.key, required this.onSelect});

  static const _featured = [ServiceType.taxi, ServiceType.okada];
  static const _more = [
    ServiceType.pragyia,
    ServiceType.delivery,
    ServiceType.gas,
  ];

  @override
  Widget build(BuildContext context) {
    Widget row(List<ServiceType> items, {required bool large}) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) SizedBox(width: large ? 12 : 10),
              Expanded(
                child: ServiceTile(
                  service: items[i],
                  large: large,
                  onTap: () => onSelect(items[i]),
                ),
              ),
            ],
          ],
        );

    return Column(
      children: [
        row(_featured, large: true),
        const SizedBox(height: 12),
        row(_more, large: false),
      ],
    );
  }
}
