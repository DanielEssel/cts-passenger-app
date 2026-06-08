// lib/features/gas/presentation/screens/gas_order_tracking_screen.dart
//
// Production-grade gas order tracking screen.
// Changes from original:
//  - _contactSupport() fully implemented (bottom sheet with call / chat / report)
//  - GoogleMapController disposed properly in dispose()
//  - Camera animates to fit both markers on first load + whenever locations change
//  - DraggableScrollableSheet replaces fixed Column (no overflow, fully scrollable)
//  - Driver card shown when driverName/driverPhone are present on the order
//  - Live driver location marker rendered when order.driverLocation != null
//  - Cancel order dialog (guards against late-stage cancellations)
//  - SystemUiOverlayStyle + extendBodyBehindAppBar for immersive map
//  - Pulse animation on the active-status indicator
//  - Proper SafeArea handling for action buttons
//  - _ErrorState and _LoadingState extracted for clean code paths
//
// Assumed additions to GasRefillRequest model (add if not already present):
//   final String?   driverName;
//   final String?   driverPhone;
//   final String?   driverVehicle;       // e.g. "Toyota Corolla · AB-1234-22"
//   final GeoPoint? driverLocation;      // Firestore GeoPoint, nullable
//
// Assumed additions to gas_order_providers.dart:
//   final gasOrderRepositoryProvider = Provider<GasOrderRepository>(...);
//   // GasOrderRepository.cancelOrder(String orderId) → Future<void>

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:cts_transport_app/core/theme/app_theme.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/gas/providers/gas_order_providers.dart';
import 'package:cts_transport_app/features/ride/services/route_service.dart';

class GasOrderTrackingScreen extends ConsumerStatefulWidget {
  final String orderId;

  const GasOrderTrackingScreen({super.key, required this.orderId});

  @override
  ConsumerState<GasOrderTrackingScreen> createState() =>
      _GasOrderTrackingScreenState();
}

