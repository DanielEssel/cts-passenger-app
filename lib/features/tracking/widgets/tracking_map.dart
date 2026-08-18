// lib/features/tracking/widgets/tracking_map.dart
// Fixed map controls positioning and locator functionality

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../../../core/constants/app_colors.dart';
import 'tracking_constants.dart';

class TrackingMap extends StatefulWidget {
  final LatLng pickup;
  final LatLng dropoff;
  final LatLng? driverLocation;
  final double driverHeading;
  final Set<Marker>? additionalMarkers;
  final Set<Polyline>? polylines;
  final Widget? overlayWidget;
  final VoidCallback? onMapCreated;
  final bool showControls;
  final bool myLocationEnabled;
  final EdgeInsets padding;
  final double controlsBottomOffset;

  const TrackingMap({
    super.key,
    required this.pickup,
    required this.dropoff,
    this.driverLocation,
    this.driverHeading = 0,
    this.additionalMarkers,
    this.polylines,
    this.overlayWidget,
    this.onMapCreated,
    this.showControls = true,
    this.myLocationEnabled = true,
    this.padding = const EdgeInsets.only(bottom: 180),
    this.controlsBottomOffset = 200,
  });

  @override
  State<TrackingMap> createState() => _TrackingMapState();
}

class _TrackingMapState extends State<TrackingMap> {
  GoogleMapController? _controller;
  bool _mapReady = false;
  Timer? _autoFitTimer;
  Timer? _followTimer;

  LatLng? _lastDriverPosition;
  double? _lastZoom;
  bool _isMovingToLocation = false;

  @override
  void initState() {
    super.initState();
    _startAutoFitTimer();
  }

  @override
  void didUpdateWidget(TrackingMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.driverLocation != null &&
        oldWidget.driverLocation != widget.driverLocation) {
      _handleDriverMovement();
    }
  }

  void _startAutoFitTimer() {
    _autoFitTimer?.cancel();
    _autoFitTimer = Timer(const Duration(milliseconds: 500), () {
      if (_mapReady && _controller != null) {
        _fitMap();
      }
    });
  }

  void _handleDriverMovement() {
    _followTimer?.cancel();
    _followTimer = Timer(const Duration(milliseconds: 100), () {
      if (_mapReady && _controller != null && widget.driverLocation != null) {
        _animateToDriver();
      }
    });
  }

  void _fitMap() {
    if (!_mapReady || _controller == null) return;

    final bounds = _calculateBounds();
    _controller!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 80),
    );
  }

  LatLngBounds _calculateBounds() {
    final points = [
      widget.pickup,
      widget.dropoff,
      if (widget.driverLocation != null) widget.driverLocation!,
    ];

    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;

    for (final point in points) {
      minLat = min(minLat, point.latitude);
      maxLat = max(maxLat, point.latitude);
      minLng = min(minLng, point.longitude);
      maxLng = max(maxLng, point.longitude);
    }

    final latPadding = (maxLat - minLat) * 0.2;
    final lngPadding = (maxLng - minLng) * 0.2;

    return LatLngBounds(
      southwest: LatLng(minLat - latPadding, minLng - lngPadding),
      northeast: LatLng(maxLat + latPadding, maxLng + lngPadding),
    );
  }

  void _animateToDriver() {
    if (_controller == null || widget.driverLocation == null) return;

    _controller!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: widget.driverLocation!,
          zoom: _lastZoom ?? 16,
        ),
      ),
    );

    _lastDriverPosition = widget.driverLocation;
  }

  void _onMapCreated(GoogleMapController controller) {
    _controller = controller;
    setState(() => _mapReady = true);
    widget.onMapCreated?.call();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitMap();
    });
  }

  void _moveToCurrentLocation() {
    if (_controller == null) return;

    // Try driver location first, fallback to pickup
    final target = widget.driverLocation ?? widget.pickup;
    
    if (_isMovingToLocation) return;
    _isMovingToLocation = true;

    _controller!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: target,
          zoom: 17,
        ),
      ),
    ).then((_) {
      _isMovingToLocation = false;
    }).catchError((_) {
      _isMovingToLocation = false;
    });
  }

  void _zoomIn() {
    if (_controller != null) {
      _controller!.animateCamera(
        CameraUpdate.zoomIn(),
      );
    }
  }

  void _zoomOut() {
    if (_controller != null) {
      _controller!.animateCamera(
        CameraUpdate.zoomOut(),
      );
    }
  }

  @override
  void dispose() {
    _autoFitTimer?.cancel();
    _followTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GoogleMap(
          style: TrackingConstants.mapStyle,
          onMapCreated: _onMapCreated,
          initialCameraPosition: CameraPosition(
            target: widget.pickup,
            zoom: 14,
          ),
          markers: _buildMarkers(),
          polylines: widget.polylines ?? const {},
          myLocationEnabled: widget.myLocationEnabled,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
          compassEnabled: false,
          padding: widget.padding,
        ),
        if (widget.showControls) _buildMapControls(),
        if (widget.overlayWidget != null) widget.overlayWidget!,
      ],
    );
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{...?widget.additionalMarkers};
    return markers;
  }

  Widget _buildMapControls() {
    return Positioned(
      right: 16,
      bottom: widget.controlsBottomOffset,
      child: Column(
        children: [
          // Locate Me button - primary action
          _buildMapControlButton(
            icon: Icons.my_location_rounded,
            onTap: _moveToCurrentLocation,
            isPrimary: true,
          ),
          const SizedBox(height: 10),
          // Zoom In
          _buildMapControlButton(
            icon: Icons.add_rounded,
            onTap: _zoomIn,
          ),
          const SizedBox(height: 10),
          // Zoom Out
          _buildMapControlButton(
            icon: Icons.remove_rounded,
            onTap: _zoomOut,
          ),
          const SizedBox(height: 10),
          // Fit Screen
          _buildMapControlButton(
            icon: Icons.fit_screen_rounded,
            onTap: _fitMap,
          ),
        ],
      ),
    );
  }

  Widget _buildMapControlButton({
    required IconData icon,
    required VoidCallback onTap,
    bool isPrimary = false,
  }) {
    return GestureDetector(
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
              offset: const Offset(0, 2),
            ),
          ],
          border: isPrimary
              ? Border.all(color: AppColors.primary, width: 2)
              : null,
        ),
        child: Icon(
          icon,
          color: isPrimary ? AppColors.primary : AppColors.textPrimary,
          size: 20,
        ),
      ),
    );
  }
}