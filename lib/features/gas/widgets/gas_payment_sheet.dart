// lib/features/gas/presentation/widgets/gas_payment_sheet.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cts_transport_app/core/theme/app_theme.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/wallet/presentation/providers/wallet_providers.dart';
import 'package:cts_transport_app/features/wallet/presentation/providers/wallet_controller.dart';
import 'package:cts_transport_app/widgets/common/glass_card.dart';

/// Slides up before placing a gas order.
/// Returns `true`  when payment succeeds (caller should proceed to create order).
/// Returns `false` / null when user cancels.
class GasPaymentSheet extends ConsumerStatefulWidget {
  final GasRefillType refillType;
  final CylinderSize cylinderSize;
  final GasBrand? brand;
  final int quantity;
  final double gasPrice;
  final double deliveryFee;
  final double total;

  const GasPaymentSheet({
    super.key,
    required this.refillType,
    required this.cylinderSize,
    this.brand,
    required this.quantity,
    required this.gasPrice,
    required this.deliveryFee,
    required this.total,
  });

  @override
  ConsumerState<GasPaymentSheet> createState() => _GasPaymentSheetState();
}

class _GasPaymentSheetState extends ConsumerState<GasPaymentSheet> {
  bool _isProcessing = false;

  double get _brandPremium {
    if (widget.brand == null || widget.brand!.priceMultiplier == 1.0) return 0;
    return widget.gasPrice * widget.quantity * (widget.brand!.priceMultiplier - 1);
  }

  // ─────────────────────────────────────────────
  // Pay from wallet
  // ─────────────────────────────────────────────

  Future<void> _payWithWallet(double balance) async {
    if (balance < widget.total) return;

    setState(() => _isProcessing = true);
    HapticFeedback.mediumImpact();

    try {
      final controller = ref.read(walletControllerProvider);
      final success = await controller.deductForGasOrder(
        amount: widget.total,
        description:
            'Gas order — ${widget.cylinderSize.displayName} × ${widget.quantity}',
      );

      if (!mounted) return;

      if (success) {
        Navigator.pop(context, true); // ← signals caller to proceed
      } else {
        _showError('Payment failed. Please try again.');
      }
    } catch (e) {
      if (mounted) _showError(e.toString().replaceFirst('Exception: ', ''));
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
      final controller = ref.read(walletControllerProvider);
      final success = await controller.topUp(
        amount: topUpAmount,
        paymentMethod: 'card',
      );

      if (!mounted) return;

      if (success) {
        // Refresh wallet then re-check balance automatically
        await ref.read(walletProvider.notifier).refresh();
        // Balance should now be sufficient — proceed
        final newBalance =
            ref.read(walletStreamProvider).value?.balance ?? 0.0;
        await _payWithWallet(newBalance);
      }
    } catch (e) {
      if (mounted) _showError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: Colors.red,
    ));
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final walletAsync = ref.watch(walletStreamProvider);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.background,
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
                width: 38, height: 4,
                margin: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.grey[700],
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
                      style: AppTheme.titleLarge
                          .copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('Review your order and pay from wallet',
                      style:
                          AppTheme.bodyMedium.copyWith(color: Colors.grey)),

                  const SizedBox(height: 20),

                  // ── Order summary ──
                  GlassCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _SummaryRow(
                          label:
                              '${widget.cylinderSize.displayName} × ${widget.quantity}',
                          amount: widget.gasPrice * widget.quantity,
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
                        Divider(
                            height: 24,
                            color: Colors.grey[800]),
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
                      final balance = wallet?.balance ?? 0.0;
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
                      final balance = wallet?.balance ?? 0.0;
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
)
    );

  }

  // ─────────────────────────────────────────────
  // Balance card states
  // ─────────────────────────────────────────────

  Widget _buildBalanceCard(double balance, bool hasFunds) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: hasFunds
            ? Colors.green.withValues(alpha: 0.08)
            : Colors.orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasFunds
              ? Colors.green.withValues(alpha: 0.3)
              : Colors.orange.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: hasFunds
                  ? Colors.green.withValues(alpha: 0.15)
                  : Colors.orange.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.account_balance_wallet_rounded,
              color: hasFunds ? Colors.green : Colors.orange,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Wallet Balance',
                    style:
                        AppTheme.labelSmall.copyWith(color: Colors.grey)),
                const SizedBox(height: 3),
                Text(
                  '₵${balance.toStringAsFixed(2)}',
                  style: AppTheme.titleMedium.copyWith(
                    fontWeight: FontWeight.w800,
                    color: hasFunds ? Colors.green : Colors.orange,
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
                    style: AppTheme.labelSmall.copyWith(color: Colors.grey)),
                Text(
                  '₵${(widget.total - balance).toStringAsFixed(2)}',
                  style: AppTheme.bodyMedium.copyWith(
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
          color: AppTheme.surface,
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
          onPressed:
              _isProcessing ? null : () => _payWithWallet(balance),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            foregroundColor: Colors.white,
            disabledBackgroundColor:
                AppTheme.primaryColor.withValues(alpha: 0.5),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
          ),
          child: _isProcessing
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Text(
                  'Pay ₵${widget.total.toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800),
                ),
        ),
      );

  Widget _buildTopUpButton(double balance) => SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed:
              _isProcessing ? null : () => _topUpAndPay(balance),
          icon: const Icon(Icons.add_rounded),
          label: _isProcessing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Text(
                  'Top Up & Pay ₵${widget.total.toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800),
                ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
          ),
        ),
      );

  Widget _buildLoadingButton() => Container(
        width: double.infinity,
        height: 54,
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
      );

  Widget _buildErrorButton() => SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => ref.invalidate(walletStreamProvider),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.grey[800],
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
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
                  ? AppTheme.titleMedium
                      .copyWith(fontWeight: FontWeight.bold)
                  : AppTheme.bodyMedium),
        ),
        Text(
          '₵${amount.toStringAsFixed(2)}',
          style: isTotal
              ? AppTheme.titleLarge.copyWith(
                  color: AppTheme.primaryColor,
                  fontWeight: FontWeight.bold,
                )
              : AppTheme.bodyMedium,
        ),
      ],
    );
  }
}