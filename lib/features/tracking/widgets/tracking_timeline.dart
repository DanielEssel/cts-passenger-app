// lib/features/tracking/widgets/tracking_timeline.dart (UPDATE EXISTING)

import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../tracking/widgets/tracking_constants.dart';

class TrackingTimelineItem {
  final IconData icon;
  final String label;
  final bool isCompleted;
  final bool isCurrent;

  const TrackingTimelineItem({
    required this.icon,
    required this.label,
    this.isCompleted = false,
    this.isCurrent = false,
  });
}

class TrackingTimeline extends StatelessWidget {
  final List<TrackingTimelineItem> items;
  final int currentIndex;

  const TrackingTimeline({
    super.key,
    required this.items,
    required this.currentIndex,
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
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: List.generate(items.length, (i) {
          final item = items[i];
          final isDone = i < currentIndex;
          final isCurrent = i == currentIndex;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  AnimatedContainer(
                    duration: TrackingConstants.animationDuration,
                    width: isCurrent ? 32 : 28,
                    height: isCurrent ? 32 : 28,
                    decoration: BoxDecoration(
                      color: isDone
                          ? AppColors.primary
                          : isCurrent
                              ? AppColors.primary
                              : AppColors.surfaceAlt,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDone
                            ? AppColors.primary
                            : isCurrent
                                ? AppColors.primary
                                : AppColors.border,
                        width: isCurrent ? 2.5 : 1.5,
                      ),
                      boxShadow: isCurrent
                          ? [
                              BoxShadow(
                                color: AppColors.primary.withValues(alpha: 0.3),
                                blurRadius: 12,
                                spreadRadius: 3,
                              ),
                            ]
                          : isDone
                              ? [
                                  BoxShadow(
                                    color: AppColors.primary.withValues(alpha: 0.15),
                                    blurRadius: 8,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                    ),
                    child: Icon(
                      isDone ? Icons.check_rounded : item.icon,
                      size: isCurrent ? 16 : 14,
                      color: isDone || isCurrent
                          ? Colors.white
                          : AppColors.textSecondary,
                    ),
                  ),
                  if (i < items.length - 1)
                    AnimatedContainer(
                      duration: TrackingConstants.animationDuration,
                      width: 2.5,
                      height: 32,
                      color: isDone ? AppColors.primary : AppColors.border,
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text(
                        item.label,
                        style: AppTextStyles.labelLarge.copyWith(
                          color: isDone
                              ? AppColors.primary
                              : isCurrent
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary,
                          fontWeight:
                              isCurrent ? FontWeight.w700 : FontWeight.w500,
                          fontSize: isCurrent ? 15 : 14,
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
}