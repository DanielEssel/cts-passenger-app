// lib/features/delivery/delivery_tracking_screen.dart

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../widgets/common/shared_widgets.dart';
import '../models/delivery_request.dart';
import '../../delivery/providers/delivery_provider.dart';

class DeliveryTrackingScreen extends ConsumerWidget {
  final String deliveryId;

  const DeliveryTrackingScreen({super.key, required this.deliveryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deliveryAsync = ref.watch(deliveryStreamProvider(deliveryId));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: deliveryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => Center(child: Text('Error: $e')),
        data:    (delivery) {
          if (delivery == null) {
            return const Center(child: Text('Delivery not found'));
          }
          return _TrackingBody(
              delivery: delivery, deliveryId: deliveryId);
        },
      ),
    );
  }
}

class _TrackingBody extends ConsumerWidget {
  final DeliveryRequest delivery;
  final String          deliveryId;

  const _TrackingBody({
    required this.delivery,
    required this.deliveryId,
  });

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
    DeliveryStatus.driverAssigned:   Icons.person_rounded,
    DeliveryStatus.pickupEnroute:    Icons.directions_rounded,
    DeliveryStatus.arrivedAtPickup:  Icons.location_on_rounded,
    DeliveryStatus.packagePicked:    Icons.inventory_2_rounded,
    DeliveryStatus.deliveryEnroute:  Icons.local_shipping_rounded,
    DeliveryStatus.arrivedAtDropoff: Icons.location_on_rounded,
    DeliveryStatus.completed:        Icons.check_circle_rounded,
  };

  bool get _isCompleted => delivery.status == DeliveryStatus.completed;
  bool get _isCancelled => delivery.status == DeliveryStatus.cancelled;

  IconData get _vehicleIcon {
    if (delivery.vehicleType == 'Aboboya')   return Icons.electric_rickshaw_rounded;
    if (delivery.vehicleType == 'Mini Truck') return Icons.local_shipping_rounded;
    return Icons.two_wheeler_rounded;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

    return Column(
      children: [
        // ── Map area ──
        Stack(
          children: [
            const MapPlaceholder(height: 260, showRoute: true),
            Positioned(
              top:   MediaQuery.of(context).padding.top + 12,
              left:  16,
              right: 16,
              child: _StatusHeader(delivery: delivery),
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
                    _buildCompletedBanner(context),
                    const SizedBox(height: 14),
                  ],
                ],

                _buildOtpCard(context),
                const SizedBox(height: 12),
                _buildRiderCard(context, ref),
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

  // ── Progress steps ────────────────────────────────────────────────────────

  Widget _buildProgressSteps() {
    final currentIdx = _steps.indexOf(delivery.status);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: AppColors.border),
      ),
      child: Column(
        children: List.generate(_steps.length, (i) {
          final s        = _steps[i];
          final isDone   = i < currentIdx;
          final isCurrent = i == currentIdx;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 28, height: 28,
                    decoration: BoxDecoration(
                      color:  isDone
                          ? AppColors.success
                          : isCurrent
                              ? AppColors.primary
                              : AppColors.surfaceAlt,
                      shape:  BoxShape.circle,
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
                      size:  14,
                      color: isDone || isCurrent
                          ? Colors.white
                          : AppColors.textTertiary,
                    ),
                  ),
                  if (i < _steps.length - 1)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width:  2,
                      height: 28,
                      color:  isDone ? AppColors.success : AppColors.border,
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
                        s.passengerDisplayName,
                        style: AppTextStyles.labelLarge.copyWith(
                          color:      isDone
                              ? AppColors.textSecondary
                              : isCurrent
                                  ? AppColors.textPrimary
                                  : AppColors.textTertiary,
                          fontWeight: isCurrent
                              ? FontWeight.w700
                              : FontWeight.w400,
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

  // ── Banners ───────────────────────────────────────────────────────────────

  Widget _buildCompletedBanner(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:        AppColors.success.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: AppColors.success.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color:  AppColors.success.withValues(alpha: 0.15),
                shape:  BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  color: AppColors.success, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Parcel delivered!',
                      style: AppTextStyles.heading4
                          .copyWith(color: AppColors.success)),
                  Text(
                    'Delivered to ${delivery.dropoffAddress}',
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
          color:        AppColors.errorLight,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: AppColors.error.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color:  AppColors.error.withValues(alpha: 0.15),
                shape:  BoxShape.circle,
              ),
              child: const Icon(Icons.cancel_rounded,
                  color: AppColors.error, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Delivery cancelled',
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

  // ── Rider card ────────────────────────────────────────────────────────────

  Widget _buildOtpCard(BuildContext context) {
    final otp = delivery.deliveryOtp;
    if (otp == null || otp.isEmpty) return const SizedBox.shrink();
    if (_isCompleted || _isCancelled) return const SizedBox.shrink();

    final receiverName  = delivery.receiverName  ?? 'Recipient';
    final receiverPhone = delivery.receiverPhone ?? '';

    // WhatsApp share message
    final shareMsg = 'Hi $receiverName, your delivery OTP is: *$otp*\n\n'
        'Please give this code to the delivery rider when they arrive. '
        'CTSRide Delivery';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: AppColors.border),
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
                color:        AppColors.primaryDim,
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
                        fontSize:   13,
                        fontWeight: FontWeight.w700,
                        color:      AppColors.textPrimary,
                      )),
                  const Text(
                    'Share this code with the recipient',
                    style: TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ]),

          const SizedBox(height: 16),

          // OTP display
          Container(
            width:  double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color:        AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border:       Border.all(
                  color: AppColors.primary.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: otp.split('').map((digit) => Container(
                width:  44, height: 52,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color:        AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border:       Border.all(color: AppColors.primary),
                  boxShadow: [
                    BoxShadow(
                      color:      AppColors.primary.withValues(alpha: 0.1),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(digit,
                      style: const TextStyle(
                        fontSize:   24,
                        fontWeight: FontWeight.w900,
                        color:      AppColors.primary,
                        fontFamily: 'monospace',
                      )),
                ),
              )).toList(),
            ),
          ),

          const SizedBox(height: 14),

          // Info text
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color:        const Color(0xFFFFF7ED),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded,
                  color: Color(0xFFD97706), size: 14),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'The rider will ask $receiverName for this code to complete delivery.',
                  style: const TextStyle(
                    fontSize: 11, color: Color(0xFF92400E),
                  ),
                ),
              ),
            ]),
          ),

          const SizedBox(height: 12),

          // Share buttons
          Row(children: [
            // Share via WhatsApp
            Expanded(
              child: GestureDetector(
                onTap: () async {
                  final waUrl = Uri.parse(
                    'https://wa.me/${receiverPhone.replaceAll('+', '')}?text=${Uri.encodeComponent(shareMsg)}'
                  );
                  if (await canLaunchUrl(waUrl)) {
                    await launchUrl(waUrl,
                        mode: LaunchMode.externalApplication);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color:        const Color(0xFF25D366),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_rounded,
                          color: Colors.white, size: 15),
                      SizedBox(width: 6),
                      Text('Send via WhatsApp',
                          style: TextStyle(
                            color:      Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize:   12,
                          )),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Share via SMS/other
            GestureDetector(
              onTap: () => Share.share(shareMsg,
                  subject: 'Your CTSRide Delivery OTP'),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color:        AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                  border:       Border.all(color: AppColors.border),
                ),
                child: const Row(children: [
                  Icon(Icons.share_rounded,
                      color: AppColors.textSecondary, size: 15),
                  SizedBox(width: 6),
                  Text('Share',
                      style: TextStyle(
                        fontSize:   12,
                        fontWeight: FontWeight.w600,
                        color:      AppColors.textSecondary,
                      )),
                ]),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildRiderCard(BuildContext context, WidgetRef ref) {
    final name   = delivery.driverName   ?? 'Your rider';
    final rating = delivery.driverRating ?? 0.0;
    final initials = name.split(' ')
        .take(2)
        .map((p) => p.isNotEmpty ? p[0] : '')
        .join()
        .toUpperCase();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius:          22,
            backgroundColor: AppColors.primary,
            child: Text(initials,
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
                    Icon(_vehicleIcon, size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(delivery.vehicleType, style: AppTextStyles.bodySmall),
                  ],
                ),
              ],
            ),
          ),
          Text('GHS ${delivery.estimatedFare.toStringAsFixed(2)}',
              style: AppTextStyles.labelLarge
                  .copyWith(color: AppColors.primary)),
        ],
      ),
    );
  }

  // ── Action row ────────────────────────────────────────────────────────────

  Widget _buildActionRow(BuildContext context, WidgetRef ref) => Row(
        children: [
          Expanded(
            child: _ActionBtn(
              icon:  Icons.phone_rounded,
              label: 'Call rider',
              onTap: () async {
                final phone = delivery.driverPhone;
                if (phone == null) return;
                final uri = Uri(scheme: 'tel', path: phone);
                if (await canLaunchUrl(uri)) launchUrl(uri);
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ActionBtn(
              icon:  Icons.share_rounded,
              label: 'Share',
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Tracking link copied'),
                    duration: Duration(seconds: 2)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ActionBtn(
              icon:      Icons.report_problem_rounded,
              label:     'Report',
              color:     AppColors.errorLight,
              iconColor: AppColors.error,
              onTap:     () => _showReportSheet(context, ref),
            ),
          ),
        ],
      );

  void _showReportSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context:          context,
      backgroundColor:  AppColors.surface,
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
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color:        AppColors.border,
                    borderRadius: BorderRadius.circular(2))),
            ),
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
                    margin:  const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color:        AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border:       Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Expanded(child: Text(issue,
                            style: AppTextStyles.bodyMedium)),
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
  final DeliveryRequest delivery;
  const _StatusHeader({required this.delivery});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color:        Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            const Icon(Icons.inventory_2_rounded,
                color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                delivery.status.passengerDisplayName,
                style: AppTextStyles.labelLarge
                    .copyWith(color: Colors.white),
              ),
            ),
            if (delivery.status.isActive &&
                delivery.status != DeliveryStatus.completed)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color:        Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('Live',
                    style: TextStyle(
                      color:      Colors.white,
                      fontSize:   11,
                      fontWeight: FontWeight.w700,
                    )),
              ),
          ],
        ),
      );
}

// ── Action button ─────────────────────────────────────────────────────────────

class _ActionBtn extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;
  final Color?       color;
  final Color?       iconColor;

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
            color:        color ?? AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border:       Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Icon(icon,
                  color: iconColor ?? AppColors.textSecondary, size: 20),
              const SizedBox(height: 4),
              Text(label,
                  style:     AppTextStyles.caption,
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}