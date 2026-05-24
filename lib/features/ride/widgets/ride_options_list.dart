// lib/features/ride/widgets/ride_options_list.dart

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
import '../models/ride_option.dart' hide RideOptionsService;
import '../services/ride_options_service.dart';
import '../constants/ride_constants.dart';
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
    // Watch all nearby drivers once
    final nearbyAsync = ref.watch(driversNearbyProvider);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'CHOOSE RIDE',
                style: AppTextStyles.overline.copyWith(
                  color:         AppColors.textTertiary,
                  letterSpacing: 1.1,
                  fontWeight:    FontWeight.w700,
                ),
              ),
              nearbyAsync.when(
                data: (drivers) {
                  final total = drivers
                      .where((d) =>
                          d.serviceType == 'taxi' ||
                          d.serviceType == 'okada')
                      .length;
                  return Text(
                    '$total driver${total == 1 ? '' : 's'} nearby',
                    style: AppTextStyles.caption.copyWith(
                      color:      total > 0
                          ? AppColors.success
                          : AppColors.textTertiary,
                      fontWeight: FontWeight.w600,
                    ),
                  );
                },
                loading: () => const SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                error: (_, __) => const SizedBox.shrink(),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── Ride options ──
          ...RideOptionsService.availableRides.map((ride) {
            final serviceKey = ride.serviceType.name; // 'taxi' or 'okada'

            final driverCount = nearbyAsync.maybeWhen(
              data: (drivers) => drivers
                  .where((d) => d.serviceType == serviceKey)
                  .length,
              orElse: () => 0,
            );

            final isAvailable = driverCount > 0;

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: RideOptionCard(
                option:      ride,
                isSelected:  state.selectedRide?.serviceType ==
                    ride.serviceType,
                isAvailable: isAvailable,
                driverCount: driverCount,
                onTap: isAvailable
                    ? () {
                        HapticFeedback.selectionClick();
                        ref
                            .read(rideRequestProvider.notifier)
                            .selectRide(ride);
                      }
                    : null,
                distance: state.estimatedDistance ??
                    RideConstants.defaultDistanceKm,
              ),
            );
          }),

          // ── No drivers banner ──
          nearbyAsync.when(
            data: (drivers) {
              final hasAny = drivers.any((d) =>
                  d.serviceType == 'taxi' || d.serviceType == 'okada');
              if (hasAny) return const SizedBox.shrink();
              return Container(
                margin:  const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color:        AppColors.warningLight,
                  borderRadius: BorderRadius.circular(12),
                  border:       Border.all(
                      color: AppColors.warning.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        color: AppColors.warning, size: 16),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'No drivers available in your area right now. '
                        'Please try again in a few minutes.',
                        style: AppTextStyles.caption.copyWith(
                            color: AppColors.warning),
                      ),
                    ),
                  ],
                ),
              );
            },
            loading: () => const SizedBox.shrink(),
            error:   (_, __) => const SizedBox.shrink(),
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
      data:    (b) => b,
      orElse:  () => 0.0,
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