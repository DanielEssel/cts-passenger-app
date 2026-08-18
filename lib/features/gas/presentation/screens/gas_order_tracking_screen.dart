// lib/features/gas/presentation/screens/gas_order_tracking_screen.dart
// Refactored to use shared tracking widgets (no TrackingStatusHeader yet)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/marker_service.dart';
import '../../../../widgets/common/shared_widgets.dart';
import '../../../ride/presentation/trip_complete_screen.dart';
import '../../../ride/services/route_service.dart';
import '../../../tracking/widgets/tracking_constants.dart';
import '../../../tracking/widgets/tracking_action_button.dart';
import '../../../tracking/widgets/tracking_drag_handle.dart';
import '../../../tracking/widgets/tracking_map.dart';
import '../../../tracking/widgets/tracking_status_banner.dart';
import '../../../tracking/widgets/tracking_timeline.dart';
import '../../models/gas_refill_request.dart';
import '../../providers/gas_order_providers.dart';

// Temporary inline status header until shared widget is created
class _TempStatusHeader extends StatelessWidget {
  final String statusText;
  final IconData icon;
  final bool isLive;

  const _TempStatusHeader({
    required this.statusText,
    required this.icon,
    this.isLive = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              statusText,
              style: AppTextStyles.labelLarge.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
          if (isLive)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Text(
                'LIVE',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class DriverInfoCard extends StatelessWidget {
  final String name;
  final double rating;
  final String vehicleType;
  final String? vehiclePlate;
  final String price;
  final IconData vehicleIcon;
  final VoidCallback? onCall;
  final VoidCallback? onChat;
  final VoidCallback? onEmergency;

  const DriverInfoCard({
    super.key,
    required this.name,
    required this.rating,
    required this.vehicleType,
    this.vehiclePlate,
    required this.price,
    required this.vehicleIcon,
    this.onCall,
    this.onChat,
    this.onEmergency,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primaryDim,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(vehicleIcon, color: AppColors.primary, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: AppTextStyles.heading4
                            .copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.star_rounded,
                            color: AppColors.success, size: 16),
                        const SizedBox(width: 4),
                        Text(rating.toStringAsFixed(1),
                            style: AppTextStyles.bodyMedium),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(vehicleType,
                        style: AppTextStyles.bodyMedium
                            .copyWith(color: AppColors.textSecondary)),
                    if (vehiclePlate != null && vehiclePlate!.isNotEmpty)
                      Text(vehiclePlate!,
                          style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              Text(price,
                  style: AppTextStyles.heading4
                      .copyWith(color: AppColors.primary)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: onCall,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.phone_rounded,
                            size: 18, color: AppColors.primary),
                        SizedBox(width: 8),
                        Text('Call',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: onChat,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.chat_bubble_rounded,
                            size: 18, color: AppColors.primary),
                        SizedBox(width: 8),
                        Text('Chat',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: onEmergency,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: AppColors.errorLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.report_problem_rounded,
                            size: 18, color: AppColors.error),
                        SizedBox(width: 8),
                        Text('Report',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: AppColors.error)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class GasOrderTrackingScreen extends ConsumerWidget {
  final String orderId;

  const GasOrderTrackingScreen({super.key, required this.orderId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderAsync = ref.watch(gasOrderStreamProvider(orderId));

    // Navigate to rating screen when order completes
    ref.listen(gasOrderStreamProvider(orderId), (prev, next) {
      final prevStatus = prev?.value?.status;
      final order = next.value;
      if (order != null &&
          order.status == GasOrderStatus.delivered &&
          prevStatus != GasOrderStatus.delivered) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => TripCompleteScreen(
              tripId: order.id,
              collection: 'gas_orders',
              serviceType: 'gas',
              driverId: order.driverId ?? '',
              driverName: order.driverName ?? 'Your driver',
              destination: order.deliveryAddress ?? '',
              fare: 'GHS ${order.totalPrice.toStringAsFixed(2)}',
              rideType: 'Gas Delivery',
              driverRating: 5.0,
            ),
          ),
        );
      }
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      body: orderAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (order) {
          if (order == null) {
            return const Center(child: Text('Order not found'));
          }
          return _GasTrackingBody(order: order, orderId: orderId);
        },
      ),
    );
  }
}

class _GasTrackingBody extends ConsumerStatefulWidget {
  final GasRefillRequest order;
  final String orderId;

  const _GasTrackingBody({
    required this.order,
    required this.orderId,
  });

  @override
  ConsumerState<_GasTrackingBody> createState() => _GasTrackingBodyState();
}

class _GasTrackingBodyState extends ConsumerState<_GasTrackingBody> {
  late final RouteService _routeService;
  Set<Polyline> _polylines = {};
  bool _routeFetched = false;

  // Timeline steps for gas delivery
  static const _steps = [
    GasOrderStatus.pendingApproval,
    GasOrderStatus.driverAssigned,
    GasOrderStatus.driverEnRoute,
    GasOrderStatus.driverArrived,
    GasOrderStatus.pickedUp,
    GasOrderStatus.atStation,
    GasOrderStatus.refilling,
    GasOrderStatus.returning,
    GasOrderStatus.delivered,
  ];

  static const _stepIcons = <GasOrderStatus, IconData>{
    GasOrderStatus.pendingApproval: Icons.hourglass_top_rounded,
    GasOrderStatus.driverAssigned: Icons.person_rounded,
    GasOrderStatus.driverEnRoute: Icons.directions_bike_rounded,
    GasOrderStatus.driverArrived: Icons.location_on_rounded,
    GasOrderStatus.pickedUp: Icons.propane_tank_rounded,
    GasOrderStatus.atStation: Icons.local_gas_station_rounded,
    GasOrderStatus.refilling: Icons.local_fire_department_rounded,
    GasOrderStatus.returning: Icons.u_turn_left_rounded,
    GasOrderStatus.delivered: Icons.check_circle_rounded,
  };

  static const _stepLabels = <GasOrderStatus, String>{
    GasOrderStatus.pendingApproval: 'Finding driver',
    GasOrderStatus.driverAssigned: 'Driver assigned',
    GasOrderStatus.driverEnRoute: 'Driver en route',
    GasOrderStatus.driverArrived: 'Driver arrived',
    GasOrderStatus.pickedUp: 'Cylinder collected',
    GasOrderStatus.atStation: 'At refill station',
    GasOrderStatus.refilling: 'Refilling',
    GasOrderStatus.returning: 'Returning to you',
    GasOrderStatus.delivered: 'Delivered',
  };

  @override
  void initState() {
    super.initState();
    _routeService = RouteService();
    _fetchRoute();
  }

  Future<void> _fetchRoute() async {
    if (_routeFetched) return;
    _routeFetched = true;

    final pickup = LatLng(
      widget.order.pickupLocation.latitude,
      widget.order.pickupLocation.longitude,
    );
    final dropoff = LatLng(
      widget.order.deliveryLocation.latitude,
      widget.order.deliveryLocation.longitude,
    );

    final result = await _routeService.getRoute(pickup, dropoff);
    if (result != null && result.points.isNotEmpty && mounted) {
      setState(() {
        _polylines = {
          // Main route
          Polyline(
            polylineId: const PolylineId('main_route'),
            points: result.points,
            color: AppColors.primary.withValues(alpha: 0.9),
            width: TrackingConstants.polylineWidth.toInt(),
            geodesic: TrackingConstants.polylineGeodesic,
            patterns: const [],
            jointType: JointType.round,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
          // Shadow for depth
          Polyline(
            polylineId: const PolylineId('shadow_route'),
            points: result.points,
            color: Colors.black.withValues(alpha: 0.08),
            width: TrackingConstants.polylineShadowWidth.toInt(),
            geodesic: TrackingConstants.polylineGeodesic,
            patterns: const [],
            jointType: JointType.round,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final isCompleted = order.status == GasOrderStatus.delivered;
    final isCancelled = order.status == GasOrderStatus.cancelled ||
        order.status == GasOrderStatus.failed;

    final pickup = LatLng(
      order.pickupLocation.latitude,
      order.pickupLocation.longitude,
    );
    final dropoff = LatLng(
      order.deliveryLocation.latitude,
      order.deliveryLocation.longitude,
    );
    final driverLocation = order.driverLocation != null
        ? LatLng(
            order.driverLocation!.latitude,
            order.driverLocation!.longitude,
          )
        : null;

    SystemChrome.setSystemUIOverlayStyle(TrackingConstants.lightStatusBar);

    return Stack(
      children: [
        // Full-bleed map
        Positioned.fill(
          child: _buildTrackingMap(pickup, dropoff, driverLocation),
        ),

        // Status header
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          left: 16,
          right: 16,
          child: _buildStatusHeader(order),
        ),

        // Draggable bottom sheet
        DraggableScrollableSheet(
          initialChildSize: TrackingConstants.initialSheetSize,
          minChildSize: TrackingConstants.minSheetSize,
          maxChildSize: TrackingConstants.maxSheetSize,
          snap: true,
          snapSizes: TrackingConstants.snapSizes,
          builder: (context, scrollController) => Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, -8),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: Column(
              children: [
                const TrackingDragHandle(),
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      children: [
                        if (isCancelled)
                          _buildCancelledBanner()
                        else ...[
                          _buildTimeline(order),
                          const SizedBox(height: 14),
                          if (isCompleted) ...[
                            _buildCompletedBanner(),
                            const SizedBox(height: 14),
                          ],
                        ],
                        _buildOtpCard(context),
                        const SizedBox(height: 12),
                        _buildDriverInfoCard(context),
                        const SizedBox(height: 12),
                        _buildOrderSummary(),
                        const SizedBox(height: 12),
                        if (!isCompleted && !isCancelled)
                          _buildActionRow(context),
                        if (isCompleted || isCancelled) ...[
                          const SizedBox(height: 12),
                          PrimaryButton(
                            label: 'Back to home',
                            onTap: () =>
                                Navigator.of(context, rootNavigator: true)
                                    .pushNamedAndRemoveUntil(
                                        AppRoutes.shell, (_) => false),
                          ),
                        ],
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // In gas_order_tracking_screen.dart - update the map usage

  Widget _buildTrackingMap(
    LatLng pickup,
    LatLng dropoff,
    LatLng? driverLocation,
  ) {
    return TrackingMap(
      pickup: pickup,
      dropoff: dropoff,
      driverLocation: driverLocation,
      driverHeading: widget.order.driverHeading ?? 0,
      polylines: _polylines,
      additionalMarkers: _buildMarkers(),
      padding: const EdgeInsets.only(bottom: 160),
      controlsBottomOffset: 180, // Controls above bottom sheet
      myLocationEnabled: true,
      showControls: true,
    );
  }

  Set<Marker> _buildMarkers() {
    final markerService = MarkerService.instance;
    final pickup = LatLng(
      widget.order.pickupLocation.latitude,
      widget.order.pickupLocation.longitude,
    );
    final dropoff = LatLng(
      widget.order.deliveryLocation.latitude,
      widget.order.deliveryLocation.longitude,
    );

    return {
      Marker(
        markerId: const MarkerId('pickup'),
        position: pickup,
        icon: markerService.pickup(),
        anchor: const Offset(0.5, 1.0),
      ),
      Marker(
        markerId: const MarkerId('dropoff'),
        position: dropoff,
        icon: markerService.dropoff(),
        anchor: const Offset(0.5, 1.0),
      ),
    };
  }

  Widget _buildStatusHeader(GasRefillRequest order) {
    final isActive = !_isCompleteOrCancelled(order.status);
    final statusText =
        _stepLabels[order.status] ?? order.status.passengerDisplayName;

    return _TempStatusHeader(
      statusText: statusText,
      icon: Icons.local_fire_department_rounded,
      isLive: isActive,
    );
  }

  bool _isCompleteOrCancelled(GasOrderStatus status) {
    return status == GasOrderStatus.delivered ||
        status == GasOrderStatus.cancelled ||
        status == GasOrderStatus.failed;
  }

  Widget _buildTimeline(GasRefillRequest order) {
    final currentIndex = _steps.indexOf(order.status);

    final timelineItems = _steps.asMap().entries.map((entry) {
      final index = entry.key;
      final status = entry.value;
      return TrackingTimelineItem(
        icon: _stepIcons[status] ?? Icons.circle_outlined,
        label: _stepLabels[status] ?? status.passengerDisplayName,
        isCompleted: index < currentIndex,
        isCurrent: index == currentIndex,
      );
    }).toList();

    return TrackingTimeline(
      items: timelineItems,
      currentIndex: currentIndex,
    );
  }

  Widget _buildCompletedBanner() {
    return TrackingStatusBanner(
      icon: Icons.check_circle_rounded,
      color: AppColors.success,
      title: 'Gas delivered!',
      subtitle:
          'Delivered to ${widget.order.deliveryAddress ?? 'your location'}',
    );
  }

  Widget _buildCancelledBanner() {
    return TrackingStatusBanner(
      icon: Icons.cancel_rounded,
      color: AppColors.error,
      title: 'Order cancelled',
      subtitle: 'Your wallet will be refunded if charged.',
      backgroundColor: AppColors.errorLight,
    );
  }

  Widget _buildOtpCard(BuildContext context) {
    final otp = widget.order.deliveryOtp;
    if (otp == null || otp.isEmpty) return const SizedBox.shrink();

    final isCompleteOrCancelled =
        widget.order.status == GasOrderStatus.delivered ||
            widget.order.status == GasOrderStatus.cancelled ||
            widget.order.status == GasOrderStatus.failed;

    if (isCompleteOrCancelled) return const SizedBox.shrink();

    final shareMsg = 'Your gas delivery OTP is: *$otp*\n\n'
        'Please give this code to the CTSTransport rider when they arrive.';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.primaryDim,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.lock_rounded,
                  color: AppColors.primary, size: 18),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Delivery OTP',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      )),
                  Text(
                    'Give this code to the rider on arrival',
                    style:
                        TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: otp
                  .split('')
                  .map((digit) => Container(
                        width: 44,
                        height: 52,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.primary),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.1),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(digit,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w900,
                                color: AppColors.primary,
                                fontFamily: 'monospace',
                              )),
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7ED),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline_rounded,
                  color: Color(0xFFD97706), size: 14),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Only share this OTP with the CTSTransport rider. Do not share with anyone else.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF92400E)),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: () => Share.share(shareMsg,
                  subject: 'CTSTransport Gas Delivery OTP'),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.share_rounded, color: Colors.white, size: 15),
                    SizedBox(width: 6),
                    Text('Share OTP',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        )),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDriverInfoCard(BuildContext context) {
    final order = widget.order;
    final hasDriver = order.driverName?.isNotEmpty == true ||
        order.driverPhone?.isNotEmpty == true;

    if (!hasDriver) return const SizedBox.shrink();

    final name = order.driverName ?? 'Your driver';
    final rating = order.driverRating ?? 0.0;

    IconData vehicleIcon = Icons.two_wheeler_rounded;

    return DriverInfoCard(
      name: name,
      rating: rating,
      vehicleType: order.driverVehicle ?? 'Gas delivery',
      vehiclePlate: null,
      price: 'GHS ${order.totalPrice.toStringAsFixed(2)}',
      vehicleIcon: vehicleIcon,
      onCall: () async {
        final phone = order.driverPhone;
        if (phone == null || phone.isEmpty) return;
        final uri = Uri(scheme: 'tel', path: phone);
        if (await canLaunchUrl(uri)) launchUrl(uri);
      },
      onChat: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Chat feature coming soon'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      onEmergency: () => _showReportSheet(context),
    );
  }

  Widget _buildOrderSummary() {
    final order = widget.order;
    final gasCost = (order.totalPrice - order.deliveryFee)
        .clamp(0, double.infinity)
        .toDouble();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primaryDim,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.local_fire_department_rounded,
                    color: AppColors.primary, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${order.cylinderSize.displayName} × ${order.quantity}',
                      style: AppTextStyles.labelLarge
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(order.refillType.displayName,
                        style: AppTextStyles.caption.copyWith(
                          color: const Color(0xFF5F6368),
                        )),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 12),
          _summaryLine('Gas cost', gasCost),
          const SizedBox(height: 8),
          _summaryLine('Delivery fee', order.deliveryFee),
          const SizedBox(height: 10),
          Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total',
                  style: AppTextStyles.labelLarge
                      .copyWith(fontWeight: FontWeight.w700)),
              Text('GHS ${order.totalPrice.toStringAsFixed(2)}',
                  style: AppTextStyles.heading4
                      .copyWith(color: AppColors.primary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryLine(String label, double amount) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: AppTextStyles.bodyMedium
                  .copyWith(color: const Color(0xFF5F6368))),
          Text('GHS ${amount.toStringAsFixed(2)}',
              style: AppTextStyles.bodyMedium),
        ],
      );

  Widget _buildActionRow(BuildContext context) {
    return Row(
      children: [
        TrackingActionButton(
          icon: Icons.phone_rounded,
          label: 'Call driver',
          onTap: () async {
            final phone = widget.order.driverPhone;
            if (phone == null || phone.isEmpty) return;
            final uri = Uri(scheme: 'tel', path: phone);
            if (await canLaunchUrl(uri)) launchUrl(uri);
          },
        ),
        const SizedBox(width: 10),
        TrackingActionButton(
          icon: Icons.share_rounded,
          label: 'Share',
          onTap: () {
            final shortId = widget.orderId.length >= 8
                ? widget.orderId.substring(0, 8).toUpperCase()
                : widget.orderId.toUpperCase();
            Share.share('Track my CTSTransport gas order #$shortId');
          },
        ),
        const SizedBox(width: 10),
        TrackingActionButton(
          icon: Icons.report_problem_rounded,
          label: 'Report',
          backgroundColor: AppColors.errorLight,
          iconColor: AppColors.error,
          onTap: () => _showReportSheet(context),
        ),
      ],
    );
  }

  void _showReportSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const TrackingDragHandle(),
            const SizedBox(height: 20),
            const Text('Report an issue', style: AppTextStyles.heading3),
            const SizedBox(height: 16),
            ...[
              'Driver not moving',
              'Wrong delivery location',
              'Cylinder issue',
              'Driver unreachable',
              'Other',
            ].map((issue) => GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                            child:
                                Text(issue, style: AppTextStyles.bodyMedium)),
                        const Icon(Icons.chevron_right_rounded,
                            color: AppColors.textTertiary, size: 16),
                      ],
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
