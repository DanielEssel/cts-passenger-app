// lib/features/ride_tracking/ride_tracking_screen.dart
import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ride/presentation/trip_complete_screen.dart';
import '../ride/services/route_service.dart';
import 'package:cts_transport_app/core/services/marker_service.dart';

const _kPrimary = Color(0xFF16A34A);
const _kAccra = LatLng(5.6037, -0.1870);

enum _TripStatus {
  searching,
  tripAccepted,
  driverArrived,
  tripStarted,
  completed,
  cancelledByDriver,
  cancelledByPassenger,
  unknown;

  static _TripStatus fromString(String? v) => switch (v) {
        'searching' => searching,
        'tripAccepted' => tripAccepted,
        'driverArrived' => driverArrived,
        'tripStarted' => tripStarted,
        'inProgress' => tripStarted,
        'completed' => completed,
        'cancelledByDriver' => cancelledByDriver,
        'cancelledByPassenger' => cancelledByPassenger,
        _ => unknown,
      };

  int get stepIndex => switch (this) {
        tripAccepted => 0,
        driverArrived => 1,
        tripStarted => 2,
        completed => 3,
        _ => 0,
      };

  bool get isTerminal =>
      this == completed ||
      this == cancelledByDriver ||
      this == cancelledByPassenger;
}

class RideTrackingScreen extends StatefulWidget {
  final String tripId;
  const RideTrackingScreen({super.key, required this.tripId});

  @override
  State<RideTrackingScreen> createState() => _RideTrackingScreenState();
}

