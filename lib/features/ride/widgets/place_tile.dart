// features/ride/widgets/place_tile.dart
//
// ✅ Promoted from private _PlaceTile to a public widget
// ✅ Takes typed PlaceResult instead of raw Map fields
// ✅ `showHistory` inferred from PlaceResult.isRecent — no caller must track this
// ✅ Identical visual design to original

import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../models/place_result.dart';

class PlaceTile extends StatelessWidget {
  final PlaceResult place;
  final VoidCallback onTap;

  const PlaceTile({
    super.key,
    required this.place,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: AppColors.borderLight, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            _PlaceIcon(icon: place.icon),
            const SizedBox(width: 12),
            Expanded(child: _PlaceLabels(place: place)),
            _TrailingIcon(isRecent: place.isRecent),
          ],
        ),
      ),
    );
  }
}

class _PlaceIcon extends StatelessWidget {
  final IconData icon;
  const _PlaceIcon({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: AppColors.primary, size: 18),
    );
  }
}

class _PlaceLabels extends StatelessWidget {
  final PlaceResult place;
  const _PlaceLabels({required this.place});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(place.name, style: AppTextStyles.labelLarge),
        const SizedBox(height: 2),
        Text(
          place.address,
          style: AppTextStyles.caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _TrailingIcon extends StatelessWidget {
  final bool isRecent;
  const _TrailingIcon({required this.isRecent});

  @override
  Widget build(BuildContext context) {
    return Icon(
      isRecent ? Icons.history_rounded : Icons.north_west_rounded,
      size: isRecent ? 16 : 14,
      color: AppColors.textTertiary,
    );
  }
}