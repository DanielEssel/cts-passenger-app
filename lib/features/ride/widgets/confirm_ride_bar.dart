// features/ride/widgets/confirm_ride_bar.dart

import 'package:flutter/material.dart';
import '../../../core/theme/cts_theme.dart';
import '../../../core/widgets/cts_ui.dart';
import '../providers/ride_request_provider.dart';
import '../domain/ride_fare_estimate.dart';

class ConfirmRideBar extends StatelessWidget {
  final RideRequestState state;
  final Animation<double> animation;
  final VoidCallback onConfirm;

  const ConfirmRideBar({
    super.key,
    required this.state,
    required this.animation,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final ride = state.selectedRide;
    return ScaleTransition(
      scale: animation,
      child: Container(
        padding: EdgeInsets.only(
          left: ctsGutter,
          right: ctsGutter,
          top: 12,
          bottom: MediaQuery.paddingOf(context).bottom + 12,
        ),
        decoration: const BoxDecoration(
          color: CtsTheme.surface,
          border: Border(top: BorderSide(color: CtsTheme.border)),
        ),
        // While a booking is in flight the button shows a spinner and
        // ignores taps (the screen also guards on state.isLoading). With no
        // vehicle chosen yet it stays visible but disabled and says why.
        child: ride == null
            ? const CtsPrimaryButton(
                label: 'Choose a ride to continue',
                onPressed: null,
              )
            : CtsPrimaryButton(
                label: 'Confirm ${ride.name}',
                trailingText: formatGhs(state.calculatedFare),
                loading: state.isLoading,
                onPressed: onConfirm,
              ),
      ),
    );
  }
}
