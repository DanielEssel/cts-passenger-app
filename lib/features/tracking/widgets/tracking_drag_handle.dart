// lib/features/tracking/widgets/tracking_drag_handle.dart
import 'package:flutter/material.dart';
import '../../../../../core/constants/app_colors.dart';

class TrackingDragHandle extends StatelessWidget {
  const TrackingDragHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.border,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}