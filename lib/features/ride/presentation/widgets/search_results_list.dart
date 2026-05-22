// features/ride/widgets/search_results_list.dart
//
// ✅ Pure presentational — results, loading state, and query passed in
// ✅ Shows a loading shimmer while debounce fires (isSearching)
// ✅ Empty state with query shown inline

import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../models/place_result.dart';
import 'place_tile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/destination_search_provider.dart';

class SearchResultsList extends StatelessWidget {
  final List<PlaceResult> results;
  final bool isSearching;
  final String query;
  final ValueChanged<PlaceResult> onSelect;

  const SearchResultsList({
    super.key,
    required this.results,
    required this.isSearching,
    required this.query,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (isSearching) return const _SearchingIndicator();

    if (results.isEmpty) return _EmptyResults(query: query);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(label: 'Results'),
        ...results.map((p) => PlaceTile(place: p, onTap: () => onSelect(p))),
      ],
    );
  }
}

class _SearchingIndicator extends StatelessWidget {
  const _SearchingIndicator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.primary,
          ),
        ),
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  final String query;
  const _EmptyResults({required this.query});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          const Icon(Icons.search_off_rounded,
              size: 48, color: AppColors.textTertiary),
          const SizedBox(height: 12),
          Text(
            'No results for "$query"',
            style: AppTextStyles.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}


// ============================================================================
// features/ride/widgets/default_places_list.dart
//
// ✅ Reads recent/popular via their own FutureProviders — isolated rebuilds
// ✅ AsyncValue.when() handles loading / error per section independently
// ✅ onSelect callback delegates up — no navigation logic here
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

