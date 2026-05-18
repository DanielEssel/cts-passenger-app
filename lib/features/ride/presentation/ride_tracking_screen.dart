// features/ride/screens/ride_tracking_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';
import 'trip_complete_screen.dart';

// ---------------------------------------------------------------------------
// Trip status — matches Firestore string values exactly
// ---------------------------------------------------------------------------

enum _TripStatus {
  searching,
  pending,
  driverArrived,
  inProgress,
  arriving,
  completed,
  cancelledByDriver,
  cancelledByPassenger,
  unknown;

  static _TripStatus fromString(String value) => switch (value) {
        'searching' => searching,
        'pending' => pending,
        'driverArrived' => driverArrived,
        'inProgress' => inProgress,
        'arriving' => arriving,
        'completed' => completed,
        'cancelledByDriver' => cancelledByDriver,
        'cancelledByPassenger' => cancelledByPassenger,
        _ => unknown,
      };

  /// Maps Firestore status → 0-based step index for the progress stepper.
  int get stepIndex => switch (this) {
        pending => 0,
        driverArrived => 1,
        inProgress => 2,
        arriving => 3,
        _ => 0,
      };
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class RideTrackingScreen extends StatefulWidget {
  final String tripId;
  final String rideType;
  final String destination;
  final String fare;
  final String driverName;
  final double driverRating;
  final String driverPlate;
  final String eta;
  final String? driverPhone; // optional — used for call/SMS

  const RideTrackingScreen({
    super.key,
    required this.tripId,
    required this.rideType,
    required this.destination,
    required this.fare,
    required this.driverName,
    required this.driverRating,
    required this.driverPlate,
    required this.eta,
    this.driverPhone,
  });

  @override
  State<RideTrackingScreen> createState() => _RideTrackingScreenState();
}

class _RideTrackingScreenState extends State<RideTrackingScreen> {
  StreamSubscription<DocumentSnapshot>? _tripSubscription;

  _TripStatus _status = _TripStatus.pending;
  String _eta = '';
  bool _isCancelling = false;
  bool _isNavigatingToComplete = false;

