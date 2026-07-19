// lib/features/delivery/presentation/widgets/extra_options.dart
//
// Fragile + loading-helpers toggles. The helpers toggle is disabled (and
// visually explained) when the selected weight tier can't carry helpers —
// preventing a +GHS 10 charge for a vehicle class the tier can't use.

import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../domain/delivery_form_validator.dart';

class ExtraOptions extends StatelessWidget {
  final bool isFragile;
  final bool requiresHelpers;
  final ValueChanged<bool> onFragileChanged;
  final ValueChanged<bool> onHelpersChanged;

  /// Vehicles the currently-selected weight tier supports, or null if no
  /// tier is chosen yet. Drives whether the helpers toggle is active.
  final List<String>? selectedTierVehicles;

  const ExtraOptions({
    super.key,
    required this.isFragile,
    required this.requiresHelpers,
    required this.onFragileChanged,
    required this.onHelpersChanged,
    required this.selectedTierVehicles,
  });

  @override
  Widget build(BuildContext context) {
    final helpersAllowed = selectedTierVehicles != null &&
        DeliveryFormValidator.helpersAllowedForTier(selectedTierVehicles!);

    return Column(
      children: [
        _ToggleRow(
          icon: Icons.broken_image_rounded,
          label: 'Fragile item',
          subtitle: '+GHS 5.00 handling fee',
          value: isFragile,
          onChanged: onFragileChanged,
        ),
        const SizedBox(height: 10),
        _ToggleRow(
          icon: Icons.people_rounded,
          label: 'Requires loading helpers',
          subtitle: selectedTierVehicles != null && !helpersAllowed
              ? 'Not available for this weight tier'
              : '+GHS 10.00 (Aboboya / Mini Truck only)',
          value: helpersAllowed && requiresHelpers,
          enabled: helpersAllowed,
          onChanged: helpersAllowed ? onHelpersChanged : null,
        ),
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool>? onChanged;

  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    this.enabled = true,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: value
              ? AppColors.primary.withValues(alpha: 0.06)
              : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: value ? AppColors.primary : AppColors.border,
            width: value ? 1.5 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 18,
                color: value ? AppColors.primary : AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: value
                            ? AppColors.primary
                            : AppColors.textPrimary,
                      )),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondary)),
                ],
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppColors.primary,
            ),
          ],
        ),
      ),
    );
  }
}