import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';


// ============================================================================
// features/ride/widgets/empty_destination_state.dart
// ✅ Fully extracted, zero dependencies on Riverpod
// ✅ Search action delegated via callback
// ============================================================================
 
class EmptyDestinationState extends StatelessWidget {
  final VoidCallback onSearchTap;
 
  const EmptyDestinationState({super.key, required this.onSearchTap});
 
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _SearchIcon(),
            const SizedBox(height: 20),
            Text(
              'Where to?',
              style: AppTextStyles.heading2
                  .copyWith(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              'Search for a destination to see\navailable rides nearby',
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            _SearchButton(onTap: onSearchTap),
          ],
        ),
      ),
    );
  }
}
 
class _SearchIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: AppColors.primaryDim,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: const Icon(Icons.location_searching_rounded,
          color: AppColors.primary, size: 34),
    );
  }
}
 
class _SearchButton extends StatelessWidget {
  final VoidCallback onTap;
  const _SearchButton({required this.onTap});
 
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 15),
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.3),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_rounded,
                color: AppColors.background, size: 18),
            const SizedBox(width: 8),
            Text(
              'Search destination',
              style:
                  AppTextStyles.button.copyWith(color: AppColors.background),
            ),
          ],
        ),
      ),
    );
  }
}
 
