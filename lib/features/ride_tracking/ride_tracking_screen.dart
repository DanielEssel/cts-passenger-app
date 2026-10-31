// lib/features/ride_tracking/ride_tracking_screen.dart
//
// The passenger's live ride screen. What it says and offers comes only from
// the trip's stored status (rideTrackingView): one plain headline, whether
// the passenger needs to act, named progress, the driver's real details and
// an honest note on how current the driver's position is. Ended, unknown
// and missing trips get their own screen with no tracking controls.
import 'dart:async';
import 'dart:math';

import '../../core/utils/smooth_marker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/utils/phone_launcher.dart';
import '../../core/theme/cts_theme.dart';
import '../../core/widgets/cts_ui.dart';

import '../ride/presentation/trip_complete_screen.dart';
import '../ride/services/route_service.dart';
import '../tracking/domain/tracking_view.dart';
import '../tracking/domain/trip_completion.dart';
import '../tracking/widgets/arrival_prompt.dart';
import '../tracking/widgets/passenger_tracking_panel.dart';
import 'package:cts_transport_app/core/services/marker_service.dart';

const _kPrimary = CtsTheme.primary;
const _kAccra = LatLng(5.6037, -0.1870);

class RideTrackingScreen extends StatefulWidget {
  final String tripId;
  const RideTrackingScreen({super.key, required this.tripId});

  @override
  State<RideTrackingScreen> createState() => _RideTrackingScreenState();
}

