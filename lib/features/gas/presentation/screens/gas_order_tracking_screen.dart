// lib/features/gas/presentation/screens/gas_order_tracking_screen.dart
//
// Rebuilt to mirror DeliveryTrackingScreen exactly: Column layout, 260px map
// header with an overlaid status pill, a vertical step timeline, border-based
// cards (OTP, rider, order summary), and a Call/Share/Report action row.
// Same AppColors / AppTextStyles design system so Ride, Delivery and Gas feel
// like one app. Timeline adapts to the order's refill type (3-step simple vs
// 7-step pickup & return), reconciled to the real GasOrderStatus flow.

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../../widgets/common/shared_widgets.dart';
import '../../models/gas_refill_request.dart';
import '../../providers/gas_order_providers.dart';
import '../../../ride/services/route_service.dart';
import 'package:cts_transport_app/core/services/marker_service.dart';
import 'package:cts_transport_app/features/ride/presentation/trip_complete_screen.dart';

class GasOrderTrackingScreen extends ConsumerWidget {
  final String orderId;

  const GasOrderTrackingScreen({super.key, required this.orderId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderAsync = ref.watch(gasOrderStreamProvider(orderId));

    // Navigate to rating screen once, when the order completes.
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
              tipReferenceType: 'gas',
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
          return _TrackingBody(order: order, orderId: orderId);
        },
      ),
    );
  }
}

class _TrackingBody extends ConsumerWidget {
  final GasRefillRequest order;
  final String orderId;

  const _TrackingBody({required this.order, required this.orderId});

  // Friendly labels for the timeline (statuses stay as the model defines them).
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

  // Full journey = pre-flow (finding/assigned) + the type's flow steps.
  List<GasOrderStatus> get _steps => [
        GasOrderStatus.pendingApproval,
        GasOrderStatus.driverAssigned,
        ...order.refillType.steps,
      ];

  bool get _isCompleted => order.status == GasOrderStatus.delivered;
  bool get _isCancelled =>
      order.status == GasOrderStatus.cancelled ||
      order.status == GasOrderStatus.failed;

  bool get _isActive => !_isCompleted && !_isCancelled &&
      order.status != GasOrderStatus.pendingApproval;

  bool get _hasDriver =>
      (order.driverName?.isNotEmpty == true) ||
      (order.driverPhone?.isNotEmpty == true);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

