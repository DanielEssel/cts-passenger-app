// lib/features/delivery/delivery_tracking_screen_refactored.dart
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/marker_service.dart';
import '../../../widgets/common/shared_widgets.dart';
import '../../ride/services/route_service.dart';
import '../../ride/presentation/trip_complete_screen.dart';
import '../../tracking/widgets/tracking_constants.dart';
import '../../tracking/widgets/driver_info_card.dart';
import '../../tracking/widgets/tracking_action_button.dart';
import '../../tracking/widgets/tracking_drag_handle.dart';
import '../../tracking/widgets/tracking_map.dart';
import '../../tracking/widgets/tracking_status_banner.dart';
import '../../tracking/widgets/tracking_timeline.dart';
import '../models/delivery_request.dart';
import '../providers/delivery_provider.dart';

extension DeliveryRequestVehiclePlate on DeliveryRequest {
  String? get vehiclePlate => null;
}

class DeliveryTrackingScreen extends ConsumerWidget {
  final String deliveryId;

  const DeliveryTrackingScreen({super.key, required this.deliveryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deliveryAsync = ref.watch(deliveryStreamProvider(deliveryId));

    ref.listen(deliveryStreamProvider(deliveryId), (prev, next) {
      final prevStatus = prev?.value?.status;
      final delivery = next.value;
      if (delivery != null &&
          delivery.status == DeliveryStatus.completed &&
          prevStatus != DeliveryStatus.completed) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => TripCompleteScreen(
              tripId: delivery.id,
              collection: 'deliveries',
              serviceType: 'delivery',
              driverId: delivery.driverId ?? '',
              driverName: delivery.driverName ?? 'Your rider',
              destination: delivery.dropoffAddress,
              fare: 'GHS ${delivery.estimatedFare.toStringAsFixed(2)}',
              rideType: 'Delivery',
              driverRating: 5.0,
            ),
          ),
        );
      }
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      body: deliveryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (delivery) {
          if (delivery == null) {
            return const Center(child: Text('Delivery not found'));
          }
          return _DeliveryTrackingBody(
            delivery: delivery,
            deliveryId: deliveryId,
          );
        },
      ),
    );
  }
}

class _DeliveryTrackingBody extends ConsumerStatefulWidget {
  final DeliveryRequest delivery;
  final String deliveryId;

  const _DeliveryTrackingBody({
    required this.delivery,
    required this.deliveryId,
  });

  @override
  ConsumerState<_DeliveryTrackingBody> createState() =>
      _DeliveryTrackingBodyState();
}

class _DeliveryTrackingBodyState extends ConsumerState<_DeliveryTrackingBody> {
  late final RouteService _routeService;
  Set<Polyline> _polylines = {};
  bool _routeFetched = false;

  static const _steps = [
    DeliveryStatus.driverAssigned,
    DeliveryStatus.pickupEnroute,
    DeliveryStatus.arrivedAtPickup,
    DeliveryStatus.packagePicked,
    DeliveryStatus.deliveryEnroute,
    DeliveryStatus.arrivedAtDropoff,
    DeliveryStatus.completed,
  ];

  static const _stepIcons = <DeliveryStatus, IconData>{
    DeliveryStatus.driverAssigned: Icons.person_rounded,
    DeliveryStatus.pickupEnroute: Icons.directions_rounded,
    DeliveryStatus.arrivedAtPickup: Icons.location_on_rounded,
    DeliveryStatus.packagePicked: Icons.inventory_2_rounded,
    DeliveryStatus.deliveryEnroute: Icons.local_shipping_rounded,
    DeliveryStatus.arrivedAtDropoff: Icons.location_on_rounded,
    DeliveryStatus.completed: Icons.check_circle_rounded,
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
      widget.delivery.pickupLocation.latitude,
      widget.delivery.pickupLocation.longitude,
    );
    final dropoff = LatLng(
      widget.delivery.dropoffLocation.latitude,
      widget.delivery.dropoffLocation.longitude,
    );

