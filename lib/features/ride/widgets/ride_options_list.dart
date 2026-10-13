// features/ride/widgets/ride_options_list.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../payment/models/payment_method.dart';
import '../providers/drivers_nearby_provider.dart';
import '../providers/ride_request_provider.dart';
import '../providers/wallet_provider.dart';
import '../services/payment_method_service.dart';
import '../services/ride_options_service.dart';
import '../constants/ride_constants.dart';
import '../../../core/widgets/cts_ui.dart';
import 'ride_option_card.dart';

class RideOptionsList extends ConsumerWidget {
  final RideRequestState state;
  final VoidCallback     onShowPaymentSheet;

  const RideOptionsList({
    super.key,
    required this.state,
    required this.onShowPaymentSheet,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same stream as the map markers. Categories stay selectable either way:
    // the backend's search decides whether a driver is found.
    final drivers = ref.watch(driversNearbyProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          const CtsSectionHeader('Choose a ride',
              caption: 'Prices are estimates'),

          // ── Ride options ──
          ...RideOptionsService.availableRides.map((ride) {
            final availability =
                rideAvailabilityFrom(drivers, ride.serviceType.name);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: RideOptionCard(
                option:       ride,
                isSelected:   state.selectedRide?.serviceType ==
                    ride.serviceType,
                availability: availability.status,
                driverCount:  availability.count,
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.read(rideRequestProvider.notifier).selectRide(ride);
                },
                distance: state.estimatedDistance ??
                    RideConstants.defaultDistanceKm,
                durationMin: state.estimatedDuration ?? 0,
              ),
            );
          }),

          // ── How availability works ──
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded,
                    color: AppColors.textTertiary, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Prices are estimates. We search for a driver after '
                    'you request, and tell you if none is available.',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 4),

          // ── Payment selector ──
          PaymentSelector(
            state: state,
            onTap: onShowPaymentSheet,
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PAYMENT SELECTOR
// ─────────────────────────────────────────────────────────────────────────────

class PaymentSelector extends ConsumerWidget {
  final RideRequestState state;
  final VoidCallback     onTap;

  const PaymentSelector({
    super.key,
    required this.state,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedMethod = PaymentMethod.fromType(state.paymentMethod);
    final walletBalance  = ref.watch(walletBalanceProvider).maybeWhen(
      data:   (b) => b,
      orElse: () => 0.0,
    );

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color:        AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            _PaymentIcon(method: selectedMethod),
            const SizedBox(width: 12),
            Expanded(
              child: _PaymentDetails(
                method:        selectedMethod,
                walletBalance: walletBalance,
              ),
            ),
            const Icon(Icons.keyboard_arrow_down_rounded,
                color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _PaymentIcon extends StatelessWidget {
  final PaymentMethod method;
  const _PaymentIcon({required this.method});

  @override
  Widget build(BuildContext context) => Container(
        width:  42,
        height: 42,
        decoration: BoxDecoration(
          color:        AppColors.primaryDim,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(method.icon, color: AppColors.primary, size: 18),
      );
}

class _PaymentDetails extends StatelessWidget {
  final PaymentMethod method;
  final double        walletBalance;

  const _PaymentDetails({
    required this.method,
    required this.walletBalance,
  });

  @override
  Widget build(BuildContext context) {
    final isWallet = method.type == PaymentType.wallet;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(method.name,
            style: AppTextStyles.labelLarge
                .copyWith(fontWeight: FontWeight.w600)),
        Text(
          isWallet
              ? 'Balance: ${PaymentMethodService.getFormattedBalance(walletBalance)}'
              : method.subtitle,
          style: AppTextStyles.caption.copyWith(
            color: isWallet
                ? AppColors.success
                : AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}