
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../constants/ride_constants.dart';
import '../providers/drivers_nearby_provider.dart';
import '../providers/ride_request_provider.dart';
import 'map_placeholder.dart';

class MapSection extends ConsumerWidget {
  final RideRequestState state;
  final VoidCallback onMapTap;

  const MapSection({
    super.key,
    required this.state,
    required this.onMapTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        MapPlaceholder(
          height: MediaQuery.of(context).size.height,
          showRoute: state.isDestinationSet,
          origin: state.pickupLocation != null
              ? LatLng(
                  state.pickupLocation!.latitude,
                  state.pickupLocation!.longitude,
                )
              : null,
          destination: state.dropoffLocation != null
              ? LatLng(
                  state.dropoffLocation!.latitude,
                  state.dropoffLocation!.longitude,
                )
              : null,
          onMapTap: onMapTap,
        ),
        Positioned(
          top: MediaQuery.of(context).padding.top + 10,
          left: 16,
          child: const _BackButton(),
        ),
        Positioned(
          bottom: 12,
          right: 12,
          child: _DriversNearbyChip(),
        ),
        if (state.isDestinationSet)
          Positioned(
            bottom: 12,
            left: 12,
            child: _RouteStatsChip(state: state),
          ),
      ],
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        ),
        child: const Icon(
          Icons.arrow_back_ios_new_rounded,
          color: Colors.white,
          size: 16,
        ),
      ),
    );
  }
}

class _DriversNearbyChip extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final driversAsync = ref.watch(driversNearbyProvider);

    return driversAsync.when(
      loading: () => const _MapChip(
        dotColor: AppColors.textTertiary,
        label: 'Finding drivers\u2026',
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (drivers) {
        if (drivers.isEmpty) {
          return const _MapChip(
            dotColor: AppColors.error,
            label: 'No drivers nearby',
          );
        }
        final count = drivers.length;
        return _MapChip(
          dotColor: AppColors.success,
          label: '$count driver${count == 1 ? '' : 's'} nearby',
        );
      },
    );
  }
}

class _RouteStatsChip extends StatelessWidget {
  final RideRequestState state;
  const _RouteStatsChip({required this.state});

  @override
  Widget build(BuildContext context) {
    final dist = state.estimatedDistance?.toStringAsFixed(1) ??
        RideConstants.defaultDistanceKm.toStringAsFixed(1);
    final dur = state.estimatedDuration ?? RideConstants.defaultDurationMin;
    return _MapChip(
      dotColor: AppColors.primary,
      label: '$dist km · ~$dur min',
    );
  }
}

class _MapChip extends StatelessWidget {
  final Color dotColor;
  final String label;

  const _MapChip({required this.dotColor, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration:
                BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}