    return Column(
      children: [
        // ── Map area ──
        Stack(
          children: [
            _GasMap(order: order, height: 260),
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 16,
              right: 16,
              child: _StatusHeader(order: order, active: _isActive),
            ),
            // Back button
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 8,
              child: _CircleBtn(
                icon: Icons.arrow_back_rounded,
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),

        // ── Content ──
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                if (_isCancelled)
                  _buildCancelledBanner()
                else ...[
                  _buildProgressSteps(),
                  const SizedBox(height: 14),
                  if (_isCompleted) ...[
                    _buildCompletedBanner(),
                    const SizedBox(height: 14),
                  ],
                ],
                _buildOtpCard(context),
                if (_hasDriver) ...[
                  const SizedBox(height: 12),
                  _buildRiderCard(context),
                ],
                const SizedBox(height: 12),
                _buildOrderSummary(),
                const SizedBox(height: 12),
                if (!_isCompleted && !_isCancelled)
                  _buildActionRow(context, ref),
                if (_isCompleted || _isCancelled) ...[
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: 'Back to home',
                    onTap: () => Navigator.of(context, rootNavigator: true)
                        .pushNamedAndRemoveUntil(AppRoutes.shell, (_) => false),
                  ),
                ],
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Progress timeline ───────────────────────────────────────────────────────

  Widget _buildProgressSteps() {
    final steps = _steps;
    final currentIdx = steps.indexOf(order.status);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: List.generate(steps.length, (i) {
          final s = steps[i];
          final isDone = i < currentIdx;
          final isCurrent = i == currentIdx;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: isDone
                          ? AppColors.success
                          : isCurrent
                              ? AppColors.primary
                              : AppColors.surfaceAlt,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDone
                            ? AppColors.success
                            : isCurrent
                                ? AppColors.primary
                                : AppColors.border,
                      ),
                    ),
                    child: Icon(
                      isDone
                          ? Icons.check_rounded
                          : _stepIcons[s] ?? Icons.circle_outlined,
                      size: 14,
                      color: isDone || isCurrent
                          ? Colors.white
                          : AppColors.textTertiary,
                    ),
                  ),
                  if (i < steps.length - 1)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 2,
                      height: 28,
                      color: isDone ? AppColors.success : AppColors.border,
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text(
                        _stepLabels[s] ?? s.passengerDisplayName,
                        style: AppTextStyles.labelLarge.copyWith(
                          color: isDone
                              ? AppColors.textSecondary
                              : isCurrent
                                  ? AppColors.textPrimary
                                  : AppColors.textTertiary,
                          fontWeight:
                              isCurrent ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  // ── Banners ─────────────────────────────────────────────────────────────────

  Widget _buildCompletedBanner() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.success.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  color: AppColors.success, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Gas delivered!',
                      style: AppTextStyles.heading4
                          .copyWith(color: AppColors.success)),
                  Text(
                    'Delivered to ${order.deliveryAddress ?? 'your location'}',
                    style: AppTextStyles.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _buildCancelledBanner() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.errorLight,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cancel_rounded,
                  color: AppColors.error, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Order cancelled',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.error,
                      )),
                  Text('Your wallet will be refunded if charged.',
                      style: AppTextStyles.caption),
                ],
              ),
            ),
          ],
        ),
      );

  // ── OTP card ──────────────────────────────────────────────────────────────

  Widget _buildOtpCard(BuildContext context) {
    final otp = order.deliveryOtp;
    if (otp == null || otp.isEmpty) return const SizedBox.shrink();
    // Only once a driver is engaged and the order is still active.
    if (!_isActive || !_hasDriver) return const SizedBox.shrink();

    final shareMsg = 'Your gas delivery OTP is: *$otp*\n\n'
        'Please give this code to the CTSRide rider when they arrive.';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
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
                  'Only share this OTP with the CTSRide rider. Do not share with anyone else.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF92400E)),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: () =>
                  Share.share(shareMsg, subject: 'CTSRide Gas Delivery OTP'),
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

  // ── Rider card ──────────────────────────────────────────────────────────────

  Widget _buildRiderCard(BuildContext context) {
    final name = order.driverName ?? 'Your driver';
    final rating = order.driverRating ?? 0.0;
    final initials = name
        .split(' ')
        .take(2)
        .map((p) => p.isNotEmpty ? p[0] : '')
        .join()
        .toUpperCase();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.primary,
            child: Text(initials.isEmpty ? '?' : initials,
                style: AppTextStyles.labelLarge
                    .copyWith(color: AppColors.background)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: AppTextStyles.heading4),
                Row(
                  children: [
                    if (rating > 0) ...[
                      const Icon(Icons.star_rounded,
                          color: AppColors.warning, size: 13),
                      const SizedBox(width: 3),
                      Text(rating.toStringAsFixed(1),
                          style: AppTextStyles.bodySmall),
                      const SizedBox(width: 6),
                    ],
                    const Icon(Icons.two_wheeler_rounded,
                        size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        order.driverVehicle ?? 'Gas delivery',
                        style: AppTextStyles.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Order summary ─────────────────────────────────────────────────────────

  Widget _buildOrderSummary() {
    final gasCost = (order.totalPrice - order.deliveryFee)
        .clamp(0, double.infinity)
        .toDouble();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
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
                        style: AppTextStyles.caption),
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
              Text('₵${order.totalPrice.toStringAsFixed(2)}',
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
                  .copyWith(color: AppColors.textSecondary)),
          Text('₵${amount.toStringAsFixed(2)}', style: AppTextStyles.bodyMedium),
        ],
      );

  // ── Action row ──────────────────────────────────────────────────────────────

  Widget _buildActionRow(BuildContext context, WidgetRef ref) => Row(
        children: [
          Expanded(
            child: _ActionBtn(
              icon: Icons.phone_rounded,
              label: 'Call driver',
              onTap: () async {
                final phone = order.driverPhone;
                if (phone == null || phone.isEmpty) return;
                final uri = Uri(scheme: 'tel', path: phone);
                if (await canLaunchUrl(uri)) launchUrl(uri);
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ActionBtn(
              icon: Icons.share_rounded,
              label: 'Share',
              onTap: () {
                final shortId = orderId.length >= 8
                    ? orderId.substring(0, 8).toUpperCase()
                    : orderId.toUpperCase();
                Share.share('Track my CTSRide gas order #$shortId');
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ActionBtn(
              icon: Icons.report_problem_rounded,
              label: 'Report',
              color: AppColors.errorLight,
              iconColor: AppColors.error,
              onTap: () => _showReportSheet(context, ref),
            ),
          ),
        ],
      );

  void _showReportSheet(BuildContext context, WidgetRef ref) {
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
            Center(
              child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2))),
            ),
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

// ── Status header overlay ─────────────────────────────────────────────────────

class _StatusHeader extends StatelessWidget {
  final GasRefillRequest order;
  final bool active;
  const _StatusHeader({required this.order, required this.active});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            const Icon(Icons.local_fire_department_rounded,
                color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                order.status.passengerDisplayName,
                style: AppTextStyles.labelLarge.copyWith(color: Colors.white),
              ),
            ),
            if (active)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('Live',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    )),
              ),
          ],
        ),
      );
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.all(8),
          width: 38,
          height: 38,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.black87, size: 20),
        ),
      );
}

