// lib/features/ride/widgets/ride_option_card.dart

import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/theme/cts_theme.dart';
import '../../home/widgets/service_tile.dart';
import '../domain/ride_availability.dart';
import '../domain/ride_fare_estimate.dart';
import '../models/ride_option.dart';


class RideOptionCard extends StatelessWidget {
  final RideOption    option;
  final bool          isSelected;
  final VoidCallback? onTap;
  final double        distance;     // route distance in km
  final int           durationMin;  // route duration in minutes
  final bool          showPerks;
  // Shown next to the category, and fades it when no driver is nearby. It
  // never blocks selection: the backend decides whether a driver is found.
  final RideAvailability availability;
  final int              driverCount;  // nearby drivers of this type

  const RideOptionCard({
    super.key,
    required this.option,
    required this.isSelected,
    required this.onTap,
    this.distance     = 8.2,
    this.durationMin  = 0,
    this.showPerks    = true,
    this.availability = RideAvailability.notChecked,
    this.driverCount  = 0,
  });

  bool get _isFaded => availability == RideAvailability.unavailable;

  /// Same estimate the confirm button shows for this category.
  double get calculatedPrice => estimateRideFare(
        serviceType: option.serviceType.name,
        distanceKm: distance,
        durationMin: durationMin,
      );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button:   true,
      selected: isSelected,
      inMutuallyExclusiveGroup: true,
      label: '${option.name}, ${formatGhs(calculatedPrice)} estimate, '
          '${_availabilityText()}',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve:    Curves.easeOut,
        padding:  const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isSelected ? CtsTheme.primaryTint : CtsTheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected ? CtsTheme.primary : CtsTheme.border,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity:  _isFaded ? 0.5 : 1.0,
          child: Column(
            children: [
              Row(
                children: [
                  _buildImage(),
                  const SizedBox(width: 12),
                  Expanded(child: _buildInfo()),
                  _buildPrice(),
                ],
              ),
              if (showPerks && isSelected) _buildPerksSection(),
            ],
          ),
        ),
      ),
      ),
    );
  }

  // The vehicle photo for this category (taxi, okada, pragyia).
  Widget _buildImage() => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 72,
          child: ServiceImage(service: option.serviceType, aspectRatio: 1.2),
        ),
      );

  String _availabilityText() => switch (availability) {
        RideAvailability.available => driverCount == 1
            ? '1 driver nearby'
            : '$driverCount drivers nearby',
        _ => availability.label,
      };

  Widget _buildInfo() {
    final etaText = _availabilityText();
    final etaColor = switch (availability) {
      RideAvailability.available => CtsTheme.primaryDeep,
      RideAvailability.unavailable ||
      RideAvailability.checkFailed => AppColors.warning,
      RideAvailability.notChecked ||
      RideAvailability.checking => AppColors.textTertiary,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Badge on its own line so long names (e.g. "CTSTransport Taxi")
        // keep the full width.
        if (option.badge.isNotEmpty)
          Text(
            option.badge.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.overline.copyWith(
              color: isSelected ? CtsTheme.primaryDeep : CtsTheme.textSecondary,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        Text(option.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.labelLarge
                .copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(option.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.caption),
        const SizedBox(height: 4),
        Row(
          children: [
            Container(
              width: 6, height: 6,
              decoration: BoxDecoration(
                color:  etaColor,
                shape:  BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                etaText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.caption.copyWith(
                  color:      etaColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // Capped so the name and availability always keep room on narrow phones.
  Widget _buildPrice() => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 110),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                formatGhs(calculatedPrice),
                style: AppTextStyles.amountSmall.copyWith(
                  fontSize:   17,
                  fontWeight: FontWeight.w800,
                  color:      AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text('Estimate · ${option.duration}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.caption),
          ],
        ),
      );

  Widget _buildPerksSection() => AnimatedCrossFade(
        firstChild:  const SizedBox.shrink(),
        secondChild: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            children: [
              Divider(
                  height: 1,
                  color: AppColors.primary.withValues(alpha: 0.15)),
              const SizedBox(height: 10),
              Wrap(
                spacing:    8,
                runSpacing: 6,
                children: option.perks
                    .map((perk) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.primary
                                .withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(perk,
                              style: AppTextStyles.overline.copyWith(
                                color:      AppColors.primary,
                                fontWeight: FontWeight.w700,
                                fontSize:   11,
                              )),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
        crossFadeState: isSelected
            ? CrossFadeState.showSecond
            : CrossFadeState.showFirst,
        duration: const Duration(milliseconds: 220),
      );
}