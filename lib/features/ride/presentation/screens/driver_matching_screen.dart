// lib/features/ride/presentation/driver_matching_screen.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cts_transport_app/core/constants/app_colors.dart';
import 'package:cts_transport_app/core/routes/app_routes.dart';
import 'package:cts_transport_app/features/ride/constants/ride_constants.dart';

class DriverMatchingScreen extends StatefulWidget {
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
  State<DriverMatchingScreen> createState() => _DriverMatchingScreenState();
}

class _DriverMatchingScreenState extends State<DriverMatchingScreen>
    with SingleTickerProviderStateMixin {

  late final AnimationController _pulseController;
  late final Animation<double>   _pulseAnim;

  StreamSubscription<DocumentSnapshot>? _tripSub;
  Timer? _timeoutTimer;

  int    _searchSeconds   = 0;
  bool   _isCancelling    = false;
  String _driverName      = '';
  String _driverVehicle   = '';
  bool   _driverFound     = false;

  @override
  void initState() {
    super.initState();

    // Pulse animation
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 0.85, end: 1.15)
        .animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));

    // Start listening + countdown
    _startListening();
    _startCountdown();
  }

  // ── Firestore listener ────────────────────────────────────────────────────

  void _startListening() {
    _tripSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(widget.tripId)
        .snapshots()
        .listen(_onTripSnapshot, onError: (_) {});
  }

  void _onTripSnapshot(DocumentSnapshot snap) async {
    if (!snap.exists || !mounted) return;

    final data     = snap.data() as Map<String, dynamic>;
    final status   = data['status'] as String? ?? '';
    final driverId = data['driverId'] as String?;

    if (status == 'cancelled') {
      _navigateBack('Trip was cancelled');
      return;
    }

    if (driverId != null && !_driverFound) {
      _driverFound = true;
      _timeoutTimer?.cancel();
      HapticFeedback.heavyImpact();

      // Fetch driver details
      try {
        final driverDoc = await FirebaseFirestore.instance
            .collection('drivers')
            .doc(driverId)
            .get();
        if (driverDoc.exists && mounted) {
          final d = driverDoc.data()!;
          setState(() {
            _driverName    = d['displayName'] as String? ?? 'Your driver';
            _driverVehicle = '${d['vehicleColor'] ?? ''} ${d['vehicleMake'] ?? ''} · ${d['plateNumber'] ?? ''}'.trim();
          });
        }
      } catch (_) {}

      // Brief delay so the driver found state is visible
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) _goToTracking();
    }
  }

  // ── Countdown ─────────────────────────────────────────────────────────────

  void _startCountdown() {
    Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _searchSeconds++);

      if (_searchSeconds >= RideConstants.driverSearchTimeout.inSeconds) {
        t.cancel();
        _onSearchTimeout();
      }
    });

    _timeoutTimer = Timer(RideConstants.driverSearchTimeout, () {});
  }

  void _onSearchTimeout() {
    if (!mounted || _driverFound) return;
    _cancelTrip(reason: 'No drivers available nearby. Please try again.');
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _cancelTrip({String? reason}) async {
    if (_isCancelling) return;
    setState(() => _isCancelling = true);

    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(widget.tripId)
          .update({
        'status':      'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
        'cancelReason': reason ?? 'Cancelled by passenger',
      });
    } catch (_) {}

    if (mounted) {
      _navigateBack(reason ?? 'Trip cancelled');
    }
  }

  void _goToTracking() {
    Navigator.pushReplacementNamed(
      context,
      AppRoutes.rideTracking,
      arguments: {'rideId': widget.tripId},
    );
  }

  void _navigateBack(String message) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.errorColor,
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // prevent back gesture
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 60),

                // ── Animation ──
                if (_driverFound)
                  _DriverFoundHeader(
                    driverName:    _driverName,
                    driverVehicle: _driverVehicle,
                  )
                else
                  _SearchingHeader(
                    pulseAnim:     _pulseAnim,
                    seconds:       _searchSeconds,
                    rideType:      widget.rideType,
                  ),

                const SizedBox(height: 40),

                // ── Trip info card ──
                _TripInfoCard(
                  destination: widget.destination,
                  fare:        widget.fare,
                  rideType:    widget.rideType,
                ),

                const Spacer(),

                // ── Cancel button ──
                if (!_driverFound)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _isCancelling
                          ? null
                          : () => _showCancelConfirm(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.errorColor,
                        side: const BorderSide(color: AppColors.errorColor),
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _isCancelling
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.errorColor,
                              ))
                          : const Text(
                              'Cancel Request',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                    ),
                  ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showCancelConfirm() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: const Text('Cancel request?'),
        content: const Text(
            'Are you sure you want to cancel this ride request?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep waiting'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _cancelTrip();
            },
            child: const Text('Yes, cancel',
                style: TextStyle(color: AppColors.errorColor)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _tripSub?.cancel();
    _timeoutTimer?.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SearchingHeader extends StatelessWidget {
  final Animation<double> pulseAnim;
  final int               seconds;
  final String            rideType;

  const _SearchingHeader({
    required this.pulseAnim,
    required this.seconds,
    required this.rideType,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          ScaleTransition(
            scale: pulseAnim,
            child: Container(
              width: 120, height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryColor.withValues(alpha: 0.1),
                border: Border.all(
                    color: AppColors.primaryColor.withValues(alpha: 0.3),
                    width: 2),
              ),
              child: const Icon(Icons.directions_car_rounded,
                  size: 56, color: AppColors.primaryColor),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Finding your $rideType...',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimaryColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Searching for ${seconds}s',
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondaryColor,
            ),
          ),
        ],
      );
}

class _DriverFoundHeader extends StatelessWidget {
  final String driverName;
  final String driverVehicle;

  const _DriverFoundHeader({
    required this.driverName,
    required this.driverVehicle,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Container(
            width: 100, height: 100,
            decoration: BoxDecoration(
              shape:      BoxShape.circle,
              color:      AppColors.successLight,
              border: Border.all(color: AppColors.success, width: 2),
            ),
            child: const Icon(Icons.check_rounded,
                size: 52, color: AppColors.success),
          ),
          const SizedBox(height: 20),
          const Text('Driver found!',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppColors.primaryColor,
              )),
          const SizedBox(height: 6),
          Text(
            driverName.isNotEmpty ? driverName : 'Your driver is on the way',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimaryColor,
            ),
          ),
          if (driverVehicle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              driverVehicle,
              style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondaryColor),
            ),
          ],
        ],
      );
}

class _TripInfoCard extends StatelessWidget {
  final String destination;
  final String fare;
  final String rideType;

  const _TripInfoCard({
    required this.destination,
    required this.fare,
    required this.rideType,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderColor),
        ),
        child: Column(
          children: [
            _InfoRow(
              icon:  Icons.location_on_rounded,
              color: AppColors.errorColor,
              label: 'Going to',
              value: destination,
            ),
            const Divider(height: 16, color: AppColors.borderColor),
            _InfoRow(
              icon:  Icons.payments_rounded,
              color: AppColors.primaryColor,
              label: 'Fare',
              value: fare,
            ),
            const Divider(height: 16, color: AppColors.borderColor),
            _InfoRow(
              icon:  Icons.directions_car_rounded,
              color: AppColors.textSecondaryColor,
              label: 'Ride type',
              value: rideType,
            ),
          ],
        ),
      );
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final String   label;
  final String   value;

  const _InfoRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.textSecondaryColor,
                    )),
                Text(value,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimaryColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      );
}