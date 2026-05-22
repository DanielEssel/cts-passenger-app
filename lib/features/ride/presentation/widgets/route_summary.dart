// features/ride/widgets/route_summary.dart
//
// ✅ Purely presentational — state flows in, callbacks flow out
// ✅ TripStats sub-widget extracted and reusable
// ✅ No ref.watch inside — parent already watched the provider

import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../constants/ride_constants.dart';
import '../../providers/ride_request_provider.dart';

class RouteSummary extends StatelessWidget {
  final RideRequestState state;
  final VoidCallback onDestinationTap;

  const RouteSummary({
    super.key,
    required this.state,
    required this.onDestinationTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        children: [
          _RouteRow(
            dotColor: AppColors.success,
            label: state.origin ?? RideConstants.defaultOrigin,
            trailing: Text(
              'Now',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textTertiary,
              ),
            ),
          ),
          const _RouteDivider(),
          GestureDetector(
            onTap: onDestinationTap,
            behavior: HitTestBehavior.opaque,
            child: _RouteRow(
              dotColor: AppColors.primary,
              label: state.isDestinationSet
                  ? state.destination!
                  : 'Where are you going?',
              labelStyle: AppTextStyles.bodyMedium.copyWith(
                color: state.isDestinationSet
                    ? AppColors.textPrimary
                    : AppColors.textTertiary,
                fontStyle: state.isDestinationSet
                    ? FontStyle.normal
                    : FontStyle.italic,
                fontWeight: state.isDestinationSet
                    ? FontWeight.w500
                    : FontWeight.w400,
              ),
              trailing: _DestinationBadge(isSet: state.isDestinationSet),
            ),
          ),
          if (state.isDestinationSet) TripStats(state: state),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Private sub-widgets
// ---------------------------------------------------------------------------

class _RouteRow extends StatelessWidget {
  final Color dotColor;
  final String label;
  final TextStyle? labelStyle;
  final Widget? trailing;

  const _RouteRow({
    required this.dotColor,
    required this.label,
    this.labelStyle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: labelStyle ??
                AppTextStyles.bodyMedium
                    .copyWith(fontWeight: FontWeight.w500),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _RouteDivider extends StatelessWidget {
  const _RouteDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4.5, top: 4, bottom: 4),
      child: Container(width: 1.5, height: 18, color: AppColors.border),
    );
  }
}

class _DestinationBadge extends StatelessWidget {
  final bool isSet;
  const _DestinationBadge({required this.isSet});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.primaryDim,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        isSet ? 'Change' : 'Search',
        style: AppTextStyles.caption.copyWith(
          color: AppColors.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Public — reusable in other screens (e.g. driver matching summary)
class TripStats extends StatelessWidget {
  final RideRequestState state;
  const TripStats({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final dist =
        state.estimatedDistance?.toStringAsFixed(1) ?? RideConstants.defaultDistanceKm.toStringAsFixed(1);
    final dur = state.estimatedDuration ?? RideConstants.defaultDurationMin;

    return Column(
      children: [
        const SizedBox(height: 12),
        Divider(height: 1, color: AppColors.border),
        const SizedBox(height: 12),
        Row(
          children: [
            _TripStatItem(Icons.straighten_rounded, '$dist km'),
            const SizedBox(width: 18),
            _TripStatItem(Icons.access_time_rounded, '~$dur min'),
            const SizedBox(width: 18),
            const _TripStatItem(Icons.traffic_rounded, 'Moderate'),
          ],
        ),
      ],
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
        Icon(icon, size: 13, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(label, style: AppTextStyles.caption),
      ],
    );
  }
}