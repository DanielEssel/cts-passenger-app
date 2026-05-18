import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';
import '../../../core/routes/app_routes.dart';

/// Live delivery tracking — 4 statuses:
/// Rider en route → Picked up → In transit → Delivered
class DeliveryTrackingScreen extends StatefulWidget {
  final String vehicleName;
  final String dropoff;
  final String fare;
  final String riderName;
  final double riderRating;
  final String riderPhone;
  final String eta;

  const DeliveryTrackingScreen({
    super.key,
    required this.vehicleName,
    required this.dropoff,
    required this.fare,
    required this.riderName,
    required this.riderRating,
    required this.riderPhone,
    required this.eta,
  });

  @override
  State<DeliveryTrackingScreen> createState() => _DeliveryTrackingScreenState();
}

class _DeliveryTrackingScreenState extends State<DeliveryTrackingScreen> {
  int _statusIndex = 0;

  final List<Map<String, dynamic>> _statuses = [
    {
      'label': 'Rider en route to pickup',
      'sub': 'Your rider is heading to collect the parcel',
      'icon': Icons.directions_rounded,
      'color': AppColors.info,
    },
    {
      'label': 'Parcel picked up',
      'sub': 'Your rider has collected the parcel',
      'icon': Icons.inventory_2_rounded,
      'color': AppColors.warning,
    },
    {
      'label': 'In transit',
      'sub': 'Your parcel is on the way',
      'icon': Icons.local_shipping_rounded,
      'color': AppColors.primary,
    },
    {
      'label': 'Delivered',
      'sub': 'Parcel has been delivered successfully',
      'icon': Icons.check_circle_rounded,
      'color': AppColors.success,
    },
  ];

  bool get _isDelivered => _statusIndex == _statuses.length - 1;

