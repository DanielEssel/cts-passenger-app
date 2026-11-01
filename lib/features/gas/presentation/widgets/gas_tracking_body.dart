// lib/features/gas/presentation/widgets/gas_tracking_body.dart
//
// The passenger's live Gas tracking experience, shared by both Gas order
// models: the original gas_orders (GasOrderTrackingScreen) and supplier
// orders (GasSupplierTrackingScreen). Each screen adapts its own order into
// a [GasTrackingData]; what is said and offered comes from its TrackingView,
// which each model derives only from its own stored status.
//
// The map shows the customer and, only while a driver is on the job and the
// order carries their position, the driver. Nothing here invents a driver,
// a location or a contact the order does not hold.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/marker_service.dart';
import '../../../../core/theme/cts_theme.dart';
import '../../../../core/utils/phone_launcher.dart';
import '../../../ride/services/route_service.dart';
import '../../../tracking/domain/tracking_view.dart';
import '../../../tracking/widgets/passenger_tracking_panel.dart';
import '../../../tracking/widgets/tracking_constants.dart';
import '../../../tracking/widgets/tracking_map.dart';
import '../../../../core/utils/cedi_format.dart';

/// One labelled line under the progress bar ("Refill station: …").
typedef GasTrackingInfo = ({IconData icon, String label, String value});

/// The order summary card: what was ordered and its price lines.
class GasTrackingSummary {
  final String title;
  final String subtitle;
  final List<(String, double)> lines;

  /// Null when the order holds no total ("—").
  final double? total;
  const GasTrackingSummary(
      {required this.title,
      required this.subtitle,
      required this.lines,
      required this.total});
}

/// Cancelling from the tracking screen, where the order's model allows it.
class GasTrackingCancel {
  final String title;
  final String message;
  final Future<void> Function() run;

  /// The message for a failed cancel.
  final String Function(Object error) errorText;
  const GasTrackingCancel(
      {required this.title,
      required this.message,
      required this.run,
      required this.errorText});
}

/// Everything the shared tracking body shows, adapted from one order.
class GasTrackingData {
  final String orderId;
  final TrackingView view;

  /// Changes whenever the order's status does: the route is redrawn once per value.
  final String? statusKey;

  /// The delivery point; null when the order holds none (no map then).
  final LatLng? customer;

  /// The driver's live position, only when the order carries one.
  final LatLng? driver;
  final double driverHeading;
  final DateTime? driverLocationAt;

  /// Show the driver card: a driver has accepted, by the order's own record.
  final bool showDriverCard;
  final String? driverName;
  final double? driverRating;
  final String? driverVehicle;
  final String driverRole;

  /// Whether this order model offers contacting the driver at all.
  final bool canContactDriver;
  final String? driverPhone;

  /// The delivery code, when the customer should have it.
  final String? code;
  final List<GasTrackingInfo> info;
  final String deliveryAddress;
  final GasTrackingSummary summary;
  final GasTrackingCancel? cancel;

  /// The action bar once the order is completed and shown here (null: none).
  final TrackingAction? completedAction;

  const GasTrackingData({
    required this.orderId,
    required this.view,
    required this.statusKey,
    required this.customer,
    required this.deliveryAddress,
    required this.summary,
    this.driver,
    this.driverHeading = 0,
    this.driverLocationAt,
    this.showDriverCard = false,
    this.driverName,
    this.driverRating,
    this.driverVehicle,
    this.driverRole = 'Your driver',
    this.canContactDriver = true,
    this.driverPhone,
    this.code,
    this.info = const [],
    this.cancel,
    this.completedAction,
  });
}

class GasTrackingBody extends StatefulWidget {
  final GasTrackingData data;
  const GasTrackingBody({super.key, required this.data});

  @override
  State<GasTrackingBody> createState() => _GasTrackingBodyState();
}

class _GasTrackingBodyState extends State<GasTrackingBody> {
  final _routeService = RouteService();
  Set<Polyline> _polylines = {};
  String? _routeFor; // the status the drawn route belongs to
  bool _routeBusy = false;

  GasTrackingData get _d => widget.data;

  @override
  void initState() {
    super.initState();
    _syncRoute();
  }

  @override
  void didUpdateWidget(GasTrackingBody old) {
    super.didUpdateWidget(old);
    _syncRoute();
  }

