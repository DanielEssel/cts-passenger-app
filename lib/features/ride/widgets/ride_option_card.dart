import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../models/ride_option.dart'; // ← only this needed



class RideOptionCard extends StatelessWidget {
  final RideOption option;
  final bool isSelected;
  final VoidCallback onTap;
  final double distance;
  final bool showPerks;

  const RideOptionCard({
    super.key,
    required this.option,
    required this.isSelected,
    required this.onTap,
    this.distance = 8.2,
    this.showPerks = true,
  });

  double get calculatedPrice {
    const pricePerKm = 2.5;
    return option.basePrice + (pricePerKm * distance);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primaryDim : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: isSelected ? 1.5 : 0.5,
          ),
          boxShadow: isSelected
              ? [BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                )]
              : null,
        ),
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
            if (showPerks && isSelected) _buildPerksSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildIcon() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: isSelected
            ? AppColors.primary.withValues(alpha: 0.15)
            : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        option.icon,
        color: isSelected ? AppColors.primary : AppColors.textSecondary,
        size: 24,
      ),
    );
  }

  Widget _buildInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              option.name,
              style: AppTextStyles.labelLarge.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            if (option.badge.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.primary.withValues(alpha: 0.18)
                      : AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  option.badge,
                  style: AppTextStyles.overline.copyWith(
                    color: isSelected ? AppColors.primary : AppColors.textTertiary,
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
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: option.etaColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '${option.eta} away',
              style: AppTextStyles.caption.copyWith(
                color: option.etaColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPrice() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          'GHS ${calculatedPrice.toStringAsFixed(0)}',
          style: AppTextStyles.amountSmall.copyWith(
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(option.duration, style: AppTextStyles.caption),
      ],
    );
  }

  Widget _buildPerksSection() {
    return AnimatedCrossFade(
      firstChild: const SizedBox.shrink(),
      secondChild: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          children: [
            Divider(height: 1, color: AppColors.primary.withValues(alpha: 0.15)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: option.perks.map((perk) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  perk,
                  style: AppTextStyles.overline.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              )).toList(),
            ),
          ],
        ),
      ),
      crossFadeState: isSelected ? CrossFadeState.showSecond : CrossFadeState.showFirst,
      duration: const Duration(milliseconds: 220),
    );
  }
}