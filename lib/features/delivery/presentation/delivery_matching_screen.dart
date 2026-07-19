// lib/features/delivery/presentation/delivery_matching_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../models/delivery_request.dart';
import '../../delivery/providers/delivery_provider.dart';
import 'delivery_tracking_screen.dart';

const _kPrimary = AppColors.primary;

class DeliveryMatchingScreen extends ConsumerStatefulWidget {
  final String deliveryId;
  final String vehicleName;
  final String dropoff;
  final String fare;

  const DeliveryMatchingScreen({
    super.key,
    required this.deliveryId,
    required this.vehicleName,
    required this.dropoff,
    required this.fare,
  });

  @override
  ConsumerState<DeliveryMatchingScreen> createState() =>
      _DeliveryMatchingScreenState();
}

class _DeliveryMatchingScreenState extends ConsumerState<DeliveryMatchingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _scaleOuter;
  late final Animation<double> _scaleInner;

  int _dots = 1;
  bool _navigating = false;
  bool _cancelling = false;

  Timer? _timeoutTimer;
  bool _timedOut = false;
  static const _matchTimeout = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    _scaleOuter = Tween<double>(begin: 1.0, end: 1.5).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeOut),
    );
    _scaleInner = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeOut),
    );

    _tickDots();
    _startTimeout();
  }

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _timedOut = false;
    _timeoutTimer = Timer(_matchTimeout, () {
      if (mounted && !_navigating) setState(() => _timedOut = true);
    });
  }

  void _retry() {
    setState(() => _timedOut = false);
    _startTimeout();
  }

  void _tickDots() {
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() => _dots = (_dots % 3) + 1);
      _tickDots();
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _goToTracking() {
    if (_navigating) return;
    _navigating = true;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => DeliveryTrackingScreen(
          deliveryId: widget.deliveryId,
        ),
      ),
    );
  }

  Future<void> _cancel() async {
    if (_cancelling) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Cancel request?',
            style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text(
            'Are you sure you want to cancel this delivery request?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    setState(() => _cancelling = true);

    try {
      await ref
          .read(deliveryRepositoryProvider)
          .cancelDelivery(widget.deliveryId, reason: 'Cancelled by passenger');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _cancelling = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not cancel: $e'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
        ));
      }
    }
  }

  IconData get _vehicleIcon => switch (widget.vehicleName) {
        'Aboboya' => Icons.electric_rickshaw_rounded,
        'Mini Truck' => Icons.local_shipping_rounded,
        _ => Icons.two_wheeler_rounded,
      };

  @override
  Widget build(BuildContext context) {
    ref.listen(
      deliveryStreamProvider(widget.deliveryId),
      (_, next) {
        final d = next.value;
        if (d == null) return;
        if (d.status == DeliveryStatus.cancelled) {
          _timeoutTimer?.cancel();
          if (mounted) Navigator.pop(context);
          return;
        }
        if (d.status != DeliveryStatus.pending) {
          _timeoutTimer?.cancel();
          _goToTracking();
        }
      },
    );

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              children: [
                // ── Header ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _CancelBtn(
                      onTap: _cancel,
                      loading: _cancelling,
                    ),
                    Text(widget.vehicleName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        )),
                    const SizedBox(width: 36),
                  ],
                ),

                const Spacer(),

                if (!_timedOut) ...[
                  // ── Searching: pulse animation ──
                  AnimatedBuilder(
                    animation: _pulseCtrl,
                    builder: (_, __) => SizedBox(
                      width: 180,
                      height: 180,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Transform.scale(
                            scale: _scaleOuter.value,
                            child: Container(
                              width: 140,
                              height: 140,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _kPrimary.withValues(
                                    alpha: (1 - _pulseCtrl.value) * 0.1),
                              ),
                            ),
                          ),
                          Transform.scale(
                            scale: _scaleInner.value,
                            child: Container(
                              width: 110,
                              height: 110,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _kPrimary.withValues(
                                    alpha: (1 - _pulseCtrl.value) * 0.15),
                              ),
                            ),
                          ),
                          Container(
                            width: 80,
                            height: 80,
                            decoration: const BoxDecoration(
                                color: _kPrimary, shape: BoxShape.circle),
                            child: Icon(_vehicleIcon,
                                color: Colors.white, size: 36),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  Text(
                    'Finding a rider${'.' * _dots}',
                    style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Looking for a nearby ${widget.vehicleName} rider',
                    style: const TextStyle(
                        fontSize: 14, color: AppColors.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                ] else ...[
                  // ── Timed out: no riders found ──
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.warning.withValues(alpha: 0.12),
                    ),
                    child: Icon(Icons.search_off_rounded,
                        color: AppColors.warning, size: 52),
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    'No riders available',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'No ${widget.vehicleName} riders responded right now. '
                    'You can keep waiting or cancel for a full refund.',
                    style: const TextStyle(
                        fontSize: 14, color: AppColors.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                ],

                const SizedBox(height: 40),

                // ── Summary card ──
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    children: [
                      _SummaryRow(
                        icon: Icons.location_on_rounded,
                        iconColor: _kPrimary,
                        label: 'Delivering to',
                        value: widget.dropoff,
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Divider(height: 0.5, color: AppColors.border),
                      ),
                      _SummaryRow(
                        icon: Icons.payments_rounded,
                        iconColor: AppColors.success,
                        label: 'Estimated fare',
                        value: widget.fare,
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Divider(height: 0.5, color: AppColors.border),
                      ),
                      const _SummaryRow(
                        icon: Icons.account_balance_wallet_rounded,
                        iconColor: AppColors.info,
                        label: 'Payment',
                        value: 'CTSTransport Wallet',
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // ── Cancel button ──
                _cancelling
                    ? const CircularProgressIndicator(color: _kPrimary)
                    : Column(
                        children: [
                          if (_timedOut) ...[
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _retry,
                                style: FilledButton.styleFrom(
                                  backgroundColor: _kPrimary,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14)),
                                ),
                                child: const Text('Keep searching',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700)),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed: _cancel,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.error,
                                side: BorderSide(
                                    color:
                                        AppColors.error.withValues(alpha: 0.4)),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14)),
                              ),
                              child: Text(
                                  _timedOut
                                      ? 'Cancel & refund'
                                      : 'Cancel Request',
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ),
                        ],
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CancelBtn extends StatelessWidget {
  final VoidCallback onTap;
  final bool loading;
  const _CancelBtn({required this.onTap, required this.loading});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: loading ? null : onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: loading
              ? const Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.error,
                  ),
                )
              : const Icon(Icons.close_rounded,
                  size: 18, color: AppColors.textSecondary),
        ),
      );
}

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  const _SummaryRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: iconColor, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                )),
          ),
          Flexible(
            child: Text(value,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      );
}
