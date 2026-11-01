// lib/features/gas/presentation/widgets/gas_payment_sheet.dart

import 'package:flutter/material.dart';
import '../../../../core/theme/cts_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:io' show SocketException;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../core/constants/app_colors.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/gas/domain/gas_pricing.dart';
import 'package:cts_transport_app/features/wallet/presentation/providers/wallet_providers.dart';
import 'package:cts_transport_app/features/wallet/presentation/widgets/bridge_momo_sheet.dart';
import '../../../../core/utils/cedi_format.dart';

/// Slides up before placing a gas order.
/// Returns `true`  when payment succeeds (caller should proceed to create order).
/// Returns `false` / null when user cancels.
// ── Error presentation ──────────────────────────────────────────────────────
// Payment problems are explained in plain words; the raw exception (which
// can carry internal service text) goes to the debug log only. Specific
// outcomes such as "insufficient balance" are shown by the sheet directly,
// and Mobile Money results are explained inside the MoMo sheet.

const _kConnectionCodes = {
  'unavailable',
  'network-request-failed',
  'deadline-exceeded',
  'internal',
};
const _kAuthCodes = {
  'unauthenticated',
  'permission-denied',
  'user-token-expired',
  'requires-recent-login',
};

/// Plain-language message for an unexpected error during gas payment.
String gasPaymentErrorMessage(Object error) {
  String? code;
  if (error is FirebaseFunctionsException) code = error.code;
  if (error is FirebaseException) code = error.code;
  if (error is FirebaseAuthException) code = error.code;

  if (error is SocketException ||
      error is TimeoutException ||
      (code != null && _kConnectionCodes.contains(code))) {
    return "We couldn't reach CTSGo. Check your connection and try again.";
  }
  if (code != null && _kAuthCodes.contains(code)) {
    return 'Your session has expired. Please sign in again to pay.';
  }
  return "Something went wrong with this payment. Check your wallet "
      "balance, then try again.";
}

/// Logs [error] and shows the plain-language message in a snack bar.
void showGasPaymentError(BuildContext context, Object error) {
  debugPrint('Gas payment error: $error');
  _showGasPaymentSnack(context, gasPaymentErrorMessage(error));
}

void _showGasPaymentSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: CtsTheme.errorDeep,
  ));
}

class GasPaymentSheet extends ConsumerStatefulWidget {
  final GasRefillType refillType;
  final CylinderSize cylinderSize;
  final GasBrand? brand;
  final int quantity;
  final double gasPrice;
  final double deliveryFee;
  final double total;

  /// The order's price breakdown; when given, the summary shows its lines
  /// (which add up to [total]) instead of working them out from [gasPrice].
  final GasPriceBreakdown? pricing;

  const GasPaymentSheet({
    super.key,
    required this.refillType,
    required this.cylinderSize,
    this.brand,
    required this.quantity,
    required this.gasPrice,
    required this.deliveryFee,
    required this.total,
    this.pricing,
  });

  @override
  ConsumerState<GasPaymentSheet> createState() => _GasPaymentSheetState();
}

class _GasPaymentSheetState extends ConsumerState<GasPaymentSheet> {
  bool _isProcessing = false;

  double get _brandPremium {
    final p = widget.pricing;
    if (p != null) return p.brandPremium;
    if (widget.brand == null || widget.brand!.priceMultiplier == 1.0) return 0;
    return widget.gasPrice *
        widget.quantity *
        (widget.brand!.priceMultiplier - 1);
  }

  // ─────────────────────────────────────────────
  // Pay from wallet
  // ─────────────────────────────────────────────