// ── Action button ─────────────────────────────────────────────────────────────

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final Color? iconColor;

  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: color ?? AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Icon(icon, color: iconColor ?? AppColors.textSecondary, size: 20),
              const SizedBox(height: 4),
              Text(label,
                  style: AppTextStyles.caption, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}

// ── Real map with route polyline ───────────────────────────────────────────

class _GasMap extends StatefulWidget {
  final GasRefillRequest order;
  final double height;
  const _GasMap({required this.order, required this.height});

  @override
  State<_GasMap> createState() => _GasMapState();
}

class _GasMapState extends State<_GasMap> {
  GoogleMapController? _controller;
  final _routeService = RouteService();
  Set<Polyline> _polyline = {};
  bool _routeFetched = false;
  bool _mapReady = false;

  static const _mapStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#f5f5f5"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#ffffff"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#e8f5e9"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#b3d9f2"}]}
]
''';

  LatLng get _pickup => LatLng(widget.order.pickupLocation.latitude,
      widget.order.pickupLocation.longitude);
  LatLng get _dropoff => LatLng(widget.order.deliveryLocation.latitude,
      widget.order.deliveryLocation.longitude);
  LatLng? get _driverLatLng {
    final loc = widget.order.driverLocation;
    return loc == null ? null : LatLng(loc.latitude, loc.longitude);
  }

  double get _driverHeading => widget.order.driverHeading ?? 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await MarkerService.instance.warmUp(context);
      if (mounted) setState(() {});
    });
    _fetchRoute();
  }

  Future<void> _fetchRoute() async {
    if (_routeFetched) return;
    _routeFetched = true;
    final result = await _routeService.getRoute(_pickup, _dropoff);
    if (result != null && result.points.isNotEmpty && mounted) {
      setState(() {
        _polyline = {
          Polyline(
            polylineId: const PolylineId('route'),
            points: result.points,
            color: AppColors.primary,
            width: 7,
          ),
        };
      });
    }
  }

  void _fit() {
    if (!_mapReady) return;
    final sw = LatLng(
      _pickup.latitude < _dropoff.latitude ? _pickup.latitude : _dropoff.latitude,
      _pickup.longitude < _dropoff.longitude
          ? _pickup.longitude
          : _dropoff.longitude,
    );
    final ne = LatLng(
      _pickup.latitude > _dropoff.latitude ? _pickup.latitude : _dropoff.latitude,
      _pickup.longitude > _dropoff.longitude
          ? _pickup.longitude
          : _dropoff.longitude,
    );
    _controller?.animateCamera(
      CameraUpdate.newLatLngBounds(
          LatLngBounds(southwest: sw, northeast: ne), 60),
    );
  }

  Set<Marker> _markers() {
    final ms = MarkerService.instance;
    return {
      Marker(
        markerId: const MarkerId('pickup'),
        position: _pickup,
        icon: ms.pickup(),
        anchor: const Offset(0.5, 1.0),
        infoWindow: const InfoWindow(title: 'Pickup'),
      ),
      Marker(
        markerId: const MarkerId('delivery'),
        position: _dropoff,
        icon: ms.dropoff(),
        anchor: const Offset(0.5, 1.0),
        infoWindow: const InfoWindow(title: 'Delivery'),
      ),
      if (_driverLatLng != null)
        Marker(
          markerId: const MarkerId('driver'),
          position: _driverLatLng!,
          icon: ms.vehicle('gas'),
          anchor: const Offset(0.5, 0.5),
          rotation: _driverHeading,
          flat: true,
          infoWindow: InfoWindow(title: widget.order.driverName ?? 'Driver'),
        ),
    };
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: GoogleMap(
        style: _mapStyle,
        onMapCreated: (c) {
          _controller = c;
          setState(() => _mapReady = true);
          WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
        },
        initialCameraPosition: CameraPosition(target: _pickup, zoom: 13),
        markers: _markers(),
        polylines: _polyline,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        mapToolbarEnabled: false,
        compassEnabled: false,
      ),
    );
  }
}