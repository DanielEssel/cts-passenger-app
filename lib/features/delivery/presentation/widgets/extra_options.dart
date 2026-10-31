// lib/features/delivery/presentation/widgets/extra_options.dart
//
// Fragile + loading-helpers toggles. The helpers toggle is disabled (and
// visually explained) when the selected weight tier can't carry helpers —
// preventing a helpers charge for a vehicle class the tier can't use.
// Fee amounts come from PricingService, the same values the fare uses.

import 'package:flutter/material.dart';

import '../../../../core/services/pricing_service.dart';
import '../../../../core/theme/cts_theme.dart';
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

  static String _fee(double v) => '+GHS ${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final pricing = PricingService.instance;
    final helpersAllowed = selectedTierVehicles != null &&
        DeliveryFormValidator.helpersAllowedForTier(selectedTierVehicles!);

    return Column(
      children: [
        _ToggleRow(
          icon: Icons.wine_bar_rounded,
          label: 'Fragile item',
          subtitle:
              'Handled with extra care · ${_fee(pricing.deliveryFragileSurcharge)}',
          value: isFragile,
          onChanged: onFragileChanged,
        ),
        const SizedBox(height: 8),
        _ToggleRow(
          icon: Icons.people_rounded,
          label: 'Loading helpers',
          subtitle: selectedTierVehicles == null
              ? 'Choose a weight first · Aboboya / Mini Truck only'
              : helpersAllowed
                  ? 'Help to load and unload · ${_fee(pricing.deliveryHelperSurcharge)}'
                  : 'Not available for this weight',
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
    return MergeSemantics(
      child: Material(
        color: value ? CtsTheme.primaryTint : CtsTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: value ? CtsTheme.primary : CtsTheme.border,
            width: value ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onChanged == null ? null : () => onChanged!(!value),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(
              children: [
                Icon(icon,
                    size: 20,
                    color: !enabled
                        ? CtsTheme.textTertiary
                        : value
                            ? CtsTheme.primaryDeep
                            : CtsTheme.textSecondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: enabled
                                ? CtsTheme.textPrimary
                                : CtsTheme.textTertiary,
                          )),
                      const SizedBox(height: 1),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 12, color: CtsTheme.textSecondary)),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: Colors.white,
                  activeTrackColor: CtsTheme.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
