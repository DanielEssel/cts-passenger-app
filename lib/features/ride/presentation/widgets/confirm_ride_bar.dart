// features/ride/widgets/confirm_ride_bar.dart


import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../providers/ride_request_provider.dart';

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
    if (state.selectedRide == null) return const SizedBox.shrink();

    return ScaleTransition(
      scale: animation,
      child: Container(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).padding.bottom + 16,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(
            top: BorderSide(color: AppColors.border, width: 0.5),
          ),
        ),
        child: state.isLoading
            ? const _LoadingIndicator()
            : _ConfirmButton(state: state, onConfirm: onConfirm),
      ),
    );
  }
}

class _LoadingIndicator extends StatelessWidget {
  const _LoadingIndicator();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

class _ConfirmButton extends StatelessWidget {
  final RideRequestState state;
  final VoidCallback onConfirm;

  const _ConfirmButton({required this.state, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onConfirm,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Confirm ${state.selectedRide!.name}',
              style: AppTextStyles.button.copyWith(
                color: AppColors.background,
                fontWeight: FontWeight.w700,
              ),
            ),
            _Dot(),
            Text(
              'GHS ${state.calculatedFare.toStringAsFixed(0)}',
              style: AppTextStyles.button.copyWith(
                color: AppColors.background,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward_rounded,
                color: AppColors.background, size: 18),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      width: 4,
      height: 4,
      decoration: const BoxDecoration(
        color: AppColors.background,
        shape: BoxShape.circle,
      ),
    );
  }
}