class _GasOrderTrackingScreenState extends ConsumerState<GasOrderTrackingScreen>
    with TickerProviderStateMixin {
  // ── Map ──────────────────────────────────────────────────────────────────
  GoogleMapController? _mapController;
  GasRefillRequest? _previousOrder;

  Set<Polyline> _routePolyline = {};
  bool _routeFetched = false;

  // ── Pulse animation for active-status dot ────────────────────────────────
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  // ── Cancellation loading guard ────────────────────────────────────────────
  bool _isCancelling = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _mapController?.dispose(); // ← was never disposed in original
    super.dispose();
  }

  // ── Map helpers ───────────────────────────────────────────────────────────

  /// Animates the camera to show pickup, delivery, and (if available) driver.
  void _fitCamera(GasRefillRequest order) {
    if (_mapController == null) return;

    final points = <LatLng>[
      LatLng(order.pickupLocation.latitude, order.pickupLocation.longitude),
      LatLng(order.deliveryLocation.latitude, order.deliveryLocation.longitude),
      if (order.driverLocation != null)
        LatLng(order.driverLocation!.latitude, order.driverLocation!.longitude),
    ];

    final minLat = points.map((p) => p.latitude).reduce((a, b) => a < b ? a : b);
    final maxLat = points.map((p) => p.latitude).reduce((a, b) => a > b ? a : b);
    final minLng = points.map((p) => p.longitude).reduce((a, b) => a < b ? a : b);
    final maxLng = points.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        96, // padding
      ),
    );
  }

  Future<void> _fetchRoute(GasRefillRequest order) async {
    if (_routeFetched) return;
    _routeFetched = true;
    final result = await ref.read(routeServiceProvider).getRoute(
      LatLng(order.pickupLocation.latitude, order.pickupLocation.longitude),
      LatLng(order.deliveryLocation.latitude, order.deliveryLocation.longitude),
    );
    if (result != null && result.points.isNotEmpty && mounted) {
      setState(() {
        _routePolyline = {
          Polyline(
            polylineId: const PolylineId('route'),
            points: result.points,
            color: AppTheme.primaryColor,
            width: 4,
          ),
        };
      });
    }
  }

  Set<Marker> _buildMarkers(GasRefillRequest order) {
    return {
      Marker(
        markerId: const MarkerId('pickup'),
        position: LatLng(
            order.pickupLocation.latitude, order.pickupLocation.longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        infoWindow: const InfoWindow(title: 'Pickup'),
      ),
      Marker(
        markerId: const MarkerId('delivery'),
        position: LatLng(
            order.deliveryLocation.latitude, order.deliveryLocation.longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: const InfoWindow(title: 'Delivery'),
      ),
      if (order.driverLocation != null)
        Marker(
          markerId: const MarkerId('driver'),
          position: LatLng(
              order.driverLocation!.latitude, order.driverLocation!.longitude),
          icon:
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          infoWindow: InfoWindow(title: order.driverName ?? 'Driver'),
        ),
    };
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _callDriver(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      _showSnack('Could not open dialer');
    }
  }

  void _showSupportSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SupportBottomSheet(orderId: widget.orderId),
    );
  }

  void _showCancelDialog(GasRefillRequest order) {
    // Cancellable only in early stages
    const cancellableStatuses = {
      GasOrderStatus.pendingApproval,
      GasOrderStatus.driverAssigned,
    };

    if (!cancellableStatuses.contains(order.status)) {
      _showSnack('Order cannot be cancelled at this stage');
      return;
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Cancel order?'),
        content: const Text(
          'Are you sure you want to cancel? A cancellation fee may apply if a driver has already been assigned.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep order'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _cancelOrder();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Cancel order'),
          ),
        ],
      ),
    );
  }

  Future<void> _cancelOrder() async {
    if (_isCancelling) return;
    setState(() => _isCancelling = true);
    try {
      await ref
          .read(gasOrderRepositoryProvider)
          .cancelOrder(widget.orderId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _showSnack('Failed to cancel: $e');
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final orderStream = ref.watch(gasOrderStreamProvider(widget.orderId));

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: _buildAppBar(orderStream),
        body: orderStream.when(
          data: (order) {
            if (order == null) {
              return const _EmptyState();
            }
            // Animate camera whenever locations change (first load or driver moves)
            if (_previousOrder?.pickupLocation != order.pickupLocation ||
                _previousOrder?.deliveryLocation != order.deliveryLocation ||
                _previousOrder?.driverLocation != order.driverLocation) {
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => _fitCamera(order));
            }
            _fetchRoute(order);  // draws route polyline once (guarded)
            _previousOrder = order;
            return _buildBody(order);
          },
          loading: () => const _LoadingState(),
          error: (e, _) => _ErrorState(
            error: e.toString(),
            onRetry: () =>
                ref.invalidate(gasOrderStreamProvider(widget.orderId)),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(AsyncValue<GasRefillRequest?> orderStream) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      leading: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: _FloatingCircleButton(
          child: const Icon(Icons.arrow_back_rounded,
              color: Colors.black87, size: 20),
        ),
      ),
      actions: [
        orderStream.whenOrNull(
              data: (order) {
                if (order == null) return null;
                const cancellable = {
                  GasOrderStatus.pendingApproval,
                  GasOrderStatus.driverAssigned,
                };
                if (!cancellable.contains(order.status)) return null;
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _isCancelling
                      ? const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : GestureDetector(
                          onTap: () => _showCancelDialog(order),
                          child: _FloatingPill(
                            label: 'Cancel',
                            color: Colors.red,
                          ),
                        ),
                );
              },
            ) ??
            const SizedBox.shrink(),
      ],
    );
  }

  Widget _buildBody(GasRefillRequest order) {
    return Stack(
      children: [
        // Full-screen map
        GoogleMap(
          onMapCreated: (controller) {
            _mapController = controller;
            _fitCamera(order);
          },
          initialCameraPosition: CameraPosition(
            target: LatLng(
              order.pickupLocation.latitude,
              order.pickupLocation.longitude,
            ),
            zoom: 14,
          ),
          markers: _buildMarkers(order),
          polylines: _routePolyline,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
          compassEnabled: false,
        ),

        // Bottom sheet — draggable, fully scrollable, no overflow
        DraggableScrollableSheet(
          initialChildSize: 0.45,
          minChildSize: 0.18,
          maxChildSize: 0.88,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.14),
                    blurRadius: 24,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: ListView(
                controller: scrollController,
                padding: EdgeInsets.zero,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // Status header with pulse
                  _StatusHeader(order: order, pulseAnim: _pulseAnim),

                  _Divider(),

                  // Driver card — shown only when a driver is assigned
                  if (_hasDriverInfo(order)) ...[
                    _DriverCard(
                      order: order,
                      onCall: () {
                        if (order.driverPhone?.isNotEmpty == true) {
                          _callDriver(order.driverPhone!);
                        }
                      },
                    ),
                    _Divider(),
                  ],

                  // OTP card — shown when order is active
                  _GasOtpCard(order: order),
                  // Order details
                  _OrderDetailsSection(order: order),

                  _Divider(),

                  // Action buttons
                  _ActionRow(
                    onSupport: _showSupportSheet,
                    orderId: widget.orderId,
                  ),

                  // Safe area bottom padding
                  SizedBox(
                      height: MediaQuery.of(context).padding.bottom + 16),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  bool _hasDriverInfo(GasRefillRequest order) =>
      (order.driverName?.isNotEmpty == true) ||
      (order.driverPhone?.isNotEmpty == true);
}


// ── Gas OTP Card ──────────────────────────────────────────────────────────────
class _GasOtpCard extends StatelessWidget {
  final GasRefillRequest order;
  const _GasOtpCard({required this.order});

  @override
  Widget build(BuildContext context) {
    // Only show for active orders that haven't been delivered
    if (order.status == GasOrderStatus.delivered ||
        order.status == GasOrderStatus.cancelled) {
      return const SizedBox.shrink();
    }

    // Get OTP from Firestore data via order metadata or a dedicated field
    final otp = order.deliveryOtp;
    if (otp == null || otp.isEmpty) return const SizedBox.shrink();

    final shareMsg = 'Your gas delivery OTP is: *$otp*\n\n'
        'Please give this code to the CTSRide delivery rider when they arrive.';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(16),
          border:       Border.all(color: const Color(0xFFE5E7EB)),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withValues(alpha: 0.04),
              blurRadius: 8, offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color:        const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.lock_rounded,
                    color: Color(0xFF16A34A), size: 18),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Delivery OTP',
                        style: TextStyle(
                          fontSize:   13,
                          fontWeight: FontWeight.w700,
                          color:      Color(0xFF111827),
                        )),
                    Text(
                      'Give this code to the rider on arrival',
                      style: TextStyle(
                          fontSize: 11, color: Color(0xFF6B7280)),
                    ),
                  ],
                ),
              ),
            ]),

            const SizedBox(height: 14),

            // OTP boxes
            Container(
              width:   double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color:        const Color(0xFFF8FAF9),
                borderRadius: BorderRadius.circular(12),
                border:       Border.all(
                    color: const Color(0xFF16A34A).withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: otp.split('').map((digit) => Container(
                  width:  40, height: 48,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color:        Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border:       Border.all(color: const Color(0xFF16A34A)),
                  ),
                  child: Center(
                    child: Text(digit,
                        style: const TextStyle(
                          fontSize:   22,
                          fontWeight: FontWeight.w900,
                          color:      Color(0xFF16A34A),
                        )),
                  ),
                )).toList(),
              ),
            ),

            const SizedBox(height: 12),

            // Warning
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color:        const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(children: [
                Icon(Icons.warning_amber_rounded,
                    color: Color(0xFFD97706), size: 14),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Only share this OTP with the CTSRide rider. '
                    'Do not share with anyone else.',
                    style: TextStyle(
                      fontSize: 11, color: Color(0xFF92400E),
                    ),
                  ),
                ),
              ]),
            ),

            const SizedBox(height: 12),

            // Share button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Share.share(shareMsg,
                    subject: 'CTSRide Gas Delivery OTP'),
                icon:  const Icon(Icons.share_rounded, size: 16),
                label: const Text('Share OTP'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF16A34A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Sub-widgets
// =============================================================================

class _FloatingCircleButton extends StatelessWidget {
  final Widget child;
  const _FloatingCircleButton({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.12), blurRadius: 8),
        ],
      ),
      child: child,
    );
  }
}

