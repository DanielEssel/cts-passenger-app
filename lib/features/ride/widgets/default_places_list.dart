import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/destination_search_provider.dart';
import 'package:flutter/material.dart';
import 'package:cts_transport_app/core/constants/app_colors.dart';
import 'package:cts_transport_app/core/constants/app_text_styles.dart';
import 'package:cts_transport_app/features/ride/models/place_result.dart';
import 'package:cts_transport_app/features/ride/widgets/place_tile.dart';

// ============================================================================
// features/ride/widgets/default_places_list.dart
//
// 
// ============================================================================

class DefaultPlacesList extends ConsumerWidget {
  final ValueChanged<PlaceResult> onSelect;

  const DefaultPlacesList({super.key, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recentAsync = ref.watch(recentPlacesProvider);
    final popularAsync = ref.watch(popularPlacesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(label: 'Recent places'),
        recentAsync.when(
          loading: () => const _SectionShimmer(),
          error: (_, __) => const SizedBox.shrink(),
          data: (places) => Column(
            children: places
                .map((p) => PlaceTile(place: p, onTap: () => onSelect(p)))
                .toList(),
          ),
        ),
        _SectionLabel(label: 'Popular destinations'),
        popularAsync.when(
          loading: () => const _SectionShimmer(),
          error: (_, __) => const SizedBox.shrink(),
          data: (places) => Column(
            children: places
                .map((p) => PlaceTile(place: p, onTap: () => onSelect(p)))
                .toList(),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _SectionShimmer extends StatelessWidget {
  const _SectionShimmer();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
      ),
    );
  }
}


// ============================================================================
// Shared section label — used by both lists
// ============================================================================

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        label,
        style: AppTextStyles.caption.copyWith(
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

