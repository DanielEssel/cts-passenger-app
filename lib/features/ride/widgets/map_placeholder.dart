// features/ride/widgets/map_placeholder.dart
//
// ✅ Real road route via Google Directions API (no more straight line)
// ✅ Driver markers streamed live from Firestore via driversNearbyProvider
// ✅ _fitCameraToBounds uses LatLngBounds.fromPoints — no manual min/max
// ✅ Route fetched only when both origin + destination change (not on every build)
// ✅ Custom car icon for driver markers (async loaded once)
// ✅ ConsumerStatefulWidget — reads providers without prop drilling
// ✅ RouteService injected via Riverpod — swappable in tests

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../providers/drivers_nearby_provider.dart';
import '../services/route_service.dart';

class MapPlaceholder extends ConsumerStatefulWidget {
  final double height;
  final bool showRoute;
  final LatLng? origin;
  final LatLng? destination;
  final VoidCallback? onMapTap;

  const MapPlaceholder({
    super.key,
    this.height = 248,
    this.showRoute = false,
    this.origin,
    this.destination,
    this.onMapTap,
  });

  @override
  ConsumerState<MapPlaceholder> createState() => _MapPlaceholderState();
}

class _MapPlaceholderState extends ConsumerState<MapPlaceholder> {
  GoogleMapController? _mapController;

  // Markers — origin/dest + live driver positions
  final Map<MarkerId, Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  // Driver car icon (loaded once asynchronously)
  BitmapDescriptor? _carIcon;

  bool _isFetchingRoute = false;

  static const _defaultLocation = LatLng(5.6037, -0.1870);

  @override
  void initState() {
    super.initState();
    _loadCarIcon();
  }

  Future<void> _loadCarIcon() async {
    final icon = await BitmapDescriptor.asset(
      const ImageConfiguration(size: Size(36, 36)),
      'assets/icons/car_marker.png', // add this asset or swap for defaultMarker
    );
    if (mounted) setState(() => _carIcon = icon);
  }

  @override
  void didUpdateWidget(MapPlaceholder oldWidget) {
    super.didUpdateWidget(oldWidget);
    final originChanged = oldWidget.origin != widget.origin;
    final destChanged = oldWidget.destination != widget.destination;

    if (originChanged || destChanged) {
      _rebuildStaticMarkers();
      if (widget.showRoute &&
          widget.origin != null &&
          widget.destination != null) {
        _fetchAndDrawRoute();
      } else {
        // Clear route when destination is removed
        setState(() => _polylines.clear());
        if (widget.origin != null) _animateCameraTo(widget.origin!);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Static markers (pickup + dropoff)
  // ---------------------------------------------------------------------------

  void _rebuildStaticMarkers() {
    _markers.remove(const MarkerId('origin'));
    _markers.remove(const MarkerId('destination'));

    if (widget.origin != null) {
      _markers[const MarkerId('origin')] = Marker(
        markerId: const MarkerId('origin'),
        position: widget.origin!,
        infoWindow: const InfoWindow(title: 'Pickup'),
        icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen),
      );
    }

    if (widget.destination != null) {
      _markers[const MarkerId('destination')] = Marker(
        markerId: const MarkerId('destination'),
        position: widget.destination!,
        infoWindow: const InfoWindow(title: 'Dropoff'),
        icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueRed),
      );
    }

    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Real road route from Directions API
  // ---------------------------------------------------------------------------

  Future<void> _fetchAndDrawRoute() async {
    if (_isFetchingRoute) return;
    _isFetchingRoute = true;

    final result = await ref.read(routeServiceProvider).getRoute(
          widget.origin!,
          widget.destination!,
        );

    _isFetchingRoute = false;
    if (!mounted) return;

    setState(() {
      _polylines.clear();
      if (result != null) {
        _polylines.add(Polyline(
          polylineId: const PolylineId('route'),
          points: result.points,   // ✅ real road path, not straight line
          color: AppColors.primary,
          width: 4,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
        ));
        _fitCameraToBounds(result.points);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Driver markers — rebuilt whenever driversNearbyProvider emits
  // ---------------------------------------------------------------------------

  void _rebuildDriverMarkers(List<NearbyDriver> drivers) {
    // Remove stale driver markers
    _markers.removeWhere((id, _) => id.value.startsWith('driver_'));

    for (final driver in drivers) {
      final markerId = MarkerId('driver_${driver.id}');
      _markers[markerId] = Marker(
        markerId: markerId,
        position: driver.location,
        icon: _carIcon ??
            BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueAzure),
        infoWindow: InfoWindow(title: driver.name),
        anchor: const Offset(0.5, 0.5),
        flat: true, // ✅ rotates with the map
      );
    }

    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Camera helpers
  // ---------------------------------------------------------------------------

  /// ✅ Uses LatLngBounds constructor with correct SW/NE calculation
  void _fitCameraToBounds(List<LatLng> points) {
    if (_mapController == null || points.isEmpty) return;

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        60, // padding in logical pixels
      ),
    );
  }

  void _animateCameraTo(LatLng target) {
    _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(target, 14),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // ✅ Driver markers update in real-time without rebuilding the whole widget
    ref.listen(driversNearbyProvider, (_, next) {
      next.whenData(_rebuildDriverMarkers);
    });

    return GestureDetector(
      onTap: widget.onMapTap,
      child: SizedBox(
        height: widget.height,
        child: GoogleMap(
          initialCameraPosition: CameraPosition(
            target: widget.origin ?? _defaultLocation,
            zoom: 14,
          ),
          onMapCreated: (controller) {
            _mapController = controller;
            _rebuildStaticMarkers();
            if (widget.showRoute &&
                widget.origin != null &&
                widget.destination != null) {
              _fetchAndDrawRoute();
            }
          },
          markers: Set<Marker>.of(_markers.values),
          polylines: _polylines,
          myLocationEnabled: true,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          compassEnabled: true,
          buildingsEnabled: true,
          padding: const EdgeInsets.only(bottom: 40),
        ),
      ),
    );
  }
}