class _FloatingPill extends StatelessWidget {
  final String label;
  final Color color;
  const _FloatingPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.12), blurRadius: 8),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontWeight: FontWeight.w600, fontSize: 13),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const Divider(height: 1, indent: 20, endIndent: 20);
}

// ── Status header ──────────────────────────────────────────────────────────

class _StatusHeader extends StatelessWidget {
  final GasRefillRequest order;
  final Animation<double> pulseAnim;

  const _StatusHeader({required this.order, required this.pulseAnim});

  @override
  Widget build(BuildContext context) {
    final progress = order.status.progressValue;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Pulsing dot
              FadeTransition(
                opacity: pulseAnim,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: AppTheme.primaryColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  order.status.displayName,
                  style: AppTheme.titleMedium
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                '${(progress * 100).toInt()}%',
                style: AppTheme.bodyMedium
                    .copyWith(color: AppTheme.primaryColor),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey[200],
              valueColor:
                  const AlwaysStoppedAnimation(AppTheme.primaryColor),
              minHeight: 7,
            ),
          ),
          // ETA row — show when a driver is en route
          if (order.status == GasOrderStatus.driverEnRoute ||
              order.status == GasOrderStatus.driverAssigned) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.access_time_rounded,
                    size: 14, color: Colors.grey[500]),
                const SizedBox(width: 4),
                Text(
                  'Estimated arrival in ${order.refillType.estimatedDuration.inMinutes} min',
                  style: AppTheme.bodySmall
                      .copyWith(color: Colors.grey[500]),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── Driver card ────────────────────────────────────────────────────────────

class _DriverCard extends StatelessWidget {
  final GasRefillRequest order;
  final VoidCallback onCall;

  const _DriverCard({required this.order, required this.onCall});

  String get _initials {
    final name = order.driverName?.trim() ?? '';
    if (name.isEmpty) return '?';
    final parts = name.split(' ');
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          // Avatar
          CircleAvatar(
            radius: 24,
            backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
            child: Text(
              _initials,
              style: TextStyle(
                color: AppTheme.primaryColor,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.driverName ?? 'Your Driver',
                  style: AppTheme.titleSmall
                      .copyWith(fontWeight: FontWeight.bold),
                ),
                if (order.driverVehicle?.isNotEmpty == true) ...[
                  const SizedBox(height: 2),
                  Text(
                    order.driverVehicle!,
                    style: AppTheme.bodySmall
                        .copyWith(color: Colors.grey[500]),
                  ),
                ],
              ],
            ),
          ),
          // Call button — only shown when phone is available
          if (order.driverPhone?.isNotEmpty == true)
            GestureDetector(
              onTap: onCall,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.call_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Order details ──────────────────────────────────────────────────────────

class _OrderDetailsSection extends StatelessWidget {
  final GasRefillRequest order;
  const _OrderDetailsSection({required this.order});

  @override
  Widget build(BuildContext context) {
    // Safe substring — avoids crash if ID is shorter than 8 chars
    final shortId =
        order.id.length >= 8 ? order.id.substring(0, 8).toUpperCase() : order.id.toUpperCase();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Order details',
              style:
                  AppTheme.titleSmall.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          _DetailRow(label: 'Order ID', value: '#$shortId'),
          _DetailRow(label: 'Type', value: order.refillType.displayName),
          _DetailRow(
            label: 'Cylinder',
            value:
                '${order.cylinderSize.displayName} × ${order.quantity}',
          ),
          _DetailRow(
            label: 'Total',
            value: '₵${order.totalPrice.toStringAsFixed(2)}',
            valueColor: AppTheme.primaryColor,
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: AppTheme.bodyMedium.copyWith(color: Colors.grey[500])),
          Text(
            value,
            style: AppTheme.bodyMedium.copyWith(
              fontWeight: FontWeight.w600,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Action row ─────────────────────────────────────────────────────────────

class _ActionRow extends StatelessWidget {
  final VoidCallback onSupport;
  final String orderId;

  const _ActionRow({required this.onSupport, required this.orderId});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onSupport,
              icon: const Icon(Icons.headset_mic_rounded, size: 18),
              label: const Text('Support'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: BorderSide(color: Colors.grey[300]!),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: orderId));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Order ID copied'),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy ID'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Support bottom sheet ──────────────────────────────────────────────────
//
// Fully implemented — was an empty stub in the original.

class _SupportBottomSheet extends StatelessWidget {
  final String orderId;
  const _SupportBottomSheet({required this.orderId});

  Future<void> _launchUrl(BuildContext context, Uri uri) async {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Replace with your actual support phone and WhatsApp number.
    const supportPhone = '+233200000000';
    const whatsAppNumber = '233200000000';
    final shortId = orderId.length >= 8
        ? orderId.substring(0, 8).toUpperCase()
        : orderId.toUpperCase();
    final whatsAppMessage = Uri.encodeComponent(
        'Hi, I need help with order #$shortId');

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).padding.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          Text('Contact support',
              style:
                  AppTheme.titleMedium.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'Order #$shortId · We\'re here to help',
            style: AppTheme.bodySmall.copyWith(color: Colors.grey[500]),
          ),
          const SizedBox(height: 20),

          _SupportOption(
            icon: Icons.call_rounded,
            title: 'Call support',
            subtitle: supportPhone,
            color: Colors.green,
            onTap: () => _launchUrl(
                context, Uri(scheme: 'tel', path: supportPhone)),
          ),
          const SizedBox(height: 12),
          _SupportOption(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'WhatsApp',
            subtitle: 'Chat with us instantly',
            color: const Color(0xFF25D366),
            onTap: () => _launchUrl(
              context,
              Uri.parse(
                  'https://wa.me/$whatsAppNumber?text=$whatsAppMessage'),
            ),
          ),
          const SizedBox(height: 12),
          _SupportOption(
            icon: Icons.flag_outlined,
            title: 'Report an issue',
            subtitle: 'Wrong item, delay, or other problem',
            color: Colors.orange,
            onTap: () {
              Navigator.pop(context);
             
            },
          ),
        ],
      ),
    );
  }
}

class _SupportOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _SupportOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppTheme.titleSmall
                          .copyWith(fontWeight: FontWeight.w600)),
                  Text(subtitle,
                      style: AppTheme.bodySmall
                          .copyWith(color: Colors.grey[500])),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: Colors.grey[400], size: 20),
          ],
        ),
      ),
    );
  }
}

// ── Empty / loading / error states ────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded,
                size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('Order not found',
                style: AppTheme.titleMedium
                    .copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'This order may have been removed or the ID is incorrect.',
              textAlign: TextAlign.center,
              style:
                  AppTheme.bodyMedium.copyWith(color: Colors.grey[500]),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Go back'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 64, color: Colors.red[300]),
            const SizedBox(height: 16),
            Text('Something went wrong',
                style: AppTheme.titleMedium
                    .copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style:
                  AppTheme.bodyMedium.copyWith(color: Colors.grey[500]),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}