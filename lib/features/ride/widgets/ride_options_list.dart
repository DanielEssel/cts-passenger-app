// features/ride/widgets/ride_options_list.dart
//
// ✅ No ref.watch — state passed in; only ref.read for actions
// ✅ PaymentSelector extracted to its own class
// ✅ Wallet balance fetched from walletBalanceProvider, not hardcoded

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../payment/models/payment_method.dart';
import '../models/ride_option.dart';
import '../providers/ride_request_provider.dart';
import '../providers/wallet_provider.dart';
import '../services/payment_method_service.dart';
import 'ride_option_card.dart';
// import 'payment_method_sheet.dart';
import '../constants/ride_constants.dart';

class RideOptionsList extends ConsumerWidget {
  final RideRequestState state;
  final VoidCallback onShowPaymentSheet;

  const RideOptionsList({
    super.key,
    required this.state,
    required this.onShowPaymentSheet,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CHOOSE RIDE',
            style: AppTextStyles.overline.copyWith(
              color: AppColors.textTertiary,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          ...RideOptionsService.availableRides.map((ride) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: RideOptionCard(
                  option: ride,
                  isSelected:
                      state.selectedRide?.serviceType == ride.serviceType,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    ref.read(rideRequestProvider.notifier).selectRide(ride);
                  },
                  distance: state.estimatedDistance ??
                      RideConstants.defaultDistanceKm,
                ),
              )),
          const SizedBox(height: 4),
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

// ---------------------------------------------------------------------------
// PaymentSelector — reads wallet balance from provider
// ---------------------------------------------------------------------------

class PaymentSelector extends ConsumerWidget {
  final RideRequestState state;
  final VoidCallback onTap;

  const PaymentSelector({
    super.key,
    required this.state,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedMethod = PaymentMethod.fromType(state.paymentMethod);
    // ✅ walletBalance comes from the provider, not a hardcoded field
final walletBalance = ref.watch(walletBalanceProvider).maybeWhen(
  data: (balance) => balance,
  orElse: () => 0.0,
);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            _PaymentIcon(method: selectedMethod),
            const SizedBox(width: 12),
            Expanded(
              child: _PaymentDetails(
                method: selectedMethod,
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
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: AppColors.primaryDim,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(method.icon, color: AppColors.primary, size: 18),
    );
  }
}

class _PaymentDetails extends StatelessWidget {
  final PaymentMethod method;
  final double walletBalance;

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
          style: AppTextStyles.labelLarge.copyWith(fontWeight: FontWeight.w600),
        ),
        Text(
          isWallet
              ? 'Balance: ${PaymentMethodService.getFormattedBalance(walletBalance)}'
              : method.subtitle,
          style: AppTextStyles.caption.copyWith(
            color:
                isWallet ? AppColors.success : AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}