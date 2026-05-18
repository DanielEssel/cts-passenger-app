

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import 'ride_tracking_screen.dart';

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
  late final Timer _dotsTimer;
  StreamSubscription<DocumentSnapshot>? _tripSubscription;

  int _dotsCount = 1;
  bool _isCancelling = false;
  bool _isNavigating = false; // ✅ guard against duplicate navigation

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    // ✅ Periodic timer instead of recursive Future.delayed
    _dotsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _dotsCount = (_dotsCount % 3) + 1);
    });

    _listenForDriverAssignment();
  }

  // ---------------------------------------------------------------------------
  // Firestore listener
  // ---------------------------------------------------------------------------

  void _listenForDriverAssignment() {
    _tripSubscription = FirebaseFirestore.instance
        .collection('trips')
        .doc(widget.tripId)
        .snapshots()
        .listen((snapshot) {
      if (!mounted || !snapshot.exists) return;

      final data = snapshot.data()!;
      final status = data['status'] as String? ?? '';

      switch (status) {
        case 'pending':
        case 'accepted':
          _navigateToTracking(
            driverName: data['driverName'] as String? ?? 'Your driver',
            driverRating:
                (data['driverRating'] as num?)?.toDouble() ?? 4.8,
            driverPlate: data['driverPlate'] as String? ?? 'Loading...',
            eta: data['eta'] as String? ?? '5 min',
          );

        case 'noDriversAvailable':
          _showNoDriversDialog();

        case 'cancelledByDriver':
          _showDriverCancelledDialog();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _navigateToTracking({
    required String driverName,
    required double driverRating,
    required String driverPlate,
    required String eta,
  }) {
    // ✅ Guard: Firestore may emit the same status update more than once
    if (!mounted || _isNavigating) return;
    _isNavigating = true;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => RideTrackingScreen(
          tripId: widget.tripId,
          rideType: widget.rideType,
          destination: widget.destination,
          fare: widget.fare,
          driverName: driverName,
          driverRating: driverRating,
          driverPlate: driverPlate,
          eta: eta,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Trip cancellation
  // ---------------------------------------------------------------------------

  Future<void> _cancelTripRequest() async {
    if (_isCancelling) return;
    setState(() => _isCancelling = true);

    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(widget.tripId)
          .update({
        'status': 'cancelledByPassenger',
        'cancelledAt': FieldValue.serverTimestamp(),
        'cancellationReason': 'User cancelled while searching',
      });

      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error cancelling trip: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  void _showNoDriversDialog() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('No drivers available'),
        content: const Text(
          'No drivers are available near your location right now. '
          'Please try again in a few minutes.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // close dialog
              Navigator.pop(context); // back to booking
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showDriverCancelledDialog() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Driver Cancelled'),
        content: const Text(
          'The driver cancelled your request. Please try booking again.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // close dialog
              Navigator.pop(context); // back to booking
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _pulseController.dispose();
    _dotsTimer.cancel();          // ✅ no orphaned timer
    _tripSubscription?.cancel();  // ✅ no Firestore leak
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              _TopBar(
                rideType: widget.rideType,
                isCancelling: _isCancelling,
                onCancel: _isCancelling ? null : _cancelTripRequest,
              ),
              const Spacer(),
              _PulsingRing(controller: _pulseController),
              const SizedBox(height: 40),
              _SearchingLabel(
                dotsCount: _dotsCount,
                rideType: widget.rideType,
              ),
              const SizedBox(height: 40),
              _TripSummaryCard(
                destination: widget.destination,
                fare: widget.fare,
              ),
              const Spacer(),
              _CancelButton(
                isCancelling: _isCancelling,
                onTap: _isCancelling ? null : _cancelTripRequest,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Private sub-widgets
// =============================================================================

class _TopBar extends StatelessWidget {
  final String rideType;
  final bool isCancelling;
  final VoidCallback? onCancel;

  const _TopBar({
    required this.rideType,
    required this.isCancelling,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        GestureDetector(
          onTap: onCancel,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: isCancelling
                ? const Padding(
                    padding: EdgeInsets.all(9),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.close_rounded,
                    size: 18, color: AppColors.textSecondary),
          ),
        ),
        Text(rideType, style: AppTextStyles.heading4),
        const SizedBox(width: 36),
      ],
    );
  }
}

class _PulsingRing extends StatelessWidget {
  final AnimationController controller;
  const _PulsingRing({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        return Stack(
          alignment: Alignment.center,
          children: [
            Transform.scale(
              scale: 1.0 + (controller.value * 0.4),
              child: Container(
                width: 140,
                height: 140,
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
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withValues(
                    alpha: (1.0 - controller.value) * 0.15,
                  ),
                ),
              ),
            ),
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.directions_car_rounded,
                color: AppColors.background,
                size: 36,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SearchingLabel extends StatelessWidget {
  final int dotsCount;
  final String rideType;
  const _SearchingLabel({required this.dotsCount, required this.rideType});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          'Finding your driver${'.' * dotsCount}',
          style: AppTextStyles.heading2,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Looking for nearby $rideType drivers',
          style: AppTextStyles.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _TripSummaryCard extends StatelessWidget {
  final String destination;
  final String fare;
  const _TripSummaryCard({required this.destination, required this.fare});

  @override
  Widget build(BuildContext context) {
    return Container(
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
            iconColor: AppColors.primary,
            label: 'Going to',
            value: destination,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 0.5, color: AppColors.border),
          ),
          _SummaryRow(
            icon: Icons.account_balance_wallet_rounded,
            iconColor: AppColors.success,
            label: 'Estimated fare',
            value: fare,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 0.5, color: AppColors.border),
          ),
          const _SummaryRow(
            icon: Icons.credit_card_rounded,
            iconColor: AppColors.info,
            label: 'Payment',
            value: 'CTSRide Wallet',
          ),
        ],
      ),
    );
  }
}

class _CancelButton extends StatelessWidget {
  final bool isCancelling;
  final VoidCallback? onTap;
  const _CancelButton({required this.isCancelling, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.errorLight,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.2)),
        ),
        child: isCancelling
            ? const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.error,
                  ),
                ),
              )
            : const Text(
                'Cancel request',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.error,
                ),
                textAlign: TextAlign.center,
              ),
      ),
    );
  }
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
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: AppTextStyles.bodySmall)),
        Text(
          value,
          style: AppTextStyles.labelLarge,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}