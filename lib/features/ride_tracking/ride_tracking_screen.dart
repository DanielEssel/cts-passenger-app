// lib/features/ride_tracking/ride_tracking_screen.dart

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../widgets/common/glass_card.dart';
import '../ride/models/trip_request.dart';
import '../ride/providers/trip_providers.dart';



final singleTripProvider =
    StreamProvider.autoDispose.family<TripRequest?, String>((ref, tripId) {
  return FirebaseFirestore.instance
      .collection('trips')
      .doc(tripId)
      .snapshots()
      .map((doc) => doc.exists ? TripRequest.fromFirestore(doc) : null);
});

// ─────────────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────────────

class RideTrackingScreen extends ConsumerStatefulWidget {
  final String rideId;

  const RideTrackingScreen({super.key, required this.rideId});

  @override
  ConsumerState<RideTrackingScreen> createState() =>
      _RideTrackingScreenState();
}

class _RideTrackingScreenState extends ConsumerState<RideTrackingScreen> {
  GoogleMapController? _mapController;
  final Set<Marker>   _markers   = {};
  final Set<Polyline> _polylines = {};

  // Driver location subscription
  StreamSubscription<DocumentSnapshot>? _driverLocationSub;
  LatLng? _driverLatLng;

  @override
  void initState() {
    super.initState();
    _subscribeToDriverLocation();
  }

  // ── Driver location ────────────────────────────

