// features/ride/providers/destination_search_provider.dart


import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/place_result.dart';
import '../repositories/place_repository.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class DestinationSearchState {
  const DestinationSearchState({
    this.query = '',
    this.searchResults = const [],
    this.isSearching = false,
    this.selectedPlace,
  });

  final String query;
  final List<PlaceResult> searchResults;
  final bool isSearching;
  final PlaceResult? selectedPlace;

  bool get hasQuery => query.isNotEmpty;
  bool get hasResults => searchResults.isNotEmpty;

  DestinationSearchState copyWith({
    String? query,
    List<PlaceResult>? searchResults,
    bool? isSearching,
    PlaceResult? selectedPlace,
  }) {
    return DestinationSearchState(
      query: query ?? this.query,
      searchResults: searchResults ?? this.searchResults,
      isSearching: isSearching ?? this.isSearching,
      selectedPlace: selectedPlace ?? this.selectedPlace,
    );
  }
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class DestinationSearchNotifier extends Notifier<DestinationSearchState> {
  static const _debounceDuration = Duration(milliseconds: 300);
  Timer? _debounce;

  @override
  DestinationSearchState build() {
    ref.onDispose(() {
      _debounce?.cancel();
    });

    return const DestinationSearchState();
  }

  void onQueryChanged(String query) {
    state = state.copyWith(query: query, isSearching: query.isNotEmpty);

    _debounce?.cancel();

    if (query.isEmpty) {
      state = state.copyWith(searchResults: [], isSearching: false);
      return;
    }

    _debounce = Timer(_debounceDuration, () => _runSearch(query));
  }

  // features/ride/providers/destination_search_provider.dart

Future<void> _runSearch(String query) async {
  print('🔍 Searching: $query');        // ← add
  try {
    final results =
        await ref.read(placeRepositoryProvider).search(query);
    print('✅ Results: ${results.length}'); // ← add
    if (state.query != query) return;
    state = state.copyWith(searchResults: results, isSearching: false);
  } catch (e) {
    print('❌ Search error: $e');        // ← add
    state = state.copyWith(searchResults: [], isSearching: false);
  }
}

  void clearQuery() {
    _debounce?.cancel();
    state = const DestinationSearchState();
  }

  void selectPlace(PlaceResult place) {
    state = state.copyWith(selectedPlace: place);
  }

 
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final destinationSearchProvider =
    NotifierProvider<DestinationSearchNotifier, DestinationSearchState>(
  DestinationSearchNotifier.new,
);

/// Loaded once; does not re-fetch on query changes.
final recentPlacesProvider = FutureProvider.autoDispose<List<PlaceResult>>(
  (ref) => ref.watch(placeRepositoryProvider).getRecentPlaces(),
);

final popularPlacesProvider = FutureProvider.autoDispose<List<PlaceResult>>(
  (ref) => ref.watch(placeRepositoryProvider).getPopularPlaces(),
);