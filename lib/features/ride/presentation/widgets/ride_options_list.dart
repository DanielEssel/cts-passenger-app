// lib/features/ride/widgets/ride_options_list.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../payment/models/payment_method.dart';
import '../../models/ride_option.dart';
import '../../providers/ride_request_provider.dart';
import '../../providers/wallet_provider.dart';
import '../../services/payment_method_service.dart' ;
import '../../services/ride_options_service.dart';
import '../../constants/ride_constants.dart';
import 'ride_option_card.dart';

// ─────────────────────────────────────────────────────────────────────────────
// RIDE OPTIONS LIST
// ─────────────────────────────────────────────────────────────────────────────

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
    // ── Build live provider params from current state ──
    final pickup = state.pickupLocation;
    final distanceKm = state.estimatedDistance ?? RideConstants.defaultDistanceKm;

    // Only stream live data when we have a pickup location
    final useLive = pickup != null;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CHOOSE RIDE',
            style: AppTextStyles.overline.copyWith(
              color:       AppColors.textTertiary,
              letterSpacing: 1.1,
              fontWeight:  FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),

          // ── Live options (real driver counts + ETA) ──
          if (useLive)
            _LiveRideOptions(
              state:      state,
              pickup:     pickup,
              distanceKm: distanceKm,
              ref:        ref,
            )
          else
            _StaticRideOptions(
              state:      state,
              distanceKm: distanceKm,
              ref:        ref,
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
// LIVE OPTIONS — streams from Firestore
// ─────────────────────────────────────────────────────────────────────────────

class _LiveRideOptions extends ConsumerWidget {
  final RideRequestState state;
  final GeoPoint         pickup;
  final double           distanceKm;
  final WidgetRef        ref;

  const _LiveRideOptions({
    required this.state,
    required this.pickup,
    required this.distanceKm,
    required this.ref,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final params = RideOptionsParams(
      pickupLocation: pickup,
      distanceKm:     distanceKm,
    );

    final liveAsync = ref.watch(liveRideOptionsProvider(params));

    return liveAsync.when(
      loading: () => _RideOptionsSkeleton(),
      error:   (_, __) => _StaticRideOptions(
        state:      state,
        distanceKm: distanceKm,
        ref:        ref,
      ),
      data: (liveOptions) => Column(
        children: liveOptions.map((live) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: RideOptionCard(
            option:     live.option,
            isSelected: state.selectedRide?.serviceType == live.option.serviceType,
            onTap: () {
              HapticFeedback.selectionClick();
              ref.read(rideRequestProvider.notifier).selectRide(live.option);
            },
            distance:     distanceKm,
            // Pass live data so RideOptionCard can show real ETA + driver count
            liveEta:      live.etaLabel,
            liveEtaColor: live.etaColor,
            driverCount:  live.availability.count,
            isAvailable:  live.isAvailable,
            dynamicPrice: live.dynamicPrice,
          ),
        )).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STATIC OPTIONS — fallback when no pickup location yet
// ─────────────────────────────────────────────────────────────────────────────

class _StaticRideOptions extends StatelessWidget {
  final RideRequestState state;
  final double           distanceKm;
  final WidgetRef        ref;

  const _StaticRideOptions({
    required this.state,
    required this.distanceKm,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: RideOptionsService.availableRides.map((ride) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: RideOptionCard(
            option:     ride,
            isSelected: state.selectedRide?.serviceType == ride.serviceType,
            onTap: () {
              HapticFeedback.selectionClick();
              ref.read(rideRequestProvider.notifier).selectRide(ride);
            },
            distance:     distanceKm,
            dynamicPrice: RideOptionsService.calculateDynamicPrice(
                ride, distanceKm),
          ),
        )).toList(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// SKELETON — shown while live data loads
// ─────────────────────────────────────────────────────────────────────────────

class _RideOptionsSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(
        children: List.generate(
          2,
          (_) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            height: 88,
            decoration: BoxDecoration(
              color:        AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      );
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
      orElse: ()  => 0.0,
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
        Text(
          method.name,
          style: AppTextStyles.labelLarge
              .copyWith(fontWeight: FontWeight.w600),
        ),
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