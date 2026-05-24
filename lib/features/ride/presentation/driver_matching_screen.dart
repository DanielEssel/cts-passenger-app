// lib/features/ride/presentation/driver_matching_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';

class DriverMatchingScreen extends ConsumerStatefulWidget {
  final String rideType;
  final String destination;
  final String fare;
  final String tripId;

  const DriverMatchingScreen({
    super.key,
    required this.rideType,
    required this.destination,
    required this.fare,
    required this.tripId,
  });

  @override
  ConsumerState<DriverMatchingScreen> createState() =>
      _DriverMatchingScreenState();
}

class _DriverMatchingScreenState extends ConsumerState<DriverMatchingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Timer               _dotsTimer;
  Timer?                         _timeoutTimer;
  StreamSubscription<DocumentSnapshot>? _tripSub;

  int    _dotsCount    = 1;
  int    _secondsLeft  = 120; // 2 min timeout
  bool   _isCancelling = false;
  bool   _isNavigating = false;

  static const _timeoutSeconds = 300;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _dotsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _dotsCount = (_dotsCount % 3) + 1);
    });

    // Countdown timer
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        _timeoutTimer?.cancel();
        _handleTimeout();
      }
    });

    _listenForDriverAssignment();
  }

  // ── Firestore listener ────────────────────────────────────────────────────

  void _listenForDriverAssignment() {
    _tripSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(widget.tripId)
        .snapshots()
        .listen((snap) {
      if (!mounted || !snap.exists) return;

      final data   = snap.data()!;
      final status = data['status'] as String? ?? '';

      switch (status) {
        case 'tripAccepted':
        case 'driverArrived':
          _timeoutTimer?.cancel();
          _navigateToTracking(
            driverName:   data['driverName']   as String? ?? 'Your driver',
            driverRating: (data['driverRating'] as num?)?.toDouble() ?? 5.0,
            driverPlate:  data['driverPlate']  as String? ?? '',
            driverPhoto:  data['driverPhoto']  as String? ?? '',
            vehicleModel: data['vehicleModel'] as String? ?? '',
            eta:          data['eta']          as String? ?? '5 min',
          );

        case 'noDriversAvailable':
        case 'expired':
          _timeoutTimer?.cancel();
          _showNoDriversDialog();

        case 'cancelledByDriver':
          _timeoutTimer?.cancel();
          _showDriverCancelledDialog();

        case 'cancelledByPassenger':
          // Already handled — do nothing
          break;
      }
    });
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _navigateToTracking({
    required String driverName,
    required double driverRating,
    required String driverPlate,
    required String driverPhoto,
    required String vehicleModel,
    required String eta,
  }) {
    if (!mounted || _isNavigating) return;
    _isNavigating = true;

    Navigator.pushReplacementNamed(
      context,
      AppRoutes.rideTracking,
      arguments: widget.tripId,
    );
  }

  // ── Timeout ───────────────────────────────────────────────────────────────

  Future<void> _handleTimeout() async {
    if (!mounted) return;
    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(widget.tripId)
          .update({
        'status':      'noDriversAvailable',
        'expiredAt':   FieldValue.serverTimestamp(),
        'expiredBy':   'passenger_timeout',
      });
    } catch (_) {}
    if (mounted) _showNoDriversDialog();
  }

  // ── Cancellation ──────────────────────────────────────────────────────────

  Future<void> _cancelTripRequest() async {
    if (_isCancelling) return;
    setState(() => _isCancelling = true);
    _timeoutTimer?.cancel();

    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(widget.tripId)
          .update({
        'status':             'cancelledByPassenger',
        'cancelledAt':        FieldValue.serverTimestamp(),
        'cancellationReason': 'User cancelled while searching',
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error cancelling: $e')),
        );
        setState(() => _isCancelling = false);
      }
    }
  }

  // ── Dialogs ───────────────────────────────────────────────────────────────

  void _showNoDriversDialog() {
    if (!mounted) return;
    showDialog<void>(
      context:           context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color:        AppColors.warningLight,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.person_search_rounded,
                  color: AppColors.warning, size: 32),
            ),
            const SizedBox(height: 16),
            const Text('No drivers found',
                style: TextStyle(
                  fontSize:   18,
                  fontWeight: FontWeight.w700,
                )),
            const SizedBox(height: 8),
            const Text(
              'No drivers are available near you right now. '
              'Please try again in a few minutes.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(dialogCtx); // close dialog
                  if (context.mounted) Navigator.pop(context);
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Try Again'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDriverCancelledDialog() {
    if (!mounted) return;
    showDialog<void>(
      context:           context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color:        AppColors.errorLight,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.cancel_rounded,
                  color: AppColors.error, size: 32),
            ),
            const SizedBox(height: 16),
            const Text('Driver cancelled',
                style: TextStyle(
                  fontSize:   18,
                  fontWeight: FontWeight.w700,
                )),
            const SizedBox(height: 8),
            const Text(
              'Your driver cancelled the request. '
              'Please try booking again.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(dialogCtx);
                  if (context.mounted) Navigator.pop(context);
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Book Again'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _pulseController.dispose();
    _dotsTimer.cancel();
    _timeoutTimer?.cancel();
    _tripSub?.cancel();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final progress = _secondsLeft / _timeoutSeconds;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              // ── Top bar ──
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    onTap: _isCancelling ? null : _cancelTripRequest,
                    child: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color:        AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(10),
                        border:       Border.all(color: AppColors.border),
                      ),
                      child: _isCancelling
                          ? const Padding(
                              padding: EdgeInsets.all(9),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.close_rounded,
                              size: 18, color: AppColors.textSecondary),
                    ),
                  ),
                  Text(widget.rideType, style: AppTextStyles.heading4),
                  // Timeout countdown
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color:        _secondsLeft <= 30
                          ? AppColors.errorLight
                          : AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${_secondsLeft ~/ 60}:${(_secondsLeft % 60).toString().padLeft(2, '0')}',
                      style: TextStyle(
                        fontSize:   12,
                        fontWeight: FontWeight.w700,
                        color:      _secondsLeft <= 30
                            ? AppColors.error
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),

              const Spacer(),

              // ── Pulsing ring ──
              _PulsingRing(controller: _pulseController),

              const SizedBox(height: 32),

              // ── Searching label ──
              Text(
                'Finding your driver${'.' * _dotsCount}',
                style: AppTextStyles.heading2,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Looking for nearby ${widget.rideType} drivers',
                style: AppTextStyles.bodySmall,
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 24),

              // ── Progress bar ──
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value:           progress,
                  minHeight:       4,
                  backgroundColor: AppColors.border,
                  valueColor:      AlwaysStoppedAnimation<Color>(
                    _secondsLeft <= 30
                        ? AppColors.error
                        : AppColors.primary,
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // ── Trip summary ──
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color:        AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border:       Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: [
                    _SummaryRow(
                      icon:      Icons.location_on_rounded,
                      iconColor: AppColors.primary,
                      label:     'Going to',
                      value:     widget.destination,
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Divider(height: 0.5, color: AppColors.border),
                    ),
                    _SummaryRow(
                      icon:      Icons.account_balance_wallet_rounded,
                      iconColor: AppColors.success,
                      label:     'Estimated fare',
                      value:     widget.fare,
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // ── Cancel button ──
              GestureDetector(
                onTap: _isCancelling ? null : _cancelTripRequest,
                child: Container(
                  width:   double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color:        AppColors.errorLight,
                    borderRadius: BorderRadius.circular(14),
                    border:       Border.all(
                        color: AppColors.error.withValues(alpha: 0.2)),
                  ),
                  child: _isCancelling
                      ? const Center(
                          child: SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color:       AppColors.error,
                            ),
                          ),
                        )
                      : const Text(
                          'Cancel request',
                          style: TextStyle(
                            fontSize:   15,
                            fontWeight: FontWeight.w600,
                            color:      AppColors.error,
                          ),
                          textAlign: TextAlign.center,
                        ),
                ),
              ),

              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Pulsing ring ──────────────────────────────────────────────────────────────

class _PulsingRing extends StatelessWidget {
  final AnimationController controller;
  const _PulsingRing({required this.controller});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (_, __) => Stack(
          alignment: Alignment.center,
          children: [
            Transform.scale(
              scale: 1.0 + (controller.value * 0.4),
              child: Container(
                width: 140, height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withValues(
                    alpha: (1.0 - controller.value) * 0.12,
                  ),
                ),
              ),
            ),
            Transform.scale(
              scale: 1.0 + (controller.value * 0.2),
              child: Container(
                width: 110, height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withValues(
                    alpha: (1.0 - controller.value) * 0.15,
                  ),
                ),
              ),
            ),
            Container(
              width: 80, height: 80,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.directions_car_rounded,
                color: AppColors.background,
                size:  36,
              ),
            ),
          ],
        ),
      );
}

// ── Summary row ───────────────────────────────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final Color    iconColor;
  final String   label;
  final String   value;

  const _SummaryRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, color: iconColor, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: AppTextStyles.bodySmall)),
          Text(value,
              style:    AppTextStyles.labelLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
      );
}