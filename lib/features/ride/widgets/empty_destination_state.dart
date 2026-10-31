import 'package:flutter/material.dart';

import '../../../core/theme/cts_theme.dart';
import '../../../core/widgets/cts_ui.dart';
import '../../home/widgets/service_tile.dart';
import '../models/service_type.dart';

// ============================================================================
// features/ride/widgets/empty_destination_state.dart
// ✅ Fully extracted, zero dependencies on Riverpod
// ✅ Search action delegated via callback
// ============================================================================

/// Shown in the booking sheet until a destination is set: what the ride
/// categories are, and one clear action to search.
class EmptyDestinationState extends StatelessWidget {
  final VoidCallback onSearchTap;

  const EmptyDestinationState({super.key, required this.onSearchTap});

  static const _rides = [
    ServiceType.taxi,
    ServiceType.okada,
    ServiceType.pragyia,
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CtsSectionHeader('Ride options',
              caption: 'Set a destination to see prices'),
          Row(
            children: [
              for (var i = 0; i < _rides.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _RidePreview(service: _rides[i])),
              ],
            ],
          ),
          const SizedBox(height: 16),
          CtsPrimaryButton(
            label: 'Search destination',
            icon: Icons.search_rounded,
            onPressed: onSearchTap,
          ),
        ],
      ),
    );
  }
}

class _RidePreview extends StatelessWidget {
  final ServiceType service;
  const _RidePreview({required this.service});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          decoration: BoxDecoration(
            color: CtsTheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: CtsTheme.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ServiceImage(service: service, aspectRatio: 1.35),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Text(service.displayName,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      color: CtsTheme.textPrimary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    )),
              ),
            ],
          ),
        ),
      );
}