  Future<void> _payWithWallet(double balance) async {
    if (balance < widget.total) return;

    setState(() => _isProcessing = true);
    HapticFeedback.mediumImpact();

    try {
      // Do NOT deduct here. The order screen holds funds in escrow via
      // EscrowService.holdBalance, and the Cloud Function releases them on
      // delivery. The client never moves money directly. We only confirm the
      // wallet can cover the total, then signal the caller to proceed.
      if (balance < widget.total) {
        _showError('Insufficient wallet balance. Please top up.');
        return;
      }
      if (!mounted) return;
      Navigator.pop(context, true); // ← signals _placeOrder to run holdBalance
    } catch (e) {
      if (mounted) showGasPaymentError(context, e);
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // ─────────────────────────────────────────────
  // Top-up then pay
  // ─────────────────────────────────────────────

  Future<void> _topUpAndPay(double balance) async {
    final deficit = widget.total - balance;
    // Round up to nearest 5 for a nicer top-up amount
    final topUpAmount = (deficit / 5).ceil() * 5.0;

    setState(() => _isProcessing = true);

    try {
      if (FirebaseAuth.instance.currentUser == null) {
        _showError('Unable to top up without a signed-in user.');
        return;
      }

      // Same Mobile Money top-up as the wallet screen (The Bridge
      // Solutions). It returns true only once the top-up is confirmed and
      // credited; an unconfirmed payment is explained in the sheet itself.
      final success = await showBridgeMomoSheet(context, amount: topUpAmount);

      if (!mounted) return;

      if (success) {
        // Refresh wallet then re-check balance automatically
        await ref.read(walletProvider.notifier).refresh();
        // Balance should now be sufficient — proceed
        final newBalance = ref.read(walletStreamProvider).value?.balance ?? 0.0;
        await _payWithWallet(newBalance);
      }
    } catch (e) {
      if (mounted) showGasPaymentError(context, e);
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showError(String message) => _showGasPaymentSnack(context, message);

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final walletAsync = ref.watch(walletStreamProvider);

    return Container(
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        // AFTER:
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Handle ──
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: CtsTheme.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Title ──
                      Text('Confirm Payment',
                          style: AppColors.titleMedium
                              .copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text('Review your order and pay from wallet',
                          style: AppColors.bodyMedium
                              .copyWith(color: CtsTheme.textSecondary)),

                      const SizedBox(height: 20),

                      // ── Order summary ──
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AppColors.borderLight,
                          ),
                        ),
                        child: Column(
                          children: [
                            _SummaryRow(
                              label:
                                  '${widget.cylinderSize.displayName} × ${widget.quantity}',
                              amount: widget.pricing?.base ??
                                  widget.gasPrice * widget.quantity,
                            ),
                            if (_brandPremium > 0) ...[
                              const SizedBox(height: 10),
                              _SummaryRow(
                                label:
                                    'Brand premium (${widget.brand!.displayName})',
                                amount: _brandPremium,
                              ),
                            ],
                            const SizedBox(height: 10),
                            _SummaryRow(
                                label: 'Delivery fee',
                                amount: widget.deliveryFee),
                            const Divider(height: 24, color: CtsTheme.border),
                            _SummaryRow(
                              label: 'Total',
                              amount: widget.total,
                              isTotal: true,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

                      // ── Wallet balance ──
                      walletAsync.when(
                        loading: () => _buildBalanceSkeleton(),
                        error: (_, __) => _buildBalanceError(),
                        data: (wallet) {
                          final balance = wallet.balance;
                          final hasFunds = balance >= widget.total;
                          return _buildBalanceCard(balance, hasFunds);
                        },
                      ),

                      const SizedBox(height: 20),

                      // ── CTA ──
                      walletAsync.when(
                        loading: () => _buildLoadingButton(),
                        error: (_, __) => _buildErrorButton(),
                        data: (wallet) {
                          final balance = wallet.balance;
                          final hasFunds = balance >= widget.total;
                          return hasFunds
                              ? _buildPayButton(balance)
                              : _buildTopUpButton(balance);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ));
  }

  // ─────────────────────────────────────────────
  // Balance card states
  // ─────────────────────────────────────────────

  Widget _buildBalanceCard(double balance, bool hasFunds) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: hasFunds
            ? CtsTheme.primary.withValues(alpha: 0.08)
            : Colors.orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasFunds
              ? CtsTheme.primary.withValues(alpha: 0.3)
              : Colors.orange.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: hasFunds
                  ? CtsTheme.primary.withValues(alpha: 0.15)
                  : Colors.orange.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.account_balance_wallet_rounded,
              color: hasFunds ? CtsTheme.primary : Colors.orange,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Wallet Balance',
                    style: AppColors.labelSmall
                        .copyWith(color: CtsTheme.textSecondary)),
                const SizedBox(height: 3),
                Text(
                  formatCedis(balance),
                  style: AppColors.titleMedium.copyWith(
                    fontWeight: FontWeight.w800,
                    color: hasFunds ? CtsTheme.primary : Colors.orange,
                  ),
                ),
              ],
            ),
          ),
          if (!hasFunds)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Short by',
                    style: AppColors.labelSmall
                        .copyWith(color: CtsTheme.textSecondary)),
                Text(
                  formatCedis(widget.total - balance),
                  style: AppColors.bodyMedium.copyWith(
                    color: Colors.orange,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildBalanceSkeleton() => Container(
        height: 72,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
      );

  Widget _buildBalanceError() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
        ),
        child: const Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 18),
            SizedBox(width: 10),
            Text('Could not load wallet balance',
                style: TextStyle(color: Colors.red)),
          ],
        ),
      );

  // ─────────────────────────────────────────────
  // Action buttons
  // ─────────────────────────────────────────────

  Widget _buildPayButton(double balance) => SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: _isProcessing ? null : () => _payWithWallet(balance),
          style: ElevatedButton.styleFrom(
            backgroundColor: CtsTheme.vivid,
            foregroundColor: CtsTheme.onVivid,
            disabledBackgroundColor: CtsTheme.vivid.withValues(alpha: 0.5),
            disabledForegroundColor: CtsTheme.onVivid,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          child: _isProcessing
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: CtsTheme.onVivid),
                )
              : Text(
                  'Pay ${formatCedis(widget.total)}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800),
                ),
        ),
      );

  Widget _buildTopUpButton(double balance) => SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _isProcessing ? null : () => _topUpAndPay(balance),
          icon: const Icon(Icons.add_rounded),
          label: _isProcessing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: CtsTheme.onVivid),
                )
              : Text(
                  'Top Up & Pay ${formatCedis(widget.total)}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800),
                ),
          style: ElevatedButton.styleFrom(
            // Was white on orange (2.1:1).
            backgroundColor: CtsTheme.vivid,
            foregroundColor: CtsTheme.onVivid,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      );

  Widget _buildLoadingButton() => Container(
        width: double.infinity,
        height: 54,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
      );

  Widget _buildErrorButton() => SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => ref.invalidate(walletStreamProvider),
          style: ElevatedButton.styleFrom(
            backgroundColor: CtsTheme.textPrimary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          child: const Text('Retry'),
        ),
      );
}

// ─────────────────────────────────────────────
// Private summary row
// ─────────────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  final String label;
  final double amount;
  final bool isTotal;

  const _SummaryRow({
    required this.label,
    required this.amount,
    this.isTotal = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(label,
              style: isTotal
                  ? AppColors.titleMedium.copyWith(fontWeight: FontWeight.bold)
                  : AppColors.bodyMedium),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            formatCedis(amount),
            textAlign: TextAlign.end,
            style: isTotal
                ? AppColors.titleLarge.copyWith(
                    color: AppColors.primaryColor,
                    fontWeight: FontWeight.bold,
                  )
                : AppColors.bodyMedium,
          ),
        ),
      ],
    );
  }
}