  // Step metadata — purely presentational
  static const _steps = [
    (
      label: 'Driver on the way',
      sub: 'Your driver is heading to pickup',
      icon: Icons.directions_car_rounded,
      color: AppColors.info,
    ),
    (
      label: 'Driver arrived',
      sub: 'Your driver is at the pickup point',
      icon: Icons.location_on_rounded,
      color: AppColors.warning,
    ),
    (
      label: 'On the way',
      sub: 'Sit back and enjoy the ride',
      icon: Icons.electric_bolt_rounded,
      color: AppColors.primary,
    ),
    (
      label: 'Arriving soon',
      sub: 'Almost at your destination',
      icon: Icons.flag_rounded,
      color: AppColors.success,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _eta = widget.eta;

    // ✅ SystemChrome once, not in build()
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

    _listenToTripUpdates();
  }

  @override
  void dispose() {
    _tripSubscription?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Firestore listener
  // ---------------------------------------------------------------------------

  void _listenToTripUpdates() {
    _tripSubscription = FirebaseFirestore.instance
        .collection('trips')
        .doc(widget.tripId)
        .snapshots()
        .listen((snap) {
      if (!mounted || !snap.exists) return;

      final data = snap.data()!;
      final newStatus = _TripStatus.fromString(data['status'] as String? ?? '');
      final newEta = data['eta'] as String? ?? _eta;

      setState(() {
        _status = newStatus;
        _eta = newEta;
      });

      if (newStatus == _TripStatus.completed) {
        _navigateToTripComplete(data);
      } else if (newStatus == _TripStatus.cancelledByDriver) {
        _showDriverCancelledDialog();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _navigateToTripComplete(Map<String, dynamic> data) {
    if (!mounted || _isNavigatingToComplete) return;
    _isNavigatingToComplete = true;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
          builder: (_) => TripCompleteScreen(
                tripId: widget.tripId,
                driverId: data['driverId'] as String? ??
                    '', // ← from Firestore trip doc
                driverName: widget.driverName,
                driverRating: widget.driverRating,
                destination: widget.destination,
                fare: data['actualFare'] != null
                    ? 'GHS ${(data['actualFare'] as num).toStringAsFixed(0)}'
                    : widget.fare,
                rideType: widget.rideType,
              )),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _callDriver() async {
    final phone = widget.driverPhone;
    if (phone == null || phone.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _messageDriver() async {
    final phone = widget.driverPhone;
    if (phone == null || phone.isEmpty) return;
    final uri = Uri(scheme: 'sms', path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _shareTrip() {
    Share.share(
      'I\'m on my way to ${widget.destination}. '
      'Track my trip: https://ctstrip.app/track/${widget.tripId}',
      subject: 'My CTSRide trip',
    );
  }

  Future<void> _cancelRide() async {
    if (_isCancelling) return;
    setState(() => _isCancelling = true);

    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(widget.tripId)
          .update({
        'status': 'cancelledByPassenger',
        'cancelledAt': FieldValue.serverTimestamp(),
        'cancellationReason': 'Cancelled by passenger during ride',
      });

      if (mounted) {
        Navigator.pop(context); // close dialog
        Navigator.pop(context); // back to booking
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not cancel. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Dialogs / sheets
  // ---------------------------------------------------------------------------

  void _showCancelDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Cancel ride?', style: AppTextStyles.heading3),
        content: const Text(
          'Cancelling after a driver has been assigned may incur a small fee.',
          style: AppTextStyles.bodySmall,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Keep ride',
              style: AppTextStyles.bodySmall
                  .copyWith(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: _isCancelling ? null : _cancelRide,
            child: Text(
              'Cancel ride',
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
            ),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Driver Cancelled'),
        content: const Text(
          'The driver cancelled your trip. Please book again.',
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

  void _showSOSSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SOSSheet(tripId: widget.tripId),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final stepIndex = _status.stepIndex;
    final currentStep = _steps[stepIndex];

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _MapOverlay(
            statusLabel: currentStep.label,
            statusIcon: currentStep.icon,
            eta: _eta,
          ),
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _StatusStepper(currentStep: stepIndex, steps: _steps),
                    const SizedBox(height: 16),
                    _DriverCard(
                      driverName: widget.driverName,
                      driverRating: widget.driverRating,
                      driverPlate: widget.driverPlate,
                      rideType: widget.rideType,
                      destination: widget.destination,
                      fare: widget.fare,
                    ),
                    const SizedBox(height: 12),
                    _ActionButtonRow(
                      onCall: _callDriver,
                      onMessage: _messageDriver,
                      onShare: _shareTrip,
                      onCancel: () => _showCancelDialog(),
                    ),
                    const SizedBox(height: 12),
                    _SOSButton(onTap: _showSOSSheet),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Sub-widgets
// =============================================================================

class _MapOverlay extends StatelessWidget {
  final String statusLabel;
  final IconData statusIcon;
  final String eta;

  const _MapOverlay({
    required this.statusLabel,
    required this.statusIcon,
    required this.eta,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const MapPlaceholder(height: 280, showRoute: true),
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Icon(statusIcon, color: AppColors.background, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    statusLabel,
                    style: AppTextStyles.labelLarge
                        .copyWith(color: AppColors.background),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    eta,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.background),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusStepper extends StatelessWidget {
  final int currentStep;
  final List<({String label, String sub, IconData icon, Color color})> steps;

  const _StatusStepper({
    required this.currentStep,
    required this.steps,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: List.generate(steps.length, (i) {
          final isDone = i < currentStep;
          final isCurrent = i == currentStep;
          return Expanded(
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: isDone
                        ? AppColors.success
                        : isCurrent
                            ? AppColors.primary
                            : AppColors.surfaceAlt,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isDone
                          ? AppColors.success
                          : isCurrent
                              ? AppColors.primary
                              : AppColors.border,
                    ),
                  ),
                  child: Icon(
                    isDone ? Icons.check_rounded : steps[i].icon,
                    size: 12,
                    color: isDone || isCurrent
                        ? AppColors.background
                        : AppColors.textTertiary,
                  ),
                ),
                if (i < steps.length - 1)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: isDone ? AppColors.success : AppColors.border,
                    ),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _DriverCard extends StatelessWidget {
  final String driverName;
  final double driverRating;
  final String driverPlate;
  final String rideType;
  final String destination;
  final String fare;

  const _DriverCard({
    required this.driverName,
    required this.driverRating,
    required this.driverPlate,
    required this.rideType,
    required this.destination,
    required this.fare,
  });

  /// ✅ Safe initials — never crashes on short names
  String get _initials {
    final parts = driverName.trim().split(' ');
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

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
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: AppColors.primary,
                child: Text(
                  _initials,
                  style: AppTextStyles.heading4
                      .copyWith(color: AppColors.background),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(driverName, style: AppTextStyles.heading4),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded,
                            color: AppColors.warning, size: 14),
                        const SizedBox(width: 4),
                        Text('$driverRating', style: AppTextStyles.bodySmall),
                        const SizedBox(width: 8),
                        const Text('·', style: AppTextStyles.bodySmall),
                        const SizedBox(width: 8),
                        Text(rideType, style: AppTextStyles.bodySmall),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.darkNavy,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  driverPlate,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.background,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 0.5, color: AppColors.border),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.flag_rounded,
                  color: AppColors.primary, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  destination,
                  style: AppTextStyles.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                fare,
                style:
                    AppTextStyles.labelLarge.copyWith(color: AppColors.primary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionButtonRow extends StatelessWidget {
  final VoidCallback onCall;
  final VoidCallback onMessage;
  final VoidCallback onShare;
  final VoidCallback onCancel;

  const _ActionButtonRow({
    required this.onCall,
    required this.onMessage,
    required this.onShare,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ActionButton(
              icon: Icons.phone_rounded, label: 'Call', onTap: onCall),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ActionButton(
              icon: Icons.chat_bubble_rounded,
              label: 'Message',
              onTap: onMessage),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ActionButton(
              icon: Icons.share_rounded, label: 'Share trip', onTap: onShare),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ActionButton(
            icon: Icons.close_rounded,
            label: 'Cancel',
            color: AppColors.errorLight,
            iconColor: AppColors.error,
            onTap: onCancel,
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final Color? iconColor;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color ?? AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Icon(icon, color: iconColor ?? AppColors.textSecondary, size: 20),
            const SizedBox(height: 4),
            Text(label,
                style: AppTextStyles.caption, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _SOSButton extends StatelessWidget {
  final VoidCallback onTap;
  const _SOSButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.errorLight,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.emergency_rounded, color: AppColors.error, size: 18),
            SizedBox(width: 8),
            Text(
              'SOS Emergency',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SOSSheet extends StatelessWidget {
  final String tripId;
  const _SOSSheet({required this.tripId});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          const Icon(Icons.emergency_rounded, color: AppColors.error, size: 40),
          const SizedBox(height: 12),
          const Text('Emergency options', style: AppTextStyles.heading3),
          const SizedBox(height: 20),
          _SOSOption(
            icon: Icons.local_police_rounded,
            label: 'Call Police (191)',
            onTap: () async {
              Navigator.pop(context);
              final uri = Uri(scheme: 'tel', path: '191');
              if (await canLaunchUrl(uri)) await launchUrl(uri);
            },
          ),
          _SOSOption(
            icon: Icons.local_hospital_rounded,
            label: 'Call Ambulance (193)',
            onTap: () async {
              Navigator.pop(context);
              final uri = Uri(scheme: 'tel', path: '193');
              if (await canLaunchUrl(uri)) await launchUrl(uri);
            },
          ),
          _SOSOption(
            icon: Icons.people_rounded,
            label: 'Share trip with emergency contact',
            onTap: () {
              Navigator.pop(context);
              Share.share(
                'I need help. My trip ID is $tripId. '
                'Track me at: https://ctstrip.app/track/$tripId',
                subject: 'Emergency — CTSRide trip',
              );
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SOSOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SOSOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.errorLight,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.error, size: 20),
            const SizedBox(width: 12),
            Text(
              label,
              style: AppTextStyles.labelLarge.copyWith(color: AppColors.error),
            ),
          ],
        ),
      ),
    );
  }
}