    final result = await _routeService.getRoute(pickup, dropoff);
    if (result != null && result.points.isNotEmpty && mounted) {
      setState(() {
        _polylines = {
          Polyline(
            polylineId: const PolylineId('main_route'),
            points: result.points,
            color: AppColors.primary,
            width: TrackingConstants.polylineWidth.toInt(),
            geodesic: TrackingConstants.polylineGeodesic,
            patterns: const [],
          ),
          // Shadow polyline
          Polyline(
            polylineId: const PolylineId('shadow_route'),
            points: result.points,
            color: Colors.black.withValues(alpha: 0.1),
            width: TrackingConstants.polylineShadowWidth.toInt(),
            geodesic: TrackingConstants.polylineGeodesic,
            patterns: const [],
          ),
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final delivery = widget.delivery;
    final isCompleted = delivery.status == DeliveryStatus.completed;
    final isCancelled = delivery.status == DeliveryStatus.cancelled;

    final pickup = LatLng(
      delivery.pickupLocation.latitude,
      delivery.pickupLocation.longitude,
    );
    final dropoff = LatLng(
      delivery.dropoffLocation.latitude,
      delivery.dropoffLocation.longitude,
    );
    final driverLocation = delivery.driverLocation != null
        ? LatLng(
            delivery.driverLocation!.latitude,
            delivery.driverLocation!.longitude,
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
  child: _buildStatusHeader(delivery),
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
                  const BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 20,
                  offset: const Offset(0, -6),
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
                          _buildTimeline(delivery),
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
                        if (!isCompleted && !isCancelled)
                          _buildActionRow(context),
                        if (isCompleted || isCancelled) ...[
                          const SizedBox(height: 12),
                          PrimaryButton(
                            label: 'Back to home',
                            onTap: () => Navigator.of(context,
                                    rootNavigator: true)
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

  // In delivery_tracking_screen.dart - update the map usage

Widget _buildTrackingMap(
  LatLng pickup,
  LatLng dropoff,
  LatLng? driverLocation,
) {
  return TrackingMap(
    pickup: pickup,
    dropoff: dropoff,
    driverLocation: driverLocation,
    driverHeading: widget.delivery.driverHeading ?? 0,
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
      widget.delivery.pickupLocation.latitude,
      widget.delivery.pickupLocation.longitude,
    );
    final dropoff = LatLng(
      widget.delivery.dropoffLocation.latitude,
      widget.delivery.dropoffLocation.longitude,
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

  Widget _buildStatusHeader(DeliveryRequest delivery) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.green,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.amber.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
          const Icon(Icons.inventory_2_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              delivery.status.passengerDisplayName,
              style: AppTextStyles.labelLarge.copyWith(color: Colors.white),
            ),
          ),
          if (delivery.status.isActive &&
              delivery.status != DeliveryStatus.completed)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Live',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    ),
  ),
);
  }

  Widget _buildTimeline(DeliveryRequest delivery) {
    final currentIndex = _steps.indexOf(delivery.status);

    final timelineItems = _steps.asMap().entries.map((entry) {
      final index = entry.key;
      final status = entry.value;
      return TrackingTimelineItem(
        icon: _stepIcons[status] ?? Icons.circle_outlined,
        label: status.passengerDisplayName,
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
      title: 'Parcel delivered!',
      subtitle: 'Delivered to ${widget.delivery.dropoffAddress}',
    );
  }

  Widget _buildCancelledBanner() {
    return TrackingStatusBanner(
      icon: Icons.cancel_rounded,
      color: AppColors.error,
      title: 'Delivery cancelled',
      subtitle: 'Your wallet will be refunded if charged.',
      backgroundColor: AppColors.errorLight,
    );
  }

  Widget _buildOtpCard(BuildContext context) {
    final otp = widget.delivery.deliveryOtp;
    if (otp == null || otp.isEmpty) return const SizedBox.shrink();
    if (widget.delivery.status == DeliveryStatus.completed ||
        widget.delivery.status == DeliveryStatus.cancelled) {
      return const SizedBox.shrink();
    }

    final receiverName = widget.delivery.receiverName ?? 'Recipient';
    final receiverPhone = widget.delivery.receiverPhone ?? '';

    final shareMsg = 'Hi $receiverName, your delivery OTP is: *$otp*\n\n'
        'Please give this code to the delivery rider when they arrive. '
        'CTSTransport Delivery';

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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Delivery OTP',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      )),
                  const Text('Share this code with the recipient',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textSecondary)),
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
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
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
            child: Row(children: [
              const Icon(Icons.info_outline_rounded,
                  color: Color(0xFFD97706), size: 14),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'The rider will ask $receiverName for this code to complete delivery.',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF92400E)),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: () async {
                  final waUrl = Uri.parse(
                      'https://wa.me/${receiverPhone.replaceAll('+', '')}?text=${Uri.encodeComponent(shareMsg)}');
                  if (await canLaunchUrl(waUrl)) {
                    await launchUrl(waUrl,
                        mode: LaunchMode.externalApplication);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF25D366),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_rounded, color: Colors.white, size: 15),
                      SizedBox(width: 6),
                      Text('Send via WhatsApp',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          )),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => Share.share(shareMsg,
                  subject: 'Your CTSTransport Delivery OTP'),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Row(children: [
                  Icon(Icons.share_rounded,
                      color: AppColors.textSecondary, size: 15),
                  SizedBox(width: 6),
                  Text('Share',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      )),
                ]),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildDriverInfoCard(BuildContext context) {
    final delivery = widget.delivery;
    final name = delivery.driverName ?? 'Your rider';
    final rating = delivery.driverRating ?? 0.0;

    IconData vehicleIcon;
    if (delivery.vehicleType == 'Aboboya') {
      vehicleIcon = Icons.electric_rickshaw_rounded;
    } else if (delivery.vehicleType == 'Mini Truck') {
      vehicleIcon = Icons.local_shipping_rounded;
    } else {
      vehicleIcon = Icons.two_wheeler_rounded;
    }

    return DriverInfoCard(
      name: name,
      rating: rating,
      vehicleType: delivery.vehicleType,
      vehiclePlate: delivery.vehiclePlate,
      price: 'GHS ${delivery.estimatedFare.toStringAsFixed(2)}',
      vehicleIcon: vehicleIcon,
      onCall: () async {
        final phone = delivery.driverPhone;
        if (phone == null) return;
        final uri = Uri(scheme: 'tel', path: phone);
        if (await canLaunchUrl(uri)) launchUrl(uri);
      },
      onChat: () {
        // Implement chat functionality
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

  Widget _buildActionRow(BuildContext context) {
    return Row(
      children: [
        TrackingActionButton(
          icon: Icons.phone_rounded,
          label: 'Call rider',
          onTap: () async {
            final phone = widget.delivery.driverPhone;
            if (phone == null) return;
            final uri = Uri(scheme: 'tel', path: phone);
            if (await canLaunchUrl(uri)) launchUrl(uri);
          },
        ),
        const SizedBox(width: 10),
        TrackingActionButton(
          icon: Icons.share_rounded,
          label: 'Share',
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Tracking link copied'),
              duration: Duration(seconds: 2),
            ),
          ),
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
              'Rider not moving',
              'Wrong pickup location',
              'Parcel damaged',
              'Rider unreachable',
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
                            child: Text(issue, style: AppTextStyles.bodyMedium)),
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