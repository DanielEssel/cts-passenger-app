// features/ride/widgets/route_summary.dart
//
// ✅ Purely presentational — state flows in, callbacks flow out
// ✅ TripStats sub-widget extracted and reusable
// ✅ No ref.watch inside — parent already watched the provider

import 'package:flutter/material.dart';
import '../../../core/theme/cts_theme.dart';
import '../constants/ride_constants.dart';
import '../providers/ride_request_provider.dart';

class RouteSummary extends StatelessWidget {
  final RideRequestState state;
  final VoidCallback onDestinationTap;

  /// True while GPS is being read for the pickup.
  final bool locatingPickup;

  /// Set when the pickup couldn't be found; tapping the row retries.
  final VoidCallback? onRetryPickup;

  const RouteSummary({
    super.key,
    required this.state,
    required this.onDestinationTap,
    this.locatingPickup = false,
    this.onRetryPickup,
  });

  @override
  Widget build(BuildContext context) {
    final hasDest = state.isDestinationSet;
    final hasPickup = state.pickupLocation != null;
    final pickupLabel = hasPickup
        ? (state.origin ?? RideConstants.defaultOrigin)
        : locatingPickup || onRetryPickup == null
            ? 'Finding your location…'
            : 'Location unavailable. Tap to try again';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: CtsTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          children: [
            Semantics(
              label: 'Pickup, $pickupLabel',
              button: !hasPickup && onRetryPickup != null,
              excludeSemantics: true,
              onTap: hasPickup ? null : onRetryPickup,
              child: InkWell(
                onTap: hasPickup ? null : onRetryPickup,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(18)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: _RouteRow(
                    dot: const _Dot(filled: false),
                    caption: 'Pickup',
                    label: pickupLabel,
                    muted: !hasPickup,
                    trailing: hasPickup
                        ? const Text('Now',
                            style: TextStyle(
                              color: CtsTheme.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ))
                        : onRetryPickup != null
                            ? const Text('Retry',
                                style: TextStyle(
                                  color: CtsTheme.primaryDeep,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ))
                            : const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: CtsTheme.primary),
                              ),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 38),
              child: Divider(height: 1, color: CtsTheme.border),
            ),
            Semantics(
              button: true,
              label: hasDest
                  ? 'Destination, ${state.destination}. Change'
                  : 'Search destination',
              excludeSemantics: true,
              onTap: onDestinationTap,
              child: InkWell(
                onTap: onDestinationTap,
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(18)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                  child: _RouteRow(
                    dot: const _Dot(filled: true),
                    caption: 'Destination',
                    label:
                        hasDest ? state.destination! : 'Where are you going?',
                    muted: !hasDest,
                    trailing: Text(hasDest ? 'Change' : 'Search',
                        style: const TextStyle(
                          color: CtsTheme.primaryDeep,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        )),
                  ),
                ),
              ),
            ),
            if (hasDest) TripStats(state: state),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Private sub-widgets
// ---------------------------------------------------------------------------

class _Dot extends StatelessWidget {
  final bool filled;
  const _Dot({required this.filled});

  @override
  Widget build(BuildContext context) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: filled ? CtsTheme.primary : CtsTheme.surface,
          shape: BoxShape.circle,
          border: Border.all(color: CtsTheme.primary, width: 2.5),
        ),
      );
}

class _RouteRow extends StatelessWidget {
  final Widget dot;
  final String caption;
  final String label;
  final bool muted;
  final Widget? trailing;

  const _RouteRow({
    required this.dot,
    required this.caption,
    required this.label,
    this.muted = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 12, child: dot),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(caption,
                  style: const TextStyle(
                    color: CtsTheme.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  )),
              const SizedBox(height: 1),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Inter',
                  color: muted ? CtsTheme.textTertiary : CtsTheme.textPrimary,
                  fontSize: 14.5,
                  fontWeight: muted ? FontWeight.w500 : FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing!,
        ],
      ],
    );
  }
}

/// Public — reusable in other screens (e.g. driver matching summary).
/// Shows only the route distance and duration the app actually has.
class TripStats extends StatelessWidget {
  final RideRequestState state;
  const TripStats({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final dist = state.estimatedDistance?.toStringAsFixed(1) ??
        RideConstants.defaultDistanceKm.toStringAsFixed(1);
    final dur = state.estimatedDuration ?? RideConstants.defaultDurationMin;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: CtsTheme.border)),
      ),
      child: Row(
        children: [
          _TripStatItem(Icons.straighten_rounded, '$dist km'),
          const SizedBox(width: 18),
          _TripStatItem(Icons.access_time_rounded, '~$dur min'),
        ],
      ),
    );
  }
}

class _TripStatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TripStatItem(this.icon, this.label);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: CtsTheme.textSecondary),
        const SizedBox(width: 5),
        Text(label,
            style: const TextStyle(
              color: CtsTheme.textPrimary,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            )),
      ],
    );
  }
}
