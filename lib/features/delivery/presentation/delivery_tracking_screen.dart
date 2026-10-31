// lib/features/delivery/presentation/delivery_tracking_screen.dart
//
// The passenger's live delivery screen. What it says and offers comes only
// from the delivery's stored status (deliveryTrackingView). Ended, unknown
// and missing deliveries get their own screen with no tracking controls.

import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:flutter/material.dart';
import '../../../core/theme/cts_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../tracking/data/completion_code_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/utils/phone_launcher.dart';
import '../../../core/services/marker_service.dart';
import '../../ride/services/route_service.dart';
import '../../ride/presentation/trip_complete_screen.dart';
import '../../tracking/domain/tracking_view.dart';
import '../../tracking/widgets/passenger_tracking_panel.dart';
import '../../tracking/widgets/tracking_constants.dart';
import '../../tracking/widgets/tracking_map.dart';
import '../models/delivery_request.dart';
import '../providers/delivery_provider.dart';

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
        error: (e, _) => CtsErrorState(
          title: "Can't load your delivery",
          message: 'Check your connection. Your delivery request is not '
              'affected.',
          onRetry: () => ref.invalidate(deliveryStreamProvider(deliveryId)),
          onBack: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
        ),
        data: (delivery) {
          if (delivery == null) {
            return TrackingEndedScreen(
              view: const TrackingView(
                phase: TrackingPhase.ended,
                icon: Icons.search_off_rounded,
                headline: 'Delivery not found',
                detail: 'This delivery may have been removed. You can '
                    'check your past deliveries in History.',
              ),
              onHome: () => Navigator.of(context, rootNavigator: true)
                  .pushNamedAndRemoveUntil(AppRoutes.shell, (_) => false),
            );
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
  /// The receiver's completion code: the order's own (older orders) or the
  /// server-held one (completion_code_provider.dart). Set in build.
  String? _code;

  late final RouteService _routeService;
  Set<Polyline> _polylines = {};
  bool _routeFetched = false;

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

  void _goHome() => Navigator.of(context, rootNavigator: true)
      .pushNamedAndRemoveUntil(AppRoutes.shell, (_) => false);

  void _getHelp() => Navigator.of(context, rootNavigator: true)
      .pushNamed(AppRoutes.helpSupport);

  void _callDriver() => openPhoneAction(
        action: PhoneAction.call,
        number: widget.delivery.driverPhone,
        label: 'your driver',
        messenger: ScaffoldMessenger.maybeOf(context),
      );

  @override
  Widget build(BuildContext context) {
    final delivery = widget.delivery;
    _code = completionCodeFor(ref, 'deliveries', delivery.id, delivery.deliveryOtp);
    final hasOtp = (_code ?? '').isNotEmpty;
    final view = deliveryTrackingView(
      delivery.rawStatus ?? delivery.status.firestoreValue,
      hasOtp: hasOtp,
    );

    if (view.phase == TrackingPhase.ended ||
        view.phase == TrackingPhase.unknown) {
      return TrackingEndedScreen(view: view, onHome: _goHome);
    }

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
    final showDriver = view.hasDriver && delivery.driverId != null;
    final phone = (delivery.driverPhone ?? '').trim();
    final showCode = hasOtp && !view.isOver;

    SystemChrome.setSystemUIOverlayStyle(TrackingConstants.lightStatusBar);

    return TrackingLayout(
      map: Stack(
        children: [
          Positioned.fill(
            child: _buildTrackingMap(pickup, dropoff, driverLocation),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 16,
            child: TrackingMapButton(
              icon: Icons.arrow_back_rounded,
              label: 'Back',
              onTap: () => Navigator.of(context).maybePop(),
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
                  hasLocation: driverLocation != null,
                  updatedAt: delivery.driverLocationAt,
                ),
              ),
            ),
        ],
      ),
      actions: showDriver && view.phase == TrackingPhase.active
          ? TrackingActionBar(
              primary: TrackingAction(
                label: 'Call driver',
                icon: Icons.phone_rounded,
                onTap: phone.isEmpty ? null : _callDriver,
              ),
              secondary: showCode
                  ? TrackingAction(
                      label: 'Share code',
                      icon: Icons.share_rounded,
                      onTap: () => Share.share(_otpShareMessage(),
                          subject: 'Your CTSGo delivery code'),
                    )
                  : null,
            )
          : null,
      children: [
        TrackingStatusHeader(view: view),
        const SizedBox(height: 18),
        TrackingProgressBar(steps: view.steps, current: view.stepIndex),
        const SizedBox(height: 18),
        if (showDriver) ...[
          TrackingDriverCard(
            name: delivery.driverName,
            rating: delivery.driverRating,
            vehicle: delivery.vehicleType,
          ),
          if (phone.isEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              "Your driver's phone number isn't available.",
              style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 12),
        ],
        if (showCode) ...[
          _buildOtpCard(context),
          const SizedBox(height: 12),
        ],
        TrackingRouteSummary(
          fromLabel: 'Pickup',
          fromAddress: delivery.pickupAddress,
          toLabel: 'Drop-off',
          toAddress: delivery.dropoffAddress,
          emphasiseTo: view.heading == TrackingHeading.dropoff,
          priceLabel: 'GHS ${delivery.estimatedFare.toStringAsFixed(2)}',
        ),
        const SizedBox(height: 12),
        Text(
          [
            delivery.parcelType,
            if (delivery.weightRange.trim().isNotEmpty) delivery.weightRange,
            if (delivery.isFragile) 'Fragile',
          ].join('  ·  '),
          style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: _getHelp,
            icon: const Icon(Icons.support_agent_rounded, size: 20),
            label: const Text('Get help with this delivery'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              minimumSize: const Size(48, 48),
              textStyle:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

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
      padding: const EdgeInsets.only(bottom: 48),
      controlsBottomOffset: 12,
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
        infoWindow: const InfoWindow(title: 'Pickup'),
      ),
      Marker(
        markerId: const MarkerId('dropoff'),
        position: dropoff,
        icon: markerService.dropoff(),
        anchor: const Offset(0.5, 1.0),
        infoWindow: const InfoWindow(title: 'Drop-off'),
      ),
      if (widget.delivery.driverLocation != null)
        Marker(
          markerId: const MarkerId('driver'),
          position: LatLng(
            widget.delivery.driverLocation!.latitude,
            widget.delivery.driverLocation!.longitude,
          ),
          icon: markerService.vehicle('delivery'),
          anchor: const Offset(0.5, 0.5),
          rotation: widget.delivery.driverHeading ?? 0,
          flat: true,
          infoWindow: const InfoWindow(title: 'Driver'),
        ),
    };
  }

  String _otpShareMessage() {
    final receiverName = widget.delivery.receiverName ?? 'Recipient';
    return 'Hi $receiverName, your delivery OTP is: *$_code*\n\n'
        'Please give this code to the delivery rider when they arrive. '
        'CTSGo Delivery';
  }

  Widget _buildOtpCard(BuildContext context) {
    final otp = _code;
    if (otp == null || otp.isEmpty) return const SizedBox.shrink();
    if (widget.delivery.status == DeliveryStatus.completed ||
        widget.delivery.status == DeliveryStatus.cancelled) {
      return const SizedBox.shrink();
    }

    final receiverName = widget.delivery.receiverName ?? 'Recipient';
    final receiverPhone = widget.delivery.receiverPhone ?? '';

    final shareMsg = _otpShareMessage();

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
                  const Text('Delivery code',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      )),
                  const Text('Share this code with the receiver',
                      style: TextStyle(
                          fontSize: 14, color: AppColors.textSecondary)),
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
              color: CtsTheme.warningTint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded,
                  color: CtsTheme.warning, size: 14),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'The driver will ask $receiverName for this code to complete delivery.',
                  style: const TextStyle(fontSize: 14, color: CtsTheme.warning),
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
                  // Forest on WhatsApp green is 6.2:1 (white was 2.0:1).
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_rounded,
                          color: CtsTheme.onVivid, size: 15),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text('Send via WhatsApp',
                            semanticsLabel: 'Send code via WhatsApp',
                            style: TextStyle(
                              color: CtsTheme.onVivid,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            )),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () =>
                  Share.share(shareMsg, subject: 'Your CTSGo Delivery OTP'),
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
}
