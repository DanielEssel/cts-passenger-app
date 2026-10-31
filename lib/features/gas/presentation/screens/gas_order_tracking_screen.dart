// lib/features/gas/presentation/screens/gas_order_tracking_screen.dart
//
// The passenger's live gas order screen. What it says and offers comes only
// from the order's stored status and its own fulfilment flow
// (gasTrackingView): a simple drop-off, or Pickup & Return (collect → refill
// station → return). The order stores only the customer's location, so the
// map shows the customer and the driver; no station position is invented.
// Ended, unknown and missing orders get their own screen.

import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:flutter/material.dart';
import '../../../../core/theme/cts_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../tracking/data/completion_code_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/utils/phone_launcher.dart';

import '../../../../core/constants/app_colors.dart';
import '../../repositories/gas_order_repository.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/marker_service.dart';
import '../../../ride/presentation/trip_complete_screen.dart';
import '../../../ride/services/route_service.dart';
import '../../../tracking/domain/tracking_view.dart';
import '../../../tracking/widgets/passenger_tracking_panel.dart';
import '../../../tracking/widgets/tracking_constants.dart';
import '../../../tracking/widgets/tracking_map.dart';
import '../../models/gas_refill_request.dart';
import '../../providers/gas_order_providers.dart';

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
              destination: order.deliveryAddress,
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
        error: (e, _) => CtsErrorState(
          title: "Can't load your gas order",
          message: 'Check your connection. Your order is not affected.',
          onRetry: () => ref.invalidate(gasOrderStreamProvider(orderId)),
          onBack: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
        ),
        data: (order) {
          if (order == null) {
            return TrackingEndedScreen(
              view: const TrackingView(
                phase: TrackingPhase.ended,
                icon: Icons.search_off_rounded,
                headline: 'Order not found',
                detail: 'This order may have been removed. You can check '
                    'your past orders in History.',
              ),
              onHome: () => Navigator.of(context, rootNavigator: true)
                  .pushNamedAndRemoveUntil(AppRoutes.shell, (_) => false),
            );
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
  /// The receiver's completion code: the order's own (older orders) or the
  /// server-held one (completion_code_provider.dart). Set in build.
  String? _code;

  final _routeService = RouteService();
  Set<Polyline> _polylines = {};
  String? _routeFor; // the status the drawn route belongs to
  bool _routeBusy = false;

  TrackingView get _view => gasTrackingView(
        widget.order.rawStatus ?? widget.order.status.firestoreValue,
        refillType: widget.order.refillType.firestoreValue,
        hasOtp: (_code ?? '').isNotEmpty,
      );

  LatLng get _customer => LatLng(
        widget.order.deliveryLocation.latitude,
        widget.order.deliveryLocation.longitude,
      );

  LatLng? get _driver => widget.order.driverLocation == null
      ? null
      : LatLng(widget.order.driverLocation!.latitude,
          widget.order.driverLocation!.longitude);

  @override
  void initState() {
    super.initState();
    _syncRoute();
  }

  @override
  void didUpdateWidget(_GasTrackingBody old) {
    super.didUpdateWidget(old);
    _syncRoute();
  }

  /// Draws the driver → customer route only on legs heading to the
  /// customer, once per status. The refill leg has no route: no station
  /// coordinates are stored.
  Future<void> _syncRoute() async {
    final view = _view;
    final status = widget.order.rawStatus;
    final driver = _driver;
    if (view.heading != TrackingHeading.customer || !view.tracksDriver) {
      // Runs from initState/didUpdateWidget, which always rebuild after.
      _polylines = {};
      _routeFor = null;
      return;
    }
    if (driver == null || _routeBusy || _routeFor == status) return;
    _routeBusy = true;
    try {
      final result = await _routeService.getRoute(driver, _customer);
      if (result != null && result.points.isNotEmpty && mounted) {
        setState(() {
          _routeFor = status;
          _polylines = {
            Polyline(
              polylineId: const PolylineId('main_route'),
              points: result.points,
              color: AppColors.primary.withValues(alpha: 0.9),
              width: TrackingConstants.polylineWidth.toInt(),
              geodesic: TrackingConstants.polylineGeodesic,
              jointType: JointType.round,
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
            ),
          };
        });
      }
    } catch (e) {
      debugPrint('Gas route fetch failed: $e');
    } finally {
      _routeBusy = false;
    }
  }

  void _goHome() => Navigator.of(context, rootNavigator: true)
      .pushNamedAndRemoveUntil(AppRoutes.shell, (_) => false);

  void _getHelp() => Navigator.of(context, rootNavigator: true)
      .pushNamed(AppRoutes.helpSupport);

  void _callDriver() => openPhoneAction(
        action: PhoneAction.call,
        number: widget.order.driverPhone,
        label: 'your driver',
        messenger: ScaffoldMessenger.maybeOf(context),
      );

  String _otpShareMessage() =>
      'Your gas delivery OTP is: *$_code*\n\n'
      'Please give this code to the CTSGo rider when they arrive.';

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    _code = completionCodeFor(ref, 'gas_orders', order.id, order.deliveryOtp);
    final view = _view;

    if (view.phase == TrackingPhase.ended ||
        view.phase == TrackingPhase.unknown) {
      return TrackingEndedScreen(view: view, onHome: _goHome);
    }

    final driver = _driver;
    final showDriver = view.hasDriver && order.driverId != null;
    final phone = (order.driverPhone ?? '').trim();
    final showCode = (_code ?? '').isNotEmpty && !view.isOver;
    final station = order.preferredStationAddress?.trim() ?? '';
    final onRefillLeg =
        const {'pickedUp', 'atStation', 'refilling'}.contains(order.rawStatus);

    SystemChrome.setSystemUIOverlayStyle(TrackingConstants.lightStatusBar);

    return TrackingLayout(
      map: Stack(
        children: [
          Positioned.fill(
            child: TrackingMap(
              pickup: _customer,
              dropoff: _customer,
              driverLocation: view.tracksDriver ? driver : null,
              driverHeading: order.driverHeading ?? 0,
              polylines: _polylines,
              additionalMarkers: _buildMarkers(view),
              padding: const EdgeInsets.only(bottom: 48),
              controlsBottomOffset: 12,
              myLocationEnabled: true,
              showControls: true,
            ),
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
                  hasLocation: driver != null,
                  updatedAt: order.driverLocationAt,
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
                          subject: 'CTSGo Gas Delivery OTP'),
                    )
                  : null,
            )
          : null,
      children: [
        TrackingStatusHeader(view: view),
        const SizedBox(height: 18),
        TrackingProgressBar(steps: view.steps, current: view.stepIndex),
        const SizedBox(height: 18),
        if (onRefillLeg && station.isNotEmpty) ...[
          _infoLine(Icons.local_gas_station_rounded, 'Refill station', station),
          const SizedBox(height: 12),
        ],
        if (showDriver) ...[
          TrackingDriverCard(
            name: order.driverName,
            rating: order.driverRating,
            vehicle: order.driverVehicle,
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
          fromLabel: 'Delivery address',
          fromAddress: order.deliveryAddress,
        ),
        const SizedBox(height: 12),
        _buildOrderSummary(),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: _getHelp,
            icon: const Icon(Icons.support_agent_rounded, size: 20),
            label: const Text('Get help with this order'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              minimumSize: const Size(48, 48),
              textStyle:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        if (view.canCancel)
          TrackingCancelLink(
            label: 'Cancel order',
            busy: _cancelling,
            onTap: _confirmCancel,
          ),
      ],
    );
  }

  Widget _infoLine(IconData icon, String label, String value) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: '$label: ',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                TextSpan(text: value),
              ]),
              style: const TextStyle(
                  fontSize: 15, color: AppColors.textPrimary, height: 1.4),
            ),
          ),
        ],
      );

  /// The order stores one location: the customer's. The driver is shown
  /// only while they are on the job.
  Set<Marker> _buildMarkers(TrackingView view) {
    final markerService = MarkerService.instance;
    final driver = _driver;
    return {
      Marker(
        markerId: const MarkerId('customer'),
        position: _customer,
        icon: markerService.dropoff(),
        anchor: const Offset(0.5, 1.0),
        infoWindow: const InfoWindow(title: 'Delivery address'),
      ),
      if (driver != null && view.tracksDriver)
        Marker(
          markerId: const MarkerId('driver'),
          position: driver,
          icon: markerService.vehicle('gas'),
          anchor: const Offset(0.5, 0.5),
          rotation: widget.order.driverHeading ?? 0,
          flat: true,
          infoWindow: const InfoWindow(title: 'Driver'),
        ),
    };
  }

  // Cancel is offered only while no driver has accepted (pendingApproval).
  // The repository re-checks that in a transaction; the backend refunds any
  // wallet hold when the order becomes cancelled.
  bool _cancelling = false;

  Future<void> _confirmCancel() async {
    if (_cancelling) return;
    setState(() => _cancelling = true);
    try {
      final confirmed = await showTrackingConfirm(
        context,
        title: 'Cancel this gas order?',
        message: 'No driver has accepted it yet. Any amount held from your '
            'wallet for this order is returned.',
        confirmLabel: 'Cancel order',
        keepLabel: 'Keep order',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
      await ref.read(gasOrderRepositoryProvider).cancelPendingOrder(
            widget.orderId,
            reason: 'Cancelled by customer before a driver accepted',
          );
      // The order stream switches this screen to its cancelled state.
    } on GasOrderException catch (e) {
      debugPrint('Gas cancel failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.code == 'not-pending'
            ? 'A driver has already accepted this order, so it can no longer be cancelled here.'
            : "Couldn't cancel. Check your connection and try again."),
      ));
    } catch (e) {
      debugPrint('Gas cancel failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Couldn't cancel. Check your connection and try again."),
      ));
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  Widget _buildOtpCard(BuildContext context) {
    final otp = _code;
    if (otp == null || otp.isEmpty) return const SizedBox.shrink();

    final isCompleteOrCancelled =
        widget.order.status == GasOrderStatus.delivered ||
            widget.order.status == GasOrderStatus.cancelled ||
            widget.order.status == GasOrderStatus.failed;

    if (isCompleteOrCancelled) return const SizedBox.shrink();

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
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Delivery code',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      )),
                  Text(
                    'Give this code to the driver when you receive your gas',
                    style:
                        TextStyle(fontSize: 14, color: AppColors.textSecondary),
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
              color: CtsTheme.warningTint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline_rounded,
                  color: CtsTheme.warning, size: 14),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Only share this OTP with the CTSGo rider. Do not share with anyone else.',
                  style: TextStyle(fontSize: 14, color: CtsTheme.warning),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: () =>
                  Share.share(shareMsg, subject: 'CTSGo Gas Delivery OTP'),
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
                          color: CtsTheme.textSecondary,
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
              Flexible(
                child: Text('Total',
                    style: AppTextStyles.labelLarge
                        .copyWith(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text('GHS ${order.totalPrice.toStringAsFixed(2)}',
                    textAlign: TextAlign.end,
                    style: AppTextStyles.heading4
                        .copyWith(color: AppColors.primary)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryLine(String label, double amount) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(label,
                style: AppTextStyles.bodyMedium
                    .copyWith(color: CtsTheme.textSecondary)),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text('GHS ${amount.toStringAsFixed(2)}',
                textAlign: TextAlign.end, style: AppTextStyles.bodyMedium),
          ),
        ],
      );
}