class _RideTrackingScreenState extends State<RideTrackingScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic> _tripData = {};
  _TripStatus _status = _TripStatus.tripAccepted;
  bool _isLoading = true;

  GoogleMapController? _mapController;
  LatLng? _driverLatLng;
  LatLng? _pickupLatLng;
  LatLng? _dropoffLatLng;

  final _routeService = RouteService();
  Set<Polyline> _routePolyline = {};
  bool _routeFetched = false;

  bool _mapReady = false;

  bool _isCancelling = false;
  bool _isNavigatingToComplete = false;

  StreamSubscription<DocumentSnapshot>? _tripSub;

  static const _mapStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#f5f5f5"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#ffffff"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#e8f5e9"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#b3d9f2"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#d8f0e4"}]}
]
''';

  static const _steps = [
    (
      label: 'Driver on the way',
      icon: Icons.directions_car_rounded,
      color: _kPrimary
    ),
    (
      label: 'Driver arrived',
      icon: Icons.location_on_rounded,
      color: Colors.orange
    ),
    (
      label: 'Trip in progress',
      icon: Icons.electric_bolt_rounded,
      color: Colors.blue
    ),
    (label: 'Completed', icon: Icons.flag_rounded, color: Colors.purple),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMarkers());
    _subscribeToTrip();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refitMap();
  }

  Future<void> _loadMarkers() async {
    await MarkerService.instance.warmUp(context);
    if (mounted) setState(() {});
  }

  void _subscribeToTrip() {
    _tripSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(widget.tripId)
        .snapshots()
        .listen((snap) {
      if (!snap.exists || !mounted) return;
      final data = snap.data()!;
      final newStatus = _TripStatus.fromString(data['status'] as String?);
      final geo = data['driverCurrentLocation'] as GeoPoint?;
      final pickup = data['pickupLocation'] as GeoPoint?;
      final dropoff = data['dropoffLocation'] as GeoPoint?;

      setState(() {
        _tripData = data;
        _status = newStatus;
        _isLoading = false;
        if (geo != null) _driverLatLng = LatLng(geo.latitude, geo.longitude);
        if (pickup != null) {
          _pickupLatLng = LatLng(pickup.latitude, pickup.longitude);
        }
        if (dropoff != null) {
          _dropoffLatLng = LatLng(dropoff.latitude, dropoff.longitude);
        }
      });

      _fetchRoute();

      if (_driverLatLng != null && _mapReady) {
        _mapController?.animateCamera(CameraUpdate.newLatLng(_driverLatLng!));
      }

      if (newStatus == _TripStatus.completed) _navigateToComplete(data);
      if (newStatus == _TripStatus.cancelledByDriver) {
        _showDriverCancelledDialog();
      }
    });
  }

  void _refitMap() {
    if (!_mapReady || _pickupLatLng == null || _dropoffLatLng == null) return;
    final sw = LatLng(
      min(_pickupLatLng!.latitude, _dropoffLatLng!.latitude),
      min(_pickupLatLng!.longitude, _dropoffLatLng!.longitude),
    );
    final ne = LatLng(
      max(_pickupLatLng!.latitude, _dropoffLatLng!.latitude),
      max(_pickupLatLng!.longitude, _dropoffLatLng!.longitude),
    );
    _mapController?.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: sw, northeast: ne), 80));
  }

  Future<void> _fetchRoute() async {
    if (_routeFetched || _pickupLatLng == null || _dropoffLatLng == null) {
      return;
    }
    _routeFetched = true;
    final result =
        await _routeService.getRoute(_pickupLatLng!, _dropoffLatLng!);
    if (result != null && result.points.isNotEmpty && mounted) {
      setState(() {
        _routePolyline = {
          Polyline(
            polylineId: const PolylineId('route'),
            points: result.points,
            color: _kPrimary,
            width: 4,
          ),
        };
      });
    }
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{};
    final ms = MarkerService.instance;
    final serviceType = _tripData['serviceType'] as String?;

    if (_pickupLatLng != null) {
      markers.add(Marker(
        markerId:   const MarkerId('pickup'),
        position:   _pickupLatLng!,
        icon:       ms.pickup(),
        anchor:     const Offset(0.5, 1.0),   // pin tip on coord
        infoWindow: const InfoWindow(title: 'Pickup'),
      ));
    }
    if (_dropoffLatLng != null) {
      markers.add(Marker(
        markerId:   const MarkerId('dropoff'),
        position:   _dropoffLatLng!,
        icon:       ms.dropoff(),
        anchor:     const Offset(0.5, 1.0),
        infoWindow: const InfoWindow(title: 'Drop-off'),
      ));
    }
    if (_driverLatLng != null) {
      markers.add(Marker(
        markerId:   const MarkerId('driver'),
        position:   _driverLatLng!,
        icon:       ms.vehicle(serviceType),
        anchor:     const Offset(0.5, 0.5),   // vehicle centered on coord
        rotation:   (_tripData['driverHeading'] as num?)?.toDouble() ?? 0,
        flat:       true,                      // flat = rotates with map/heading
        infoWindow: InfoWindow(title: _tripData['driverName'] as String? ?? 'Driver'),
      ));
    }
    return markers;
  }

  void _navigateToComplete(Map<String, dynamic> data) {
    if (!mounted || _isNavigatingToComplete) return;
    _isNavigatingToComplete = true;

    final fare = data['actualFare'] != null
        ? 'GHS ${(data["actualFare"] as num).toStringAsFixed(2)}'
        : 'GHS ${(data["estimatedFare"] as num? ?? 0).toStringAsFixed(2)}';

    // ── Passenger confirmation dialog ─────────────────────────────────────
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.flag_rounded,
                    color: Color(0xFF16A34A), size: 32),
              ),
              const SizedBox(height: 16),
              const Text('Have you arrived?',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  )),
              const SizedBox(height: 8),
              Text(
                'Confirm you reached your destination. $fare will be deducted from your wallet.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
              ),
              const SizedBox(height: 20),
              // Confirm button
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Yes, I arrived!',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      )),
                ),
              ),
              const SizedBox(height: 8),
              // Dispute button
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFFDC2626)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text("I didn't arrive — Report issue",
                      style: TextStyle(
                        color: Color(0xFFDC2626),
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      )),
                ),
              ),
            ],
          ),
        ),
      ).then((confirmed) async {
        if (!mounted) return;

        if (confirmed == true) {
          // ✅ Passenger confirmed — write to Firestore
          // This triggers onTripCompleted CF to process payment
          await FirebaseFirestore.instance
              .collection('trips')
              .doc(widget.tripId)
              .update({
            'passengerConfirmed': true,
            'passengerConfirmedAt': FieldValue.serverTimestamp(),
          });

          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => TripCompleteScreen(
                tripId: widget.tripId,
                driverId: data['driverId'] as String? ?? '',
                driverName: data['driverName'] as String? ?? 'Your driver',
                destination: data['dropoffAddress'] as String? ?? '',
                fare: fare,
                rideType: data['serviceType'] as String? ?? 'Ride',
                driverRating: (data['driverRating'] as num?)?.toDouble() ?? 5.0,
              ),
            ),
          );
        } else {
          // ❌ Passenger disputed — raise dispute
          await FirebaseFirestore.instance
              .collection('trips')
              .doc(widget.tripId)
              .update({
            'disputed': true,
            'disputedAt': FieldValue.serverTimestamp(),
            'disputeReason': 'Passenger did not confirm arrival',
          });

          // Write support ticket automatically
          final uid = FirebaseAuth.instance.currentUser?.uid;
          await FirebaseFirestore.instance.collection('supportTickets').add({
            'userId': uid,
            'userRole': 'passenger',
            'subject': 'Trip dispute — did not arrive at destination',
            'message':
                'Driver marked trip as complete but passenger did not arrive. Trip ID: \${widget.tripId}',
            'category': 'trip_dispute',
            'priority': 'high',
            'status': 'open',
            'tripId': widget.tripId,
            'createdAt': FieldValue.serverTimestamp(),
          });

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content:
                  Text('Dispute raised. Our team will review and contact you.'),
              backgroundColor: Color(0xFFDC2626),
              duration: Duration(seconds: 4),
            ),
          );

          // Navigate home after dispute
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) {
              Navigator.of(context, rootNavigator: true)
                  .pushNamedAndRemoveUntil('/shell', (_) => false);
            }
          });
        }
      });
    });
  }

  Future<void> _callDriver() async {
    final phone = _tripData['driverPhone'] as String?;
    if (phone == null || phone.isEmpty) {
      _snack('Driver phone not available.');
      return;
    }
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _messageDriver() async {
    final phone = _tripData['driverPhone'] as String?;
    if (phone == null || phone.isEmpty) {
      _snack('Driver phone not available.');
      return;
    }
    final uri = Uri(scheme: 'sms', path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _shareTrip() => Share.share(
        'I\'m on a CTSRide trip to ${_tripData['dropoffAddress'] ?? 'my destination'}. '
        'Track me: https://ctstrip.app/track/${widget.tripId}',
        subject: 'My CTSRide trip',
      );

  Future<void> _cancelRide() async {
    if (_isCancelling) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Cancel ride?',
            style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text(
            'Cancelling after a driver has been assigned may incur a fee.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep Ride')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Cancel Ride'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isCancelling = true);
    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(widget.tripId)
          .update({
        'status': 'cancelledByPassenger',
        'cancelledAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        Navigator.of(context, rootNavigator: true)
            .pushNamedAndRemoveUntil('/shell', (_) => false);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isCancelling = false);
        _snack('Could not cancel. Try again.', isError: true);
      }
    }
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red[700] : null,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ));
  }

  void _showDriverCancelledDialog() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16)),
              child:
                  const Icon(Icons.cancel_rounded, color: Colors.red, size: 32),
            ),
            const SizedBox(height: 16),
            const Text('Driver Cancelled',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Your driver cancelled. Please book again.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  if (context.mounted) {
                    Navigator.of(context, rootNavigator: true)
                        .pushNamedAndRemoveUntil('/shell', (_) => false);
                  }
                },
                style: FilledButton.styleFrom(
                    backgroundColor: _kPrimary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                child: const Text('Book Again'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSOSSheet() => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => _SOSSheet(tripId: widget.tripId),
      );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tripSub?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator(color: _kPrimary)));
    }

    return PopScope(
      canPop: _status.isTerminal,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _snack('Please wait for your trip to complete.');
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAF9),
        body: Column(
          children: [
            Expanded(
              flex: 55,
              child: Stack(
                children: [
                  GoogleMap(
                    style: _mapStyle,
                    onMapCreated: (c) {
                      _mapController = c;
                      setState(() => _mapReady = true);
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => _refitMap());
                    },
                    initialCameraPosition: CameraPosition(
                        target: _pickupLatLng ?? _kAccra, zoom: 14),
                    markers: _buildMarkers(),
                    polylines: _routePolyline,
                    myLocationEnabled: true,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                    mapToolbarEnabled: false,
                    compassEnabled: false,
                  ),
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 12,
                    right: 16,
                    child: _MapBtn(
                        icon: Icons.my_location_rounded,
                        color: _kPrimary,
                        onTap: _refitMap),
                  ),
                  Positioned(
                      bottom: 0, left: 0, right: 0, child: _buildStatusBar()),
                ],
              ),
            ),
            Expanded(
              flex: 45,
              child: Container(
                color: Colors.white,
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                      20, 0, 20, MediaQuery.of(context).padding.bottom + 16),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      _buildStepper(),
                      const SizedBox(height: 16),
                      _buildDriverCard(),
                      const SizedBox(height: 12),
                      _buildActionRow(),
                      const SizedBox(height: 12),
                      _buildSOSButton(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    final (color, icon, label) = switch (_status) {
      _TripStatus.tripAccepted => (
          _kPrimary,
          Icons.directions_car_rounded,
          'Driver is on the way'
        ),
      _TripStatus.driverArrived => (
          Colors.orange,
          Icons.location_on_rounded,
          'Driver has arrived'
        ),
      _TripStatus.tripStarted => (
          Colors.blue,
          Icons.electric_bolt_rounded,
          'Trip in progress'
        ),
      _TripStatus.completed => (
          Colors.purple,
          Icons.flag_rounded,
          'Trip completed'
        ),
      _TripStatus.cancelledByDriver => (
          Colors.red,
          Icons.cancel_rounded,
          'Cancelled by driver'
        ),
      _TripStatus.cancelledByPassenger => (
          Colors.red,
          Icons.cancel_rounded,
          'Cancelled'
        ),
      _ => (_kPrimary, Icons.search_rounded, 'Finding driver...'),
    };
    final eta = _tripData['eta'] as String?;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
          color: color,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14))),
          if (eta != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(20)),
              child: Text(eta,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _buildStepper() {
    final step = _status.stepIndex;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE5E7EB))),
      child: Row(
        children: List.generate(_steps.length, (i) {
          final done = i < step;
          final current = i == step;
          return Expanded(
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: done
                        ? _kPrimary
                        : current
                            ? _steps[i].color
                            : const Color(0xFFF3F4F6),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: done || current
                            ? Colors.transparent
                            : const Color(0xFFD1D5DB)),
                  ),
                  child: Icon(done ? Icons.check_rounded : _steps[i].icon,
                      size: 12,
                      color: done || current
                          ? Colors.white
                          : const Color(0xFF9CA3AF)),
                ),
                if (i < _steps.length - 1)
                  Expanded(
                      child: Container(
                          height: 2,
                          color: done ? _kPrimary : const Color(0xFFE5E7EB))),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildDriverCard() {
    final name = _tripData['driverName'] as String? ?? 'Your Driver';
    final rating = (_tripData['driverRating'] as num?)?.toDouble() ?? 5.0;
    final plate = _tripData['driverPlate'] as String? ?? '';
    final svcType = _tripData['serviceType'] as String? ?? 'Ride';
    final dest = _tripData['dropoffAddress'] as String? ?? '';
    final fare = (_tripData['estimatedFare'] as num?)?.toDouble() ?? 0.0;
    final parts = name.trim().split(' ');
    final initials = parts.length >= 2
        ? '${parts.first[0]}${parts.last[0]}'.toUpperCase()
        : name.isNotEmpty
            ? name[0].toUpperCase()
            : 'D';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE5E7EB))),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                  radius: 26,
                  backgroundColor: _kPrimary,
                  child: Text(initials,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    Row(children: [
                      const Icon(Icons.star_rounded,
                          color: Color(0xFFFFB74D), size: 14),
                      const SizedBox(width: 3),
                      Text(rating.toStringAsFixed(1),
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF6B7280))),
                      const SizedBox(width: 8),
                      Text('· $svcType',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF6B7280))),
                    ]),
                  ],
                ),
              ),
              if (plate.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: const Color(0xFF1F2937),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(plate,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 1)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFF3F4F6)),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.flag_rounded, color: _kPrimary, size: 16),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(dest,
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFF374151)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis)),
              Text('GHS ${fare.toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _kPrimary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow() => Row(
        children: [
          Expanded(
              child: _ActionBtn(
                  icon: Icons.phone_rounded,
                  label: 'Call',
                  onTap: _callDriver)),
          const SizedBox(width: 8),
          Expanded(
              child: _ActionBtn(
                  icon: Icons.chat_bubble_rounded,
                  label: 'Message',
                  onTap: _messageDriver)),
          const SizedBox(width: 8),
          Expanded(
              child: _ActionBtn(
                  icon: Icons.share_rounded,
                  label: 'Share',
                  onTap: _shareTrip)),
          const SizedBox(width: 8),
          Expanded(
              child: _ActionBtn(
                  icon: Icons.close_rounded,
                  label: 'Cancel',
                  color: Colors.red.withValues(alpha: 0.08),
                  iconColor: Colors.red,
                  onTap: _status.isTerminal ? null : _cancelRide)),
        ],
      );

  Widget _buildSOSButton() => GestureDetector(
        onTap: _showSOSSheet,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
          ),
          child:
              const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.emergency_rounded, color: Colors.red, size: 18),
            SizedBox(width: 8),
            Text('SOS Emergency',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.red)),
          ]),
        ),
      );
}

class _MapBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _MapBtn({required this.icon, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 8,
                    offset: const Offset(0, 2))
              ]),
          child: Icon(icon, color: color, size: 20),
        ),
      );
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final Color? iconColor;
  const _ActionBtn(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.color,
      this.iconColor});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedOpacity(
          opacity: onTap == null ? 0.4 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: color ?? const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Column(children: [
              Icon(icon, color: iconColor ?? const Color(0xFF6B7280), size: 20),
              const SizedBox(height: 4),
              Text(label,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6B7280)),
                  textAlign: TextAlign.center),
            ]),
          ),
        ),
      );
}

class _SOSSheet extends StatelessWidget {
  final String tripId;
  const _SOSSheet({required this.tripId});
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 12, 24, MediaQuery.of(context).padding.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 20),
            Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16)),
                child: const Icon(Icons.emergency_rounded,
                    color: Colors.red, size: 32)),
            const SizedBox(height: 12),
            const Text('Emergency',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Select an option below',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 20),
            _SOSOption(
                icon: Icons.local_police_rounded,
                label: 'Call Police (191)',
                onTap: () async {
                  Navigator.pop(context);
                  final uri = Uri(scheme: 'tel', path: '191');
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                }),
            _SOSOption(
                icon: Icons.local_hospital_rounded,
                label: 'Call Ambulance (193)',
                onTap: () async {
                  Navigator.pop(context);
                  final uri = Uri(scheme: 'tel', path: '193');
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                }),
            _SOSOption(
                icon: Icons.people_rounded,
                label: 'Share location with emergency contact',
                onTap: () {
                  Navigator.pop(context);
                  Share.share(
                      'I need help. Trip: $tripId. Track: https://ctstrip.app/track/$tripId',
                      subject: 'Emergency — CTSRide');
                }),
          ],
        ),
      );
}

class _SOSOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SOSOption(
      {required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.red.withValues(alpha: 0.15)),
          ),
          child: Row(children: [
            Icon(icon, color: Colors.red, size: 20),
            const SizedBox(width: 12),
            Text(label,
                style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.red,
                    fontSize: 14)),
          ]),
        ),
      );
}
