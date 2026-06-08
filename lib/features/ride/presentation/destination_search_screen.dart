// features/ride/screens/destination_search_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../models/place_result.dart';
import '../providers/destination_search_provider.dart';
import '../widgets/search_header.dart';
import '../widgets/search_results_list.dart';

class DestinationSearchScreen extends ConsumerStatefulWidget {
  final String origin;

  const DestinationSearchScreen({super.key, required this.origin});

  @override
  ConsumerState<DestinationSearchScreen> createState() =>
      _DestinationSearchScreenState();
}

class _DestinationSearchScreenState
    extends ConsumerState<DestinationSearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();

    debugPrint('🚀 DestinationSearchScreen OPENED');

    _controller.addListener(() {
      ref
          .read(destinationSearchProvider.notifier)
          .onQueryChanged(_controller.text);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // Clear stale selection from a previous open, so the listener doesn't
      // immediately pop on an old place (was causing auto-close + crash).
      ref.read(destinationSearchProvider.notifier).clearQuery();

      _focusNode.requestFocus();

      ref.listenManual<DestinationSearchState>(
        destinationSearchProvider,
        (prev, next) {
          // Only pop when the selection CHANGES to a real place during this session.
          if (next.selectedPlace != null &&
              next.selectedPlace != prev?.selectedPlace &&
              mounted) {
            Navigator.pop(context, next.selectedPlace!.toNavigationResult());
          }
        },
      );
    });
  }

  @override
  void dispose() {
    // ✅ Reset provider state so it's fresh next time the screen opens
    ref.invalidate(destinationSearchProvider);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(destinationSearchProvider);

    debugPrint(
      'Destination screen build: '
      'selectedPlace=${state.selectedPlace?.name}',
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          SearchHeader(
            origin: widget.origin,
            controller: _controller,
            focusNode: _focusNode,
            hasQuery: state.hasQuery,
            onClear: () {
              _controller.clear();
              ref.read(destinationSearchProvider.notifier).clearQuery();
              _focusNode.requestFocus();
            },
            onBack: () => Navigator.pop(context),
          ),
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: state.hasQuery
                  ? SearchResultsList(
                      results: state.searchResults,
                      isSearching: state.isSearching,
                      query: state.query,
                      onSelect: _onPlaceSelected,
                    )
                  : DefaultPlacesList(onSelect: _onPlaceSelected),
            ),
          ),
        ],
      ),
    );
  }

  void _onPlaceSelected(PlaceResult place) {
    ref.read(destinationSearchProvider.notifier).selectPlace(place);
  }
}
