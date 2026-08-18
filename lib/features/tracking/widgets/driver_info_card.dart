// lib/features/tracking/widgets/driver_info_card.dart
import 'package:flutter/material.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_text_styles.dart';

class DriverInfoCard extends StatelessWidget {
  final String name;
  final double rating;
  final String vehicleType;
  final String? vehiclePlate;
  final String? eta;
  final String? distanceRemaining;
  final String? price;
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
    this.eta,
    this.distanceRemaining,
    this.price,
    required this.vehicleIcon,
    this.onCall,
    this.onChat,
    this.onEmergency,
  });

  @override
  Widget build(BuildContext context) {
    final initials = name
        .split(' ')
        .take(2)
        .map((p) => p.isNotEmpty ? p[0] : '')
        .join()
        .toUpperCase();

    return Container(
  padding: const EdgeInsets.all(16),
  decoration: BoxDecoration(
    color: AppColors.surface,
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.06),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
    ],
  ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.primary,
                child: Text(
                  initials,
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.background,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
  name,
  style: AppTextStyles.heading4.copyWith(
    color: const Color(0xFF1E1E1E),
  ),
),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (rating > 0) ...[
                          const Icon(
                            Icons.star_rounded,
                            color: AppColors.warning,
                            size: 13,
                          ),
                          const SizedBox(width: 3),
                          Text(
  rating.toStringAsFixed(1),
  style: AppTextStyles.bodySmall.copyWith(
    color: const Color(0xFF5F6368),
  ),
),
                          const SizedBox(width: 6),
                        ],
                        Icon(
                          vehicleIcon,
                          size: 14,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
  vehicleType,
  style: AppTextStyles.bodySmall.copyWith(
    color: const Color(0xFF5F6368),
  ),
),
                        if (vehiclePlate != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceAlt,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              vehiclePlate!,
                              style: AppTextStyles.caption.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (price != null)
                Text(
                  price!,
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.primary,
                  ),
                ),
            ],
          ),
          if (eta != null || distanceRemaining != null) ...[
            const SizedBox(height: 12),
            Divider(
              color: AppColors.border,
              height: 1,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (eta != null) ...[
                  _buildInfoChip(
                    icon: Icons.access_time_rounded,
                    label: 'ETA',
                    value: eta!,
                  ),
                  if (distanceRemaining != null) const SizedBox(width: 12),
                ],
                if (distanceRemaining != null)
                  _buildInfoChip(
                    icon: Icons.route_rounded,
                    label: 'Distance',
                    value: distanceRemaining!,
                  ),
                const Spacer(),
                _buildActionButton(
                  icon: Icons.phone_rounded,
                  onTap: onCall,
                ),
                const SizedBox(width: 8),
                _buildActionButton(
                  icon: Icons.chat_rounded,
                  onTap: onChat,
                ),
                const SizedBox(width: 8),
                _buildActionButton(
                  icon: Icons.report_problem_rounded,
                  color: Colors.red,
                  onTap: onEmergency,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoChip({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(
          value,
          style: AppTextStyles.bodySmall.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    Color? color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color?.withValues(alpha: 0.1) ?? AppColors.surfaceAlt,
          shape: BoxShape.circle,
          border: Border.all(
            color: color?.withValues(alpha: 0.3) ?? AppColors.border,
          ),
        ),
        child: Icon(
          icon,
          color: color ?? AppColors.textSecondary,
          size: 18,
        ),
      ),
    );
  }
}