  IconData get _vehicleIcon {
    if (widget.vehicleName == 'Aboboya') return Icons.electric_rickshaw_rounded;
    if (widget.vehicleName == 'Mini Truck') return Icons.local_shipping_rounded;
    return Icons.two_wheeler_rounded;
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    final status = _statuses[_statusIndex];

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          // ── Map ──────────────────────────────────────────────────────────
          Stack(
            children: [
              const MapPlaceholder(height: 260, showRoute: true),
              // Status overlay
              Positioned(
                top: MediaQuery.of(context).padding.top + 12,
                left: 16,
                right: 16,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      Icon(status['icon'],
                          color: AppColors.background, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          status['label'],
                          style: AppTextStyles.labelLarge
                              .copyWith(color: AppColors.background),
                        ),
                      ),
                      if (!_isDelivered)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(widget.eta,
                              style: AppTextStyles.caption
                                  .copyWith(color: AppColors.background)),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.success.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text('Done',
                              style: AppTextStyles.caption.copyWith(
                                  color: AppColors.background,
                                  fontWeight: FontWeight.w700)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // ── Scrollable content ────────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // Status steps
                  _buildStatusSteps(),
                  const SizedBox(height: 14),

                  // Delivery complete banner
                  if (_isDelivered) ...[
                    _buildDeliveredBanner(),
                    const SizedBox(height: 14),
                  ],

                  // Rider card
                  _buildRiderCard(),
                  const SizedBox(height: 12),

                  // Actions
                  _buildActionRow(),
                  const SizedBox(height: 12),

                  // Share tracking
                  _buildShareTracking(),
                  const SizedBox(height: 12),

                  // DEV advance status
                  if (!_isDelivered)
                    GestureDetector(
                      onTap: () => setState(() => _statusIndex++),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Center(
                          child: Text(
                            '[ DEV ] Advance delivery status →',
                            style: AppTextStyles.caption
                                .copyWith(color: AppColors.textSecondary),
                          ),
                        ),
                      ),
                    ),

                  // Go home when delivered
                  if (_isDelivered) ...[
                    const SizedBox(height: 4),
                    PrimaryButton(
                      label: 'Done — Back to home',
                      onTap: () => Navigator.pushNamedAndRemoveUntil(
                        context,
                        AppRoutes.shell,
                        (r) => false,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Status Step Indicator ──────────────────────────────────────────────────
  Widget _buildStatusSteps() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: List.generate(_statuses.length, (i) {
          final isDone = i < _statusIndex;
          final isCurrent = i == _statusIndex;
          final s = _statuses[i];
          final color = s['color'] as Color;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: isDone
                          ? AppColors.success
                          : isCurrent
                              ? color
                              : AppColors.surfaceAlt,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDone
                            ? AppColors.success
                            : isCurrent
                                ? color
                                : AppColors.border,
                      ),
                    ),
                    child: Icon(
                      isDone ? Icons.check_rounded : s['icon'],
                      size: 14,
                      color: isDone || isCurrent
                          ? AppColors.background
                          : AppColors.textTertiary,
                    ),
                  ),
                  if (i < _statuses.length - 1)
                    Container(
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
                        s['label'],
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
                      if (isCurrent) ...[
                        const SizedBox(height: 2),
                        Text(s['sub'], style: AppTextStyles.caption),
                      ],
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

  // ─── Delivered Banner ───────────────────────────────────────────────────────
  Widget _buildDeliveredBanner() {
    return Container(
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
                Text('Parcel delivered!',
                    style: AppTextStyles.heading4
                        .copyWith(color: AppColors.success)),
                Text('Your parcel reached ${widget.dropoff}',
                    style: AppTextStyles.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Rider Card ─────────────────────────────────────────────────────────────
  Widget _buildRiderCard() {
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
            child: Text(
              widget.riderName.substring(0, 2).toUpperCase(),
              style: AppTextStyles.labelLarge
                  .copyWith(color: AppColors.background),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.riderName, style: AppTextStyles.heading4),
                Row(
                  children: [
                    const Icon(Icons.star_rounded,
                        color: AppColors.warning, size: 13),
                    const SizedBox(width: 3),
                    Text('${widget.riderRating}',
                        style: AppTextStyles.bodySmall),
                    const SizedBox(width: 6),
                    const Text('·', style: AppTextStyles.bodySmall),
                    const SizedBox(width: 6),
                    Icon(_vehicleIcon,
                        size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(widget.vehicleName, style: AppTextStyles.bodySmall),
                  ],
                ),
              ],
            ),
          ),
          Text(widget.fare,
              style:
                  AppTextStyles.labelLarge.copyWith(color: AppColors.primary)),
        ],
      ),
    );
  }

  // ─── Actions ────────────────────────────────────────────────────────────────
  Widget _buildActionRow() {
    return Row(
      children: [
        Expanded(
          child: _ActionBtn(
            icon: Icons.phone_rounded,
            label: 'Call rider',
            onTap: () {},
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ActionBtn(
            icon: Icons.chat_bubble_rounded,
            label: 'Message',
            onTap: () {},
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ActionBtn(
            icon: Icons.report_problem_rounded,
            label: 'Report issue',
            color: AppColors.errorLight,
            iconColor: AppColors.error,
            onTap: () => _showReportSheet(),
          ),
        ),
      ],
    );
  }

  // ─── Share Tracking ─────────────────────────────────────────────────────────
  Widget _buildShareTracking() {
    return GestureDetector(
      onTap: _shareTracking,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.info.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.share_rounded,
                  color: AppColors.info, size: 18),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Share tracking link', style: AppTextStyles.labelLarge),
                  Text('Let receiver track the delivery',
                      style: AppTextStyles.caption),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textTertiary, size: 18),
          ],
        ),
      ),
    );
  }

  void _shareTracking() {
    // In production: Share.share('Track your delivery: https://ctsride.app/track/ABC123');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Tracking link copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _showReportSheet() {
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
                            child:
                                Text(issue, style: AppTextStyles.bodyMedium)),
                        const Icon(Icons.chevron_right_rounded,
                            color: AppColors.textTertiary, size: 16),
                      ],
                    ),
                  ),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

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
  Widget build(BuildContext context) {
    return GestureDetector(
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
}
