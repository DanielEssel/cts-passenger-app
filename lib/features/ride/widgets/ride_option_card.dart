// lib/features/ride/widgets/ride_option_card.dart

import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../models/ride_option.dart';

class RideOptionCard extends StatelessWidget {
  final RideOption    option;
  final bool          isSelected;
  final VoidCallback? onTap;        // nullable — null = unavailable
  final double        distance;
  final bool          showPerks;
  final int           driverCount;  // real nearby driver count
  final bool          isAvailable;  // false = grey out

  const RideOptionCard({
    super.key,
    required this.option,
    required this.isSelected,
    required this.onTap,
    this.distance    = 8.2,
    this.showPerks   = true,
    this.driverCount = 0,
    this.isAvailable = true,
  });

  double get calculatedPrice {
    const pricePerKm = 2.5;
    return option.basePrice + (pricePerKm * distance);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isAvailable ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve:    Curves.easeOut,
        padding:  const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: !isAvailable
              ? AppColors.surfaceAlt
              : isSelected
                  ? AppColors.primaryDim
                  : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: !isAvailable
                ? AppColors.border
                : isSelected
                    ? AppColors.primary
                    : AppColors.border,
            width: isSelected ? 1.5 : 0.5,
          ),
          boxShadow: isSelected && isAvailable
              ? [
                  BoxShadow(
                    color:      AppColors.primary.withValues(alpha: 0.10),
                    blurRadius: 12,
                    offset:     const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Opacity(
          opacity: isAvailable ? 1.0 : 0.5,
          child: Column(
            children: [
              Row(
                children: [
                  _buildIcon(),
                  const SizedBox(width: 12),
                  Expanded(child: _buildInfo()),
                  _buildPrice(),
                ],
              ),
              if (showPerks && isSelected && isAvailable)
                _buildPerksSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIcon() => AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width:  50,
        height: 50,
        decoration: BoxDecoration(
          color: isSelected && isAvailable
              ? AppColors.primary.withValues(alpha: 0.15)
              : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          option.icon,
          color: isSelected && isAvailable
              ? AppColors.primary
              : AppColors.textSecondary,
          size: 24,
        ),
      );

  Widget _buildInfo() {
    // ETA based on real driver count
    final etaText = !isAvailable
        ? 'No drivers nearby'
        : driverCount == 1
            ? '1 driver nearby'
            : '$driverCount drivers nearby';

    final etaColor = !isAvailable
        ? AppColors.textTertiary
        : driverCount <= 1
            ? AppColors.warning
            : const Color(0xFF10B981);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(option.name,
                style: AppTextStyles.labelLarge
                    .copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            if (option.badge.isNotEmpty && isAvailable)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.primary.withValues(alpha: 0.18)
                      : AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  option.badge,
                  style: AppTextStyles.overline.copyWith(
                    color: isSelected
                        ? AppColors.primary
                        : AppColors.textTertiary,
                    fontSize: 10,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(option.description, style: AppTextStyles.caption),
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
            Text(
              etaText,
              style: AppTextStyles.caption.copyWith(
                color:      etaColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPrice() => Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            'GHS ${calculatedPrice.toStringAsFixed(0)}',
            style: AppTextStyles.amountSmall.copyWith(
              fontSize:   17,
              fontWeight: FontWeight.w800,
              color: isAvailable
                  ? AppColors.textPrimary
                  : AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 2),
          Text(option.duration, style: AppTextStyles.caption),
        ],
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