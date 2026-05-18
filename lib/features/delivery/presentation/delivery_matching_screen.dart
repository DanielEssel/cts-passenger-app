import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../delivery_tracking_screen.dart';

/// Shown after confirming delivery — pulsing animation while finding a rider.
/// Auto-navigates to DeliveryTrackingScreen after a mock delay.
class DeliveryMatchingScreen extends StatefulWidget {
  final String vehicleName;
  final String dropoff;
  final String fare;

  const DeliveryMatchingScreen({
    super.key,
    required this.vehicleName,
    required this.dropoff,
    required this.fare,
  });

  @override
  State<DeliveryMatchingScreen> createState() => _DeliveryMatchingScreenState();
}

class _DeliveryMatchingScreenState extends State<DeliveryMatchingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  int _dotsCount = 1;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _tickDots();

    // Simulate rider found after 4 seconds
    Future.delayed(const Duration(seconds: 4), () {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => DeliveryTrackingScreen(
            vehicleName: widget.vehicleName,
            dropoff: widget.dropoff,
            fare: widget.fare,
            riderName: 'Kwame A.',
            riderRating: 4.7,
            riderPhone: '+233 24 555 0000',
            eta: '5 min',
          ),
        ),
      );
    });
  }

  void _tickDots() {
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() => _dotsCount = (_dotsCount % 3) + 1);
      _tickDots();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  IconData get _vehicleIcon {
    if (widget.vehicleName == 'Aboboya') {
      return Icons.electric_rickshaw_rounded;
    } else if (widget.vehicleName == 'Mini Truck') {
      return Icons.local_shipping_rounded;
    }
    return Icons.two_wheeler_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              // Close
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: const Icon(Icons.close_rounded,
                          size: 18, color: AppColors.textSecondary),
                    ),
                  ),
                  Text(widget.vehicleName, style: AppTextStyles.heading4),
                  const SizedBox(width: 36),
                ],
              ),

              const Spacer(),

              // Pulsing animation
              AnimatedBuilder(
                animation: _pulseController,
                builder: (_, __) {
                  final scale = 1.0 + (_pulseController.value * 0.4);
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      Transform.scale(
                        scale: scale,
                        child: Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.primary.withValues(
                              alpha: (1.0 - _pulseController.value) * 0.12,
                            ),
                          ),
                        ),
                      ),
                      Transform.scale(
                        scale: 1.0 + (_pulseController.value * 0.2),
                        child: Container(
                          width: 110,
                          height: 110,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.primary.withValues(
                              alpha: (1.0 - _pulseController.value) * 0.15,
                            ),
                          ),
                        ),
                      ),
                      Container(
                        width: 80,
                        height: 80,
                        decoration: const BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(_vehicleIcon,
                            color: AppColors.background, size: 36),
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 40),

              Text(
                'Finding a rider${'.' * _dotsCount}',
                style: AppTextStyles.heading2,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Looking for a nearby ${widget.vehicleName} rider',
                style: AppTextStyles.bodySmall,
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 40),

              // Summary card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: [
                    _SummaryRow(
                      icon: Icons.location_on_rounded,
                      iconColor: AppColors.primary,
                      label: 'Delivering to',
                      value: widget.dropoff,
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Divider(height: 0.5, color: AppColors.border),
                    ),
                    _SummaryRow(
                      icon: Icons.payments_rounded,
                      iconColor: AppColors.success,
                      label: 'Estimated fare',
                      value: widget.fare,
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Divider(height: 0.5, color: AppColors.border),
                    ),
                    const _SummaryRow(
                      icon: Icons.account_balance_wallet_rounded,
                      iconColor: AppColors.info,
                      label: 'Payment',
                      value: 'CTSRide Wallet',
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // Cancel
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: AppColors.errorLight,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: AppColors.error.withValues(alpha: 0.2)),
                  ),
                  child: const Text(
                    'Cancel request',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  const _SummaryRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: AppTextStyles.bodySmall)),
        Text(value,
            style: AppTextStyles.labelLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ],
    );
  }
}