  /// Draws the driver → customer route only on legs heading to the
  /// customer, once per status. The refill leg has no route: no station
  /// coordinates are stored.
  Future<void> _syncRoute() async {
    final view = _d.view;
    final status = _d.statusKey;
    final driver = _d.driver;
    final customer = _d.customer;
    if (view.heading != TrackingHeading.customer || !view.tracksDriver) {
      // Runs from initState/didUpdateWidget, which always rebuild after.
      _polylines = {};
      _routeFor = null;
      return;
    }
    if (driver == null ||
        customer == null ||
        _routeBusy ||
        _routeFor == status) {
      return;
    }
    _routeBusy = true;
    try {
      final result = await _routeService.getRoute(driver, customer);
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
        number: _d.driverPhone,
        label: 'your driver',
        messenger: ScaffoldMessenger.maybeOf(context),
      );

  String _otpShareMessage() => 'Your gas delivery OTP is: *${_d.code}*\n\n'
      'Please give this code to the CTSGo rider when they arrive.';

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final view = d.view;

    if (view.phase == TrackingPhase.ended ||
        view.phase == TrackingPhase.unknown) {
      return TrackingEndedScreen(view: view, onHome: _goHome);
    }

    final driver = d.driver;
    final customer = d.customer;
    final showDriver = d.showDriverCard;
    final phone = (d.driverPhone ?? '').trim();
    final showCode = (d.code ?? '').isNotEmpty && !view.isOver;

    SystemChrome.setSystemUIOverlayStyle(TrackingConstants.lightStatusBar);

    return TrackingLayout(
      map: Stack(
        children: [
          Positioned.fill(
            child: customer == null
                ? const ColoredBox(color: CtsTheme.surfaceAlt)
                : TrackingMap(
                    pickup: customer,
                    dropoff: customer,
                    driverLocation: view.tracksDriver ? driver : null,
                    driverHeading: d.driverHeading,
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
                  updatedAt: d.driverLocationAt,
                ),
              ),
            ),
        ],
      ),
      actions: _actions(view, showDriver, showCode, phone),
      children: [
        TrackingStatusHeader(view: view),
        const SizedBox(height: 18),
        TrackingProgressBar(steps: view.steps, current: view.stepIndex),
        const SizedBox(height: 18),
        for (final line in d.info) ...[
          _infoLine(line.icon, line.label, line.value),
          const SizedBox(height: 12),
        ],
        if (showDriver) ...[
          TrackingDriverCard(
            name: d.driverName,
            rating: d.driverRating,
            vehicle: d.driverVehicle,
            roleLabel: d.driverRole,
          ),
          if (d.canContactDriver && phone.isEmpty) ...[
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
          fromAddress: d.deliveryAddress,
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
        if (view.canCancel && d.cancel != null)
          TrackingCancelLink(
            label: 'Cancel order',
            busy: _cancelling,
            onTap: _confirmCancel,
          ),
      ],
    );
  }

  /// Call (and share the code) while a driver is on the job; where the
  /// order model offers no driver contact, sharing the code alone.
  Widget? _actions(
      TrackingView view, bool showDriver, bool showCode, String phone) {
    if (view.phase == TrackingPhase.completed && _d.completedAction != null) {
      return TrackingActionBar(primary: _d.completedAction!);
    }
    if (!(showDriver || view.tracksDriver) ||
        view.phase != TrackingPhase.active) {
      return null;
    }
    final share = showCode
        ? TrackingAction(
            label: 'Share code',
            icon: Icons.share_rounded,
            onTap: () => Share.share(_otpShareMessage(),
                subject: 'CTSGo Gas Delivery OTP'),
          )
        : null;
    if (_d.canContactDriver) {
      if (!showDriver) return null;
      return TrackingActionBar(
        primary: TrackingAction(
          label: 'Call driver',
          icon: Icons.phone_rounded,
          onTap: phone.isEmpty ? null : _callDriver,
        ),
        secondary: share,
      );
    }
    return share == null ? null : TrackingActionBar(primary: share);
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
    final driver = _d.driver;
    final customer = _d.customer!;
    return {
      Marker(
        markerId: const MarkerId('customer'),
        position: customer,
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
          rotation: _d.driverHeading,
          flat: true,
          infoWindow: const InfoWindow(title: 'Driver'),
        ),
    };
  }

  // Cancel is offered only where the order's model allows it (the view's
  // canCancel); the order's own server or repository re-checks it.
  bool _cancelling = false;

  Future<void> _confirmCancel() async {
    final cancel = _d.cancel;
    if (_cancelling || cancel == null) return;
    setState(() => _cancelling = true);
    try {
      final confirmed = await showTrackingConfirm(
        context,
        title: cancel.title,
        message: cancel.message,
        confirmLabel: 'Cancel order',
        keepLabel: 'Keep order',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
      await cancel.run();
      // The order stream switches this screen to its cancelled state.
    } catch (e) {
      debugPrint('Gas cancel failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(cancel.errorText(e)),
      ));
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  Widget _buildOtpCard(BuildContext context) {
    final otp = _d.code;
    if (otp == null || otp.isEmpty) return const SizedBox.shrink();

    if (_d.view.isOver) return const SizedBox.shrink();

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
            key: const Key('gas-tracking-code'),
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
    final s = _d.summary;
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
                      s.title,
                      style: AppTextStyles.labelLarge
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(s.subtitle,
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
          for (var i = 0; i < s.lines.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _summaryLine(s.lines[i].$1, s.lines[i].$2),
          ],
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
                child: Text(
                    s.total == null
                        ? '—'
                        : formatCedis(s.total!),
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
            child: Text(formatCedis(amount),
                textAlign: TextAlign.end, style: AppTextStyles.bodyMedium),
          ),
        ],
      );
}