class _RideTrackingScreenState extends State<RideTrackingScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  Map<String, dynamic> _tripData = {};
  String? _rawStatus;
  bool _isLoading = true;
  bool _missing = false; // the trip document does not exist
  bool _loadFailed = false; // the trip could not be read

  TrackingView get _view => rideTrackingView(_rawStatus);
  bool get _headsToPickup => _view.heading == TrackingHeading.pickup;

  GoogleMapController? _mapController;
  LatLng? _driverLatLng; // current (animated) driver position
  LatLng? _pickupLatLng;
  LatLng? _dropoffLatLng;

  // ── Live driver marker ─────────────────────────
  late final SmoothMarker _driverAnim;
  final ValueNotifier<({LatLng pos, double bearing})?> _driverPose =
      ValueNotifier(null);
  LatLng? _driverTarget; // latest raw position from Firestore
  bool _follow = true; // camera follows until the user touches the map
  DateTime _lastCam = DateTime.fromMillisecondsSinceEpoch(0);

  // Fallback source so the driver appears as soon as the trip is accepted,
  // before the trip doc carries a live location.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _driverDocSub;
  String? _driverDocId;
  bool _tripHasLiveLoc = false;
  DateTime? _driverLocAt; // when the shown driver position was written

  // ── Route ──────────────────────────────────────
  final _routeService = RouteService();
  Set<Polyline> _routePolyline = {};
  String? _routeKey; // 'pickup' | 'dropoff' for the drawn route
  LatLng? _routeOrigin;
  bool _routeBusy = false;
  DateTime _lastRouteAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _mapReady = false;

  bool _isCancelling = false;
  bool _completionHandled = false;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);

    _driverAnim = SmoothMarker(
      vsync: this,
      onFrame: (pos, bearing) {
        _driverLatLng = pos;
        _driverPose.value = (pos: pos, bearing: bearing);
        _followCamera();
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMarkers());
    _subscribeToTrip();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _follow = true;
      _lastCam = DateTime.fromMillisecondsSinceEpoch(0);
      _fitTrip();
    }
  }

  Future<void> _loadMarkers() async {
    try {
      await MarkerService.instance.warmUp(context);
    } catch (e, st) {
      debugPrint('MarkerService.warmUp failed: $e\n$st');
    }
    if (mounted) setState(() {});
  }

  void _subscribeToTrip() {
    _tripSub?.cancel();
    _tripSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(widget.tripId)
        // Metadata changes too, so a cached first snapshot is always followed
        // by the server's copy, which decides what a completed trip shows.
        .snapshots(includeMetadataChanges: true)
        .listen((snap) {
      if (!mounted) return;
      if (!snap.exists) {
        setState(() {
          _missing = true;
          _isLoading = false;
        });
        return;
      }
      final data = snap.data()!;
      final prevStatus = _rawStatus;
      final newStatus = data['status'] as String?;
      final geo = data['driverCurrentLocation'] as GeoPoint?;
      final pickup = data['pickupLocation'] as GeoPoint?;
      final dropoff = data['dropoffLocation'] as GeoPoint?;

      setState(() {
        _tripData = data;
        _rawStatus = newStatus;
        _isLoading = false;
        _missing = false;
        _loadFailed = false;
        if (pickup != null) {
          _pickupLatLng = LatLng(pickup.latitude, pickup.longitude);
        }
        if (dropoff != null) {
          _dropoffLatLng = LatLng(dropoff.latitude, dropoff.longitude);
        }
        if (geo != null) _driverLocAt = readDriverLocationTime(data);
      });

      if (newStatus != prevStatus) {
        _follow = true;
        _lastCam = DateTime.fromMillisecondsSinceEpoch(0);
      }

      _tripHasLiveLoc = geo != null;
      if (geo != null) {
        _applyDriverLocation(
          LatLng(geo.latitude, geo.longitude),
          heading: (data['driverHeading'] as num?)?.toDouble(),
        );
      }

      _listenDriverDoc(data['driverId'] as String?);
      _syncRoute();

      if (newStatus == 'completed') {
        _onCompleted(data, fromCache: snap.metadata.isFromCache);
      }
    }, onError: (Object e) {
      debugPrint('Trip stream failed: $e');
      if (mounted) {
        setState(() {
          _loadFailed = true;
          _isLoading = false;
        });
      }
    });
  }

  void _applyDriverLocation(LatLng p, {double? heading}) {
    _driverTarget = p;
    _driverAnim.moveTo(p, heading: heading);
  }

  // Fallback: until the trip doc carries a live location, use the driver's
  // own document so the marker appears as soon as the trip is accepted.
  void _listenDriverDoc(String? driverId) {
    if (driverId == null || driverId.isEmpty || driverId == _driverDocId) {
      return;
    }
    _driverDocId = driverId;
    _driverDocSub?.cancel();
    _driverDocSub = FirebaseFirestore.instance
        .collection('drivers')
        .doc(driverId)
        .snapshots()
        .listen((s) {
      if (!mounted || _tripHasLiveLoc) return;
      final d = s.data();
      final g = (d?['location'] ?? d?['currentLocation']) as GeoPoint?;
      if (g == null) return;
      final at = readDriverLocationTime(d!) ??
          (d['lastSeen'] is Timestamp
              ? (d['lastSeen'] as Timestamp).toDate()
              : null);
      setState(() => _driverLocAt = at);
      _applyDriverLocation(LatLng(g.latitude, g.longitude));
      _syncRoute();
    });
  }

  // ── Camera ────────────────────────────────────

  void _refitMap() => _fitTrip();

  void _fitTrip() {
    if (!_mapReady) return;
    final driver = _driverLatLng;
    final toPickup = _headsToPickup;
    final target = toPickup ? _pickupLatLng : _dropoffLatLng;

    if (driver == null || target == null) {
      // No driver yet: frame pickup -> drop-off if we have both, else pickup.
      if (_pickupLatLng != null && _dropoffLatLng != null && driver == null) {
        final a = _pickupLatLng!, b = _dropoffLatLng!;
        _mapController?.animateCamera(CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(
                min(a.latitude, b.latitude), min(a.longitude, b.longitude)),
            northeast: LatLng(
                max(a.latitude, b.latitude), max(a.longitude, b.longitude)),
          ),
          80,
        ));
        return;
      }
      final p = driver ?? target ?? _pickupLatLng;
      if (p != null) {
        _mapController?.animateCamera(CameraUpdate.newLatLngZoom(p, 16));
      }
      return;
    }

    if (geoDistance(driver, target) < 30) {
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(driver, 17));
      return;
    }
    final sw = LatLng(min(driver.latitude, target.latitude),
        min(driver.longitude, target.longitude));
    final ne = LatLng(max(driver.latitude, target.latitude),
        max(driver.longitude, target.longitude));
    _mapController?.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: sw, northeast: ne), 90));
  }

  void _followCamera() {
    if (!_follow || !_mapReady) return;
    final now = DateTime.now();
    if (now.difference(_lastCam).inSeconds < 3) return;
    _lastCam = now;
    _fitTrip();
  }

  // ── Route ─────────────────────────────────────

  Future<void> _syncRoute() async {
    if (_routeBusy) return;
    // No route while searching or once the ride is over.
    if (!_view.tracksDriver) return;
    final toPickup = _headsToPickup;
    final from = toPickup ? _driverTarget : (_driverTarget ?? _pickupLatLng);
    final to = toPickup ? _pickupLatLng : _dropoffLatLng;
    if (from == null || to == null) return;

    final key = toPickup ? 'pickup' : 'dropoff';
    final now = DateTime.now();
    final sinceLast = now.difference(_lastRouteAt).inSeconds;
    final moved = _routeOrigin == null
        ? double.infinity
        : geoDistance(_routeOrigin!, from);

    if (sinceLast < 8) return; // also acts as retry backoff on failures
    if (key == _routeKey && !(moved > 200 && sinceLast > 20)) return;

    _routeBusy = true;
    _lastRouteAt = now;
    try {
      final result = await _routeService.getRoute(from, to);
      if (result != null && result.points.isNotEmpty && mounted) {
        setState(() {
          _routePolyline = {
            Polyline(
              polylineId: const PolylineId('route'),
              points: result.points,
              color: _kPrimary,
              width: 5,
            ),
          };
        });
        _routeKey = key;
        _routeOrigin = from;
      } else {
        debugPrint('Route fetch returned nothing ($key)');
      }
    } catch (e) {
      debugPrint('Route fetch failed: $e');
    } finally {
      _routeBusy = false;
    }
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{};
    final ms = MarkerService.instance;
    final serviceType = _tripData['serviceType'] as String?;

    if (_pickupLatLng != null) {
      markers.add(Marker(
        markerId: const MarkerId('pickup'),
        position: _pickupLatLng!,
        icon: ms.pickup(),
        anchor: const Offset(0.5, 1.0), // pin tip on coord
        infoWindow: const InfoWindow(title: 'Pickup'),
      ));
    }
    if (_dropoffLatLng != null) {
      markers.add(Marker(
        markerId: const MarkerId('dropoff'),
        position: _dropoffLatLng!,
        icon: ms.dropoff(),
        anchor: const Offset(0.5, 1.0),
        infoWindow: const InfoWindow(title: 'Drop-off'),
      ));
    }
    final pose = _driverPose.value;
    if (pose != null) {
      markers.add(Marker(
        markerId: const MarkerId('driver'),
        position: pose.pos,
        icon: ms.vehicle(serviceType),
        anchor: const Offset(0.5, 0.5), // vehicle centered on coord
        rotation: pose.bearing,
        flat: true, // flat = rotates with map/heading
        zIndex: 10,
        infoWindow:
            InfoWindow(title: _tripData['driverName'] as String? ?? 'Driver'),
      ));
    }
    return markers;
  }

  /// A completed ride: decided from the server's copy of the trip, never a
  /// cached one, so a trip already confirmed or settled is never offered for
  /// confirmation again (see tripCompletionStep).
  void _onCompleted(Map<String, dynamic> data, {required bool fromCache}) {
    if (!mounted || _completionHandled || fromCache) return;
    final step = tripCompletionStep(data);
    if (step == TripCompletionStep.none) return;
    _completionHandled = true;
    switch (step) {
      case TripCompletionStep.showSummary:
        _openSummary(data);
      case TripCompletionStep.askArrival:
        _askArrival(data);
      case TripCompletionStep.underReview:
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
          content: Text(
              'You reported a problem with this trip. Our team will review it and contact you.'),
          duration: Duration(seconds: 5),
        ));
      case TripCompletionStep.none:
        break;
    }
  }

  String _fareLabel(Map<String, dynamic> data) => data['actualFare'] != null
      ? 'GHS ${(data["actualFare"] as num).toStringAsFixed(2)}'
      : 'GHS ${(data["estimatedFare"] as num? ?? 0).toStringAsFixed(2)}';

  void _openSummary(Map<String, dynamic> data) {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => TripCompleteScreen(
          tripId: widget.tripId,
          driverId: data['driverId'] as String? ?? '',
          driverName: data['driverName'] as String? ?? 'Your driver',
          destination: data['dropoffAddress'] as String? ?? '',
          fare: _fareLabel(data),
          rideType: data['serviceType'] as String? ?? 'Ride',
          driverRating: (data['driverRating'] as num?)?.toDouble() ?? 5.0,
        ),
      ),
    );
  }

  // ── Passenger confirmation dialog ─────────────────────────────────────
  Future<void> _askArrival(Map<String, dynamic> data) async {
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    final answer = await askArrival(
      context,
      message: arrivalMessage(
        fare: _fareLabel(data),
        paymentMethod: data['paymentMethod'] as String?,
      ),
    );
    if (!mounted) return;

    if (answer == ArrivalAnswer.dismissed) {
      // Closed without answering (Android Back): nothing is written. The
      // passenger can answer later from here.
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: const Text('Let us know when you have arrived.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Answer',
          onPressed: () => _askArrival(data),
        ),
      ));
      return;
    }

    // "Yes" writes passengerConfirmed, which onTripCompleted settles once;
    // "Report issue" keeps the existing dispute flow.
    await applyArrivalAnswer(
      answer,
      FirestoreArrivalWriter(),
      tripId: widget.tripId,
      userId: FirebaseAuth.instance.currentUser?.uid,
    );
    if (!mounted) return;

    if (answer == ArrivalAnswer.arrived) {
      _openSummary(data);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Dispute raised. Our team will review and contact you.'),
        backgroundColor: CtsTheme.error,
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

  Future<void> _callDriver() => openPhoneAction(
        action: PhoneAction.call,
        number: _tripData['driverPhone'] as String?,
        label: 'your driver',
        messenger: ScaffoldMessenger.maybeOf(context),
      );

  Future<void> _messageDriver() => openPhoneAction(
        action: PhoneAction.sms,
        number: _tripData['driverPhone'] as String?,
        label: 'your driver',
        messenger: ScaffoldMessenger.maybeOf(context),
      );

  /// Shares the trip's real details. There is no public tracking page, so
  /// no tracking link is sent.
  void _shareTrip() => Share.share(
        rideShareText(_tripData),
        subject: 'My CTSGo ride',
      );

  Future<void> _cancelRide() async {
    if (_isCancelling) return;
    setState(() => _isCancelling = true);
    try {
      final confirmed = await showTrackingConfirm(
        context,
        title: 'Cancel this ride?',
        message: _view.phase == TrackingPhase.searching
            ? 'We will stop looking for a driver. Any amount held from your '
                'wallet for this ride is returned automatically.'
            : 'Your driver will be told you cancelled. Any amount held from '
                'your wallet for this ride is returned automatically.',
        confirmLabel: 'Cancel ride',
        keepLabel: 'Keep ride',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
      await cancelRideAsPassenger(
        FirebaseFirestore.instance,
        tripId: widget.tripId,
        passengerUid: FirebaseAuth.instance.currentUser?.uid ?? '',
      );
      if (mounted) {
        Navigator.of(context, rootNavigator: true)
            .pushNamedAndRemoveUntil('/shell', (_) => false);
      }
    } on TrackingActionException catch (e) {
      _snack(e.message, isError: true);
    } catch (e) {
      debugPrint('Ride cancel failed: $e');
      _snack("Couldn't cancel. Check your connection and try again.",
          isError: true);
    } finally {
      if (mounted) setState(() => _isCancelling = false);
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

  void _showSOSSheet() => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => _SOSSheet(shareText: rideShareText(_tripData)),
      );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tripSub?.cancel();
    _driverDocSub?.cancel();
    _driverAnim.dispose();
    _driverPose.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  void _goHome() => Navigator.of(context, rootNavigator: true)
      .pushNamedAndRemoveUntil('/shell', (_) => false);

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator(color: _kPrimary)));
    }
    if (_loadFailed) {
      return Scaffold(
        body: CtsErrorState(
          title: "Can't load your ride",
          message: 'Check your connection. Your ride is not affected.',
          onRetry: () {
            setState(() {
              _loadFailed = false;
              _isLoading = true;
            });
            _subscribeToTrip();
          },
          onBack: _goHome,
        ),
      );
    }
    if (_missing) {
      return TrackingEndedScreen(
        view: const TrackingView(
          phase: TrackingPhase.ended,
          icon: Icons.search_off_rounded,
          headline: 'Ride not found',
          detail: 'This ride may have been removed. You can check your past '
              'rides in History.',
        ),
        onHome: _goHome,
      );
    }

    final view = _view;
    if (view.phase == TrackingPhase.ended ||
        view.phase == TrackingPhase.unknown) {
      return TrackingEndedScreen(
        view: view,
        homeLabel: _rawStatus == 'cancelledByDriver' ||
                _rawStatus == 'noDriversAvailable' ||
                _rawStatus == 'expired'
            ? 'Book another ride'
            : 'Back to home',
        onHome: _goHome,
      );
    }

    final phone = (_tripData['driverPhone'] as String?)?.trim() ?? '';
    final showDriver = view.hasDriver && _tripData['driverId'] != null;
    final fare =
        (_tripData['actualFare'] ?? _tripData['estimatedFare']) as num?;

    return PopScope(
      // Leaving mid-ride is blocked as before; the ride keeps running.
      canPop: view.isOver || view.phase == TrackingPhase.review,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _snack("Your ride is still active. You'll be able to leave this "
              'screen when it ends.');
        }
      },
      child: Scaffold(
        backgroundColor: CtsTheme.background,
        body: TrackingLayout(
          map: _buildMap(view),
          actions: showDriver && view.phase == TrackingPhase.active
              ? TrackingActionBar(
                  primary: TrackingAction(
                    label: 'Call driver',
                    icon: Icons.phone_rounded,
                    onTap: phone.isEmpty ? null : _callDriver,
                  ),
                  secondary: TrackingAction(
                    label: 'Message',
                    icon: Icons.sms_rounded,
                    onTap: phone.isEmpty ? null : _messageDriver,
                  ),
                )
              : null,
          children: [
            TrackingStatusHeader(view: view),
            const SizedBox(height: 18),
            TrackingProgressBar(steps: view.steps, current: view.stepIndex),
            const SizedBox(height: 18),
            if (showDriver) ...[
              TrackingDriverCard(
                name: _tripData['driverName'] as String?,
                rating: (_tripData['driverRating'] as num?)?.toDouble(),
                vehicle: _vehicleLabel(_tripData['serviceType'] as String?),
                plate: _tripData['driverPlate'] as String?,
              ),
              if (phone.isEmpty) ...[
                const SizedBox(height: 8),
                const Text(
                  "Your driver's phone number isn't available.",
                  style: TextStyle(fontSize: 14, color: CtsTheme.textSecondary),
                ),
              ],
              const SizedBox(height: 12),
            ],
            TrackingRouteSummary(
              fromLabel: 'Pickup',
              fromAddress: _tripData['pickupAddress'] as String? ?? '',
              toLabel: 'Destination',
              toAddress: _tripData['dropoffAddress'] as String? ?? '',
              emphasiseTo: view.heading == TrackingHeading.dropoff,
              priceLabel:
                  fare == null ? null : 'GHS ${fare.toStringAsFixed(2)}',
            ),
            const SizedBox(height: 16),
            if (showDriver) ...[
              _buildSafetyRow(),
              const SizedBox(height: 8),
            ],
            if (view.canCancel)
              TrackingCancelLink(
                label: 'Cancel ride',
                busy: _isCancelling,
                onTap: _cancelRide,
              ),
          ],
        ),
      ),
    );
  }

  /// The service type is the only vehicle information a trip carries.
  static String? _vehicleLabel(String? serviceType) => switch (serviceType) {
        'okada' => 'Okada (motorbike)',
        'pragya' => 'Pragya (tricycle)',
        'taxi' => 'Taxi',
        null || '' => null,
        _ => serviceType,
      };

  Widget _buildMap(TrackingView view) {
    return Stack(
      children: [
        // Only the map rebuilds on animation frames; a touch on the map
        // turns off camera-follow.
        Listener(
          onPointerDown: (_) => _follow = false,
          child: ValueListenableBuilder(
            valueListenable: _driverPose,
            builder: (_, __, ___) => GoogleMap(
              style: _mapStyle,
              onMapCreated: (c) {
                _mapController = c;
                setState(() => _mapReady = true);
                WidgetsBinding.instance.addPostFrameCallback((_) => _fitTrip());
              },
              initialCameraPosition:
                  CameraPosition(target: _pickupLatLng ?? _kAccra, zoom: 14),
              markers: _buildMarkers(),
              polylines: view.tracksDriver ? _routePolyline : const {},
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              compassEnabled: false,
              padding: const EdgeInsets.only(bottom: 48),
            ),
          ),
        ),
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          right: 16,
          child: TrackingMapButton(
            icon: Icons.my_location_rounded,
            label: 'Show the whole route',
            onTap: () {
              _follow = true;
              _lastCam = DateTime.fromMillisecondsSinceEpoch(0);
              _fitTrip();
            },
          ),
        ),
        if (view.tracksDriver)
          Positioned(
            left: 16,
            right: 80,
            bottom: 12,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TrackingLocationNote(
                hasLocation: _driverTarget != null,
                updatedAt: _driverLocAt,
              ),
            ),
          ),
      ],
    );
  }

  /// Share and SOS: real actions, kept below the main details.
  Widget _buildSafetyRow() => Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _shareTrip,
              icon: const Icon(Icons.share_rounded, size: 20),
              label: const Text('Share trip details'),
              style: OutlinedButton.styleFrom(
                foregroundColor: CtsTheme.textPrimary,
                minimumSize: const Size.fromHeight(48),
                side: const BorderSide(color: CtsTheme.border),
                textStyle:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _showSOSSheet,
              icon: const Icon(Icons.emergency_rounded, size: 20),
              label: const Text('SOS'),
              style: OutlinedButton.styleFrom(
                foregroundColor: CtsTheme.errorDeep,
                backgroundColor: CtsTheme.errorTint,
                minimumSize: const Size.fromHeight(48),
                side: const BorderSide(color: CtsTheme.errorBorder),
                textStyle:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      );
}