  void _subscribeToDriverLocation() {
    _driverLocationSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(widget.rideId)
        .snapshots()
        .listen((doc) {
      if (!doc.exists || !mounted) return;
      final data = doc.data()!;
      final geo = data['driverCurrentLocation'] as GeoPoint?;
      if (geo == null) return;

      final latLng = LatLng(geo.latitude, geo.longitude);
      setState(() {
        _driverLatLng = latLng;
        _markers
          ..removeWhere((m) => m.markerId.value == 'driver')
          ..add(Marker(
            markerId: const MarkerId('driver'),
            position: latLng,
            icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueAzure),
            infoWindow: const InfoWindow(title: 'Your Driver'),
          ));
      });

      _mapController?.animateCamera(CameraUpdate.newLatLng(latLng));
    });
  }

  @override
  void dispose() {
    _driverLocationSub?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // ✅ singleTripProvider — correct family provider, keyed by rideId
    final tripAsync = ref.watch(singleTripProvider(widget.rideId));

    return Scaffold(
      body: tripAsync.when(
        data: (trip) {
          if (trip == null) {
            return const Center(child: Text('Trip not found'));
          }
          return _buildBody(trip);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  Widget _buildBody(TripRequest trip) {
    return Stack(
      children: [
        // ── Map ─────────────────────────────────
        GoogleMap(
          onMapCreated: (c) {
            _mapController = c;
            _updatePickupMarker(trip);
          },
          initialCameraPosition: CameraPosition(
            target: LatLng(
              trip.pickupLocation.latitude,
              trip.pickupLocation.longitude,
            ),
            zoom: 14,
          ),
          markers:             _markers,
          polylines:           _polylines,
          myLocationEnabled:   true,
          zoomControlsEnabled: false,
          mapToolbarEnabled:   false,
        ),

        // ── Status header ────────────────────────
        Positioned(
          top:   MediaQuery.of(context).padding.top + 12,
          left:  16,
          right: 16,
          child: _buildStatusHeader(trip),
        ),

        // ── Route timeline ───────────────────────
        Positioned(
          top:   MediaQuery.of(context).padding.top + 110,
          left:  16,
          right: 16,
          child: _buildTripTimeline(trip),
        ),

        // ── Bottom action card ───────────────────
        Positioned(
          bottom: 24,
          left:   16,
          right:  16,
          child:  _buildActionCard(trip),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────
  // MAP HELPERS
  // ─────────────────────────────────────────────

  void _updatePickupMarker(TripRequest trip) {
    final pickup = LatLng(
      trip.pickupLocation.latitude,
      trip.pickupLocation.longitude,
    );
    setState(() {
      _markers
        ..removeWhere((m) => m.markerId.value == 'pickup')
        ..add(Marker(
          markerId:  const MarkerId('pickup'),
          position:  pickup,
          icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueGreen),
          infoWindow: const InfoWindow(title: 'Pickup'),
        ));
    });
  }

  // ─────────────────────────────────────────────
  // STATUS HEADER
  // ─────────────────────────────────────────────

  Widget _buildStatusHeader(TripRequest trip) {
    // ✅ TripStatus — correct enum from trip_request.dart
    final (String text, IconData icon, Color color) = switch (trip.status) {
      TripStatus.searching     => ('Finding a driver…',   Icons.search,        Colors.orange),
      TripStatus.pending       => ('Driver on the way',   Icons.directions_car, Colors.blue),
      TripStatus.tripAccepted  => ('Driver assigned',     Icons.check_circle,   Colors.green),
      TripStatus.driverArrived => ('Driver has arrived',  Icons.location_on,    Colors.teal),
      TripStatus.tripStarted   => ('Trip in progress',    Icons.play_circle,    AppTheme.primaryColor),
      TripStatus.inProgress    => ('On your way',         Icons.navigation,     AppTheme.primaryColor),
      TripStatus.completed     => ('Trip completed',      Icons.flag,           Colors.purple),
      TripStatus.cancelled     => ('Trip cancelled',      Icons.cancel,         Colors.red),
      TripStatus.noDrivers     => ('No drivers nearby',   Icons.person_off,     Colors.grey),
    };

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            padding:    const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text,
                    style: AppTheme.titleSmall
                        .copyWith(fontWeight: FontWeight.bold)),
                if (trip.driverId != null)
                  Text(
                    'Driver: ${trip.metadata['driverName'] ?? 'Your driver'}',
                    style: AppTheme.bodySmall
                        .copyWith(color: Colors.grey[400]),
                  ),
              ],
            ),
          ),
          // Cancel button only while searching
          if (trip.status == TripStatus.searching)
            TextButton(
              onPressed: () => _confirmCancel(trip.id),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Cancel'),
            ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // TRIP TIMELINE
  // ─────────────────────────────────────────────

  Widget _buildTripTimeline(TripRequest trip) {
    final pickupDone = trip.status.index >= TripStatus.tripAccepted.index;
    final dropoffDone = trip.status == TripStatus.completed;

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          _TimelineItem(
            icon:        Icons.radio_button_checked,
            title:       'Pickup',
            address:     trip.pickupAddress,
            isCompleted: pickupDone,
          ),
          _TimelineConnector(
              isActive: trip.status.index >= TripStatus.tripStarted.index),
          _TimelineItem(
            icon:        Icons.flag_rounded,
            title:       'Drop-off',
            address:     trip.dropoffAddress,
            isCompleted: dropoffDone,
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // ACTION CARD
  // ─────────────────────────────────────────────

  Widget _buildActionCard(TripRequest trip) {
    // ── Completed ──────────────────────────────
    if (trip.status == TripStatus.completed) {
      final fare = trip.actualFare ?? trip.estimatedFare;
      return GlassCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total Fare',
                    style: AppTheme.bodyMedium
                        .copyWith(color: Colors.grey[400])),
                Text(
                  '₵${fare.toStringAsFixed(2)}',
                  style: AppTheme.titleLarge.copyWith(
                    color:      AppTheme.primaryColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _rateDriver(trip),
                    icon:  const Icon(Icons.star_border),
                    label: const Text('Rate Driver'),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _reportIssue(trip),
                    icon:  const Icon(Icons.report_problem),
                    label: const Text('Report Issue'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // ── Active trip ────────────────────────────
    if (trip.status == TripStatus.tripStarted ||
        trip.status == TripStatus.inProgress ||
        trip.status == TripStatus.driverArrived) {
      return GlassCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: _InfoTile(
                    icon:  Icons.timer_outlined,
                    label: 'ETA',
                    value: '${trip.metadata['eta'] ?? trip.estimatedDuration} min',
                  ),
                ),
                Container(
                    width: 1, height: 40, color: Colors.grey[800]),
                Expanded(
                  child: _InfoTile(
                    icon:  Icons.straighten,
                    label: 'Distance',
                    value: '${trip.distance.toStringAsFixed(1)} km',
                  ),
                ),
                Container(
                    width: 1, height: 40, color: Colors.grey[800]),
                Expanded(
                  child: _InfoTile(
                    icon:  Icons.payments_outlined,
                    label: 'Fare',
                    value: '₵${trip.estimatedFare.toStringAsFixed(2)}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _shareTrip(trip),
                    icon:  const Icon(Icons.share, size: 18),
                    label: const Text('Share'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _callDriver(trip),
                    icon:  const Icon(Icons.phone, size: 18),
                    label: const Text('Call Driver'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // ── Searching / pending — no card ─────────
    return const SizedBox.shrink();
  }

  // ─────────────────────────────────────────────
  // ACTIONS
  // ─────────────────────────────────────────────

  void _confirmCancel(String tripId) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title:   const Text('Cancel Trip?'),
        content: const Text(
            'Are you sure you want to cancel this trip?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep Trip'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context); // close dialog
              // ✅ tripRequestManagerProvider — correct provider name
              await ref
                  .read(tripRequestManagerProvider.notifier)
                  .cancelTrip(tripId);
              if (mounted) Navigator.pop(context); // leave screen
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _callDriver(TripRequest trip) async {
    final phone = trip.metadata['driverPhone'] as String?;
    if (phone == null) return;
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _shareTrip(TripRequest trip) {
    // Share trip link / ETA with emergency contacts
    // Implement with share_plus package
  }

  void _rateDriver(TripRequest trip) {
    // Show star-rating bottom sheet
  }

  void _reportIssue(TripRequest trip) {
    // Show issue reporting form / navigate to support
  }
}

// ═══════════════════════════════════════════════
// SMALL REUSABLE WIDGETS
// ═══════════════════════════════════════════════

class _TimelineItem extends StatelessWidget {
  final IconData icon;
  final String   title;
  final String   address;
  final bool     isCompleted;

  const _TimelineItem({
    required this.icon,
    required this.title,
    required this.address,
    required this.isCompleted,
  });

  @override
  Widget build(BuildContext context) {
    final color = isCompleted ? AppTheme.primaryColor : Colors.grey[600]!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: AppTheme.bodySmall.copyWith(color: color)),
              Text(
                address,
                style:    AppTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TimelineConnector extends StatelessWidget {
  final bool isActive;

  const _TimelineConnector({required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
      child: Container(
        width:  2,
        height: 28,
        color:  isActive ? AppTheme.primaryColor : Colors.grey[800],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;

  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: AppTheme.primaryColor, size: 22),
        const SizedBox(height: 4),
        Text(label,
            style: AppTheme.bodySmall
                .copyWith(color: Colors.grey[400])),
        Text(value, style: AppTheme.titleSmall),
      ],
    );
  }
}