/// Trip details for sharing: destination, driver and plate when known.
/// There is no public tracking page, so no link is included.
String rideShareText(Map<String, dynamic> trip) {
  final dest = (trip['dropoffAddress'] as String?)?.trim();
  final driver = (trip['driverName'] as String?)?.trim();
  final plate = (trip['driverPlate'] as String?)?.trim();
  return [
    "I'm on a CTSGo ride${dest == null || dest.isEmpty ? '' : ' to $dest'}.",
    if (driver != null && driver.isNotEmpty) 'Driver: $driver.',
    if (plate != null && plate.isNotEmpty) 'Plate: $plate.',
  ].join(' ');
}

class _SOSSheet extends StatelessWidget {
  final String shareText;
  const _SOSSheet({required this.shareText});

  // Captures the messenger before closing the sheet so a failure message can
  // still be shown on the tracking screen.
  Future<void> _dial(BuildContext context, String number, String label) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    return openPhoneAction(
      action: PhoneAction.call,
      number: number,
      label: label,
      messenger: messenger,
    );
  }

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
                    color: CtsTheme.border,
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
                style: TextStyle(color: CtsTheme.textSecondary)),
            const SizedBox(height: 20),
            // 112 is Ghana's national emergency number (police, fire,
            // ambulance). These open the dialer; they do not place the call
            // or alert anyone on the user's behalf.
            _SOSOption(
                icon: Icons.emergency_rounded,
                label: 'Call Emergency (112)',
                onTap: () => _dial(context, '112', 'Emergency (112)')),
            _SOSOption(
                icon: Icons.local_police_rounded,
                label: 'Call Police (191)',
                onTap: () => _dial(context, '191', 'Police (191)')),
            _SOSOption(
                icon: Icons.local_hospital_rounded,
                label: 'Call Ambulance (193)',
                onTap: () => _dial(context, '193', 'Ambulance (193)')),
            _SOSOption(
                icon: Icons.people_rounded,
                label: 'Share trip details with a contact',
                onTap: () {
                  Navigator.pop(context);
                  Share.share('I need help. $shareText',
                      subject: 'Emergency — CTSGo');
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
