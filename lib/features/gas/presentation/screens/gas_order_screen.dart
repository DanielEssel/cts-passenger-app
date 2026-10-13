// lib/features/gas/presentation/screens/gas_order_screen.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../../../core/services/escrow_service.dart';
import '../../../../core/services/pricing_service.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/gas_pricing.dart';

import '../../../../core/theme/cts_theme.dart';
import '../../../../core/widgets/cts_ui.dart';
import '../../../home/widgets/service_tile.dart';
import '../../../ride/models/service_type.dart';
import '../../theme/gas_theme.dart';
import '../../models/gas_refill_request.dart';
import '../../providers/gas_order_providers.dart' hide authStateProvider;
import '../../presentation/widgets/address_picker_sheet.dart';
import 'gas_order_tracking_screen.dart';
import '../../presentation/widgets/gas_payment_sheet.dart';
import '../../../../features/auth/providers/auth_providers.dart';
import 'dart:math' as math;

class GasOrderScreen extends ConsumerStatefulWidget {
  const GasOrderScreen({super.key});

  @override
  ConsumerState<GasOrderScreen> createState() => _GasOrderScreenState();
}

class _GasOrderScreenState extends ConsumerState<GasOrderScreen> {
  GasRefillType _selectedType = GasRefillType.exchangeEmpty;
  CylinderSize _selectedSize = CylinderSize.kg12_5;
  GasBrand? _selectedBrand;
  int _quantity = 1;
  bool _safetyAccepted = false;
  bool _isSubmitting = false;
  String? _deliveryAddress;
  GeoPoint? _deliveryGeoPoint;
  double _distanceKm = 5.0; // one-way estimate; defaults to 5km fallback
  bool _calculatingDistance = false;
  String _paymentMethod = 'wallet'; // 'wallet' | 'cash'

  /// Single source of truth for this order's pricing (type-aware).
  GasPriceBreakdown get _pricing {
    final p = PricingService.instance;
    return GasPricing.compute(
      type: _selectedType,
      size: _selectedSize,
      quantity: _quantity,
      brand: _selectedBrand,
      distanceKm: _distanceKm,
      inputs: GasPricingInputs(
        refillPriceOf: (s) => s.refillPrice,
        fullCylinderPriceOf: (s) => s.fullCylinderPrice,
        baseFare: p.gasBaseFare,
        perKm: p.gasPerKm,
        minDeliveryFee: p.gasMinDeliveryFee,
        roundTripFee: p.gasRoundTripFee,
        commercialRate: p.gasCommercialRate,
      ),
    );
  }

  /// Rough ETA from distance: ~3 min/km travel + ~15 min handling.
  /// Pickup & Return is a round trip, so roughly doubles travel + station time.
  String get _etaText {
    if (_calculatingDistance) return 'Calculating…';
    final isRoundTrip = _selectedType == GasRefillType.pickupAndReturn;
    final legs = isRoundTrip ? 2 : 1;
    final travel = _distanceKm * 3 * legs; // ~3 min/km
    final handling = isRoundTrip ? 90 : 15; // station time for P&R
    final mins = (travel + handling).round();
    if (mins >= 60) {
      final h = mins ~/ 60;
      final m = mins % 60;
      return m == 0 ? '~${h}h' : '~${h}h ${m}m';
    }
    return '~$mins mins';
  }

  double get _deliveryFee => _pricing.deliveryFee;
  double get _basePrice => _pricing.base;
  double get _brandPremium => _pricing.brandPremium;
  double get _total => _pricing.total;

  int get _currentStep {
    if (_safetyAccepted) return 2;
    if (_deliveryAddress != null) return 1;
    return 0;
  }

  // ─────────────────────────────────────────────
  // BUILD
  //
  // Sections live in a lazily built SliverList and render at full opacity
  // with the page transition. The old version faded the whole form in over
  // 600 ms on top of the transition, which forced an offscreen layer of every
  // blurred shadow and gradient each frame (worst frame ~500 ms on first open).
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[
      _buildIntroCard(),
      _gap,
      _buildServiceTypeSection(),
      _gap,
      _buildCylinderSection(),
      if (_selectedType != GasRefillType.pickupAndReturn) ...[
        _gap,
        _buildBrandSection(),
      ],
      if (_selectedType == GasRefillType.commercialBulk) ...[
        const SizedBox(height: 12),
        _buildQuantitySection(),
      ],
      _gap,
      _buildAddressSection(),
      _gap,
      _buildSafetySection(),
      _gap,
      const CtsSectionHeader('Payment'),
      _buildPaymentSelector(),
      _gap,
      _buildPriceSummary(),
      const SizedBox(height: 24),
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: CtsTheme.background,
        body: Column(
          children: [
            CtsServiceHeader(
              title: 'Cooking gas',
              subtitle: 'Delivered to your door',
              trailing: Semantics(
                button: true,
                label: 'Help',
                excludeSemantics: true,
                onTap: _showHelp,
                child: Material(
                  color: CtsTheme.surface,
                  shape: const CircleBorder(
                      side: BorderSide(color: CtsTheme.border)),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _showHelp,
                    child: const SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(Icons.headset_mic_rounded,
                          color: CtsTheme.textPrimary, size: 19),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding:
                        const EdgeInsets.fromLTRB(ctsGutter, 6, ctsGutter, 0),
                    sliver: SliverList.list(children: sections),
                  ),
                ],
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  static const Widget _gap = SizedBox(height: 22);

  void _toggleBrand(GasBrand brand) {
    HapticFeedback.selectionClick();
    setState(() => _selectedBrand = _selectedBrand == brand ? null : brand);
  }

  void _toggleSafety() {
    HapticFeedback.selectionClick();
    setState(() => _safetyAccepted = !_safetyAccepted);
  }

  // ─────────────────────────────────────────────
  // INTRO — photo + progress
  // ─────────────────────────────────────────────

  Widget _buildIntroCard() => CtsCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: const SizedBox(
                width: 84,
                child: ServiceImage(service: ServiceType.gas, aspectRatio: 1),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Order cooking gas',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        color: CtsTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      )),
                  const SizedBox(height: 2),
                  const Text(
                      'Choose a service and cylinder, then where to deliver.',
                      style: TextStyle(
                        color: CtsTheme.textSecondary,
                        fontSize: 12.5,
                        height: 1.35,
                      )),
                  const SizedBox(height: 10),
                  _buildProgress(),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _buildProgress() {
    const labels = ['Order', 'Delivery', 'Review'];
    return Semantics(
      label: 'Step ${_currentStep + 1} of 3, ${labels[_currentStep]}',
      excludeSemantics: true,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 4,
                    decoration: BoxDecoration(
                      color: i <= _currentStep
                          ? CtsTheme.primary
                          : CtsTheme.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(labels[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: i <= _currentStep
                            ? CtsTheme.primaryDeep
                            : CtsTheme.textTertiary,
                      )),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // SERVICE TYPE
  // ─────────────────────────────────────────────

  Widget _buildServiceTypeSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CtsSectionHeader('Service'),
          for (final type in GasRefillType.values) ...[
            CtsSelectableCard(
              selected: type == _selectedType,
              semanticLabel:
                  '${type.displayName}, about ${_formatDuration(type.estimatedDuration)}',
              showCheck: false,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _selectedType = type);
              },
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: type == _selectedType
                          ? CtsTheme.surface
                          : CtsTheme.surfaceAlt,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(type.icon,
                        size: 20,
                        color: type == _selectedType
                            ? CtsTheme.primaryDeep
                            : CtsTheme.textSecondary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(type.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: CtsTheme.textPrimary,
                            )),
                        Text('About ${_formatDuration(type.estimatedDuration)}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: CtsTheme.textSecondary,
                            )),
                      ],
                    ),
                  ),
                  _RadioDot(selected: type == _selectedType),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      );

  // ─────────────────────────────────────────────
  // CYLINDER SIZE
  // ─────────────────────────────────────────────

  // Per-cylinder price for the selected service, from the same price lists
  // GasPricing charges (new cylinders use the full-cylinder price).
  double _unitPriceFor(CylinderSize size) =>
      _selectedType == GasRefillType.newCylinder
          ? size.fullCylinderPrice
          : size.refillPrice;

  Widget _buildCylinderSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CtsSectionHeader('Cylinder size',
              caption: _selectedType == GasRefillType.newCylinder
                  ? 'Price per new cylinder'
                  : 'Price per refill'),
          LayoutBuilder(builder: (_, c) {
            const spacing = 8.0;
            final w = (c.maxWidth - spacing * 2) / 3;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final size in CylinderSize.values)
                  SizedBox(
                    width: w,
                    child: CtsSelectableCard(
                      selected: size == _selectedSize,
                      semanticLabel:
                          '${size.displayName}, ₵${_unitPriceFor(size).toStringAsFixed(0)}',
                      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedSize = size);
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.propane_tank_rounded,
                              size: 20,
                              color: size == _selectedSize
                                  ? CtsTheme.primaryDeep
                                  : CtsTheme.textSecondary),
                          const SizedBox(height: 8),
                          Text(size.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: CtsTheme.textPrimary,
                              )),
                          Text('₵${_unitPriceFor(size).toStringAsFixed(0)}',
                              maxLines: 1,
                              style: const TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: CtsTheme.primaryDeep,
                              )),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          }),
        ],
      );

  // ─────────────────────────────────────────────
  // BRAND (optional)
  // ─────────────────────────────────────────────

  Widget _buildBrandSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CtsSectionHeader('Preferred brand',
              caption: _selectedBrand == null
                  ? 'Optional · any brand if none chosen'
                  : 'Tap again to clear'),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: GasBrand.values.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final brand = GasBrand.values[i];
                final selected = brand == _selectedBrand;
                return Semantics(
                  button: true,
                  selected: selected,
                  label: brand.displayName,
                  excludeSemantics: true,
                  onTap: () => _toggleBrand(brand),
                  child: Material(
                    color: selected ? CtsTheme.primary : CtsTheme.surface,
                    shape: StadiumBorder(
                      side: BorderSide(
                          color: selected ? CtsTheme.primary : CtsTheme.border),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => _toggleBrand(brand),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Center(
                          child: Text(brand.displayName,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: selected
                                    ? Colors.white
                                    : CtsTheme.textPrimary,
                              )),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );

  // ─────────────────────────────────────────────
  // QUANTITY (commercial only)
  // ─────────────────────────────────────────────

  Widget _buildQuantitySection() => CtsCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quantity',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: CtsTheme.textPrimary,
                      )),
                  Text('Number of cylinders',
                      style: TextStyle(
                          fontSize: 12, color: CtsTheme.textSecondary)),
                ],
              ),
            ),
            _QtyBtn(
              icon: Icons.remove_rounded,
              label: 'Fewer cylinders',
              onTap: _quantity > 1
                  ? () {
                      HapticFeedback.selectionClick();
                      setState(() => _quantity--);
                    }
                  : null,
            ),
            SizedBox(
              width: 44,
              child: Text('$_quantity',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: CtsTheme.textPrimary,
                  )),
            ),
            _QtyBtn(
              icon: Icons.add_rounded,
              label: 'More cylinders',
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _quantity++);
              },
            ),
          ],
        ),
      );

  // ─────────────────────────────────────────────
  // ADDRESS
  // ─────────────────────────────────────────────

  Widget _buildAddressSection() {
    final hasAddress = _deliveryAddress != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const CtsSectionHeader('Delivery address'),
        Semantics(
          button: true,
          label: hasAddress
              ? 'Delivery address, $_deliveryAddress. Change'
              : 'Set your delivery location',
          excludeSemantics: true,
          onTap: _selectAddress,
          child: Material(
            color: CtsTheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: hasAddress ? CtsTheme.primary : CtsTheme.border,
                width: hasAddress ? 1.5 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _selectAddress,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: hasAddress
                            ? CtsTheme.primaryTint
                            : CtsTheme.surfaceAlt,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.location_on_rounded,
                          size: 20,
                          color: hasAddress
                              ? CtsTheme.primaryDeep
                              : CtsTheme.textSecondary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasAddress
                                ? 'Deliver to'
                                : 'Where should we deliver?',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: CtsTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _deliveryAddress ?? 'Tap to set your location',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              fontWeight: hasAddress
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: hasAddress
                                  ? CtsTheme.textPrimary
                                  : CtsTheme.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(hasAddress ? 'Change' : 'Set',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: CtsTheme.primaryDeep,
                        )),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: CtsTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Expanded(
                child: _InfoPair(
                  icon: Icons.access_time_rounded,
                  label: 'Est. delivery',
                  value: _etaText,
                ),
              ),
              Container(width: 1, height: 28, color: CtsTheme.border),
              const SizedBox(width: 14),
              Expanded(
                child: _InfoPair(
                  icon: Icons.local_shipping_rounded,
                  label: _pricing.deliveryLabel,
                  value: _calculatingDistance
                      ? 'Calculating…'
                      : '₵${_deliveryFee.toStringAsFixed(2)}',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────
  // SAFETY CHECKLIST
  // ─────────────────────────────────────────────

  Widget _buildSafetySection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CtsSectionHeader('Safety checklist',
              caption: 'Please confirm before we send a driver'),
          CtsCard(
            borderColor: _safetyAccepted ? CtsTheme.primary : null,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: Column(
              children: [
                const _SafetyItem('Valid empty cylinder ready for exchange',
                    'Ensure cylinder is not expired and has valid certification'),
                const SizedBox(height: 10),
                const _SafetyItem(
                    'Cylinder in good condition — no leaks or damage',
                    'Check for rust, dents, or damaged valves'),
                const SizedBox(height: 10),
                const _SafetyItem('I understand gas safety guidelines',
                    'Keep upright, away from heat, in ventilated area'),
                const Divider(height: 20, color: CtsTheme.border),
                Semantics(
                  checked: _safetyAccepted,
                  label: 'I confirm all safety requirements are met',
                  excludeSemantics: true,
                  onTap: _toggleSafety,
                  child: InkWell(
                    onTap: _toggleSafety,
                    borderRadius: BorderRadius.circular(10),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Row(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: _safetyAccepted
                                  ? CtsTheme.primary
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: _safetyAccepted
                                    ? CtsTheme.primary
                                    : CtsTheme.textTertiary,
                                width: 1.5,
                              ),
                            ),
                            child: _safetyAccepted
                                ? const Icon(Icons.check_rounded,
                                    color: Colors.white, size: 15)
                                : null,
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'I confirm all safety requirements are met',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: CtsTheme.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );

  // ─────────────────────────────────────────────
  // PRICE SUMMARY — every figure comes from GasPricing (_pricing)
  // ─────────────────────────────────────────────

  Widget _buildPriceSummary() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CtsSectionHeader('Order summary'),
          CtsCard(
            child: Column(
              children: [
                _PriceLine(
                  label:
                      '${_pricing.unitLabel} · ${_selectedSize.displayName} × $_quantity',
                  value: '₵${_basePrice.toStringAsFixed(2)}',
                ),
                const SizedBox(height: 8),
                _PriceLine(
                    label: _pricing.deliveryLabel,
                    value: '₵${_deliveryFee.toStringAsFixed(2)}'),
                if (_brandPremium > 0) ...[
                  const SizedBox(height: 8),
                  _PriceLine(
                    label: '${_selectedBrand!.displayName} premium',
                    value: '₵${_brandPremium.toStringAsFixed(2)}',
                  ),
                ],
                const Divider(height: 24, color: CtsTheme.border),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Total',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: CtsTheme.textPrimary,
                          )),
                    ),
                    Text('₵${_total.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: CtsTheme.textPrimary,
                        )),
                  ],
                ),
              ],
            ),
          ),
        ],
      );

  // ─────────────────────────────────────────────
  // BOTTOM BAR — hint, payment method, confirm
  // ─────────────────────────────────────────────

  Widget _buildBottomBar() {
    final valid = _isOrderValid();
    return Container(
      decoration: const BoxDecoration(
        color: CtsTheme.surface,
        border: Border(top: BorderSide(color: CtsTheme.border)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(ctsGutter, 12, ctsGutter, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!valid) ...[
                _buildValidationHint(),
                const SizedBox(height: 10),
              ],
              CtsPrimaryButton(
                label: 'Confirm gas order',
                trailingText: '₵${_total.toStringAsFixed(2)}',
                icon: Icons.local_fire_department_rounded,
                loading: _isSubmitting,
                onPressed: valid ? _placeOrder : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildValidationHint() {
    final hints = <String>[];
    if (_deliveryAddress == null) hints.add('Set a delivery address');
    if (!_safetyAccepted) hints.add('confirm the safety checklist');
    if (hints.isEmpty) return const SizedBox.shrink();
    final text = hints.join(' and ');
    return Row(
      children: [
        const Icon(Icons.info_outline_rounded,
            color: CtsTheme.textSecondary, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${text[0].toUpperCase()}${text.substring(1)} to continue.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              color: CtsTheme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  bool _isOrderValid() =>
      _deliveryAddress != null && _deliveryGeoPoint != null && _safetyAccepted;

  Future<void> _selectAddress() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AddressPickerSheet(),
    );
    if (result != null && mounted) {
      setState(() {
        _deliveryAddress = result['address'] as String;
        _deliveryGeoPoint = result['location'] as GeoPoint;
      });
      _updateDistance(); // recompute pricing distance for the new location
    }
  }

  /// Estimates the one-way distance from the customer to the nearest available
  /// gas driver (haversine × road factor). Falls back to 5km if none online.
  /// Charged at order time; the assigned driver ≈ nearest, so estimate ≈ actual.

  Future<void> _updateDistance() async {
    final dest = _deliveryGeoPoint;
    if (dest == null) return;
    setState(() => _calculatingDistance = true);
    try {
      final snap = await FirebaseFirestore.instance
          .collection('drivers')
          .where('isOnline', isEqualTo: true)
          .where('isApproved', isEqualTo: true)
          .where('isAvailable', isEqualTo: true)
          .get();

      double? nearest;
      var matched = 0;
      for (final doc in snap.docs) {
        final data = doc.data();
        final sType = (data['serviceType'] as String?) ?? '';
        final services =
            (data['services'] as List?)?.cast<String>() ?? const [];
        final canDoGas = sType == 'delivery' ||
            sType == 'gas' ||
            services.contains('gas') ||
            services.contains('delivery');
        if (!canDoGas) continue;
        final loc = data['location'] ?? data['currentLocation'];
        if (loc is! GeoPoint) continue;
        matched++;
        final km = _haversineKm(
            dest.latitude, dest.longitude, loc.latitude, loc.longitude);
        if (nearest == null || km < nearest) nearest = km;
      }
      debugPrint('GAS distance: ${snap.docs.length} online, '
          '$matched delivery-with-location, nearest=${nearest?.toStringAsFixed(2)}km');

      final oneWay = nearest != null ? (nearest * 1.3).clamp(1.0, 30.0) : 5.0;
      if (mounted) {
        setState(() {
          _distanceKm = oneWay.toDouble();
          _calculatingDistance = false;
        });
      }
    } catch (e) {
      debugPrint('gas distance calc failed: $e');
      if (mounted) {
        setState(() {
          _distanceKm = 5.0;
          _calculatingDistance = false;
        });
      }
    }
  }

  static double _haversineKm(
      double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * (math.pi / 180);
    final dLon = (lon2 - lon1) * (math.pi / 180);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  Widget _buildPaymentSelector() {
    Widget option(String value, IconData icon, String label, String sub) {
      final selected = _paymentMethod == value;
      return Expanded(
        child: CtsSelectableCard(
          selected: selected,
          semanticLabel: '$label, $sub',
          showCheck: false,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          onTap: () => setState(() => _paymentMethod = value),
          child: Row(children: [
            Icon(icon,
                size: 18,
                color:
                    selected ? CtsTheme.primaryDeep : CtsTheme.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: CtsTheme.textPrimary,
                      )),
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: CtsTheme.textSecondary)),
                ],
              ),
            ),
          ]),
        ),
      );
    }

    return Row(children: [
      option('wallet', Icons.account_balance_wallet_rounded, 'Wallet',
          'Pay from balance'),
      const SizedBox(width: 10),
      option('cash', Icons.payments_rounded, 'Cash', 'Pay driver directly'),
    ]);
  }

  Future<void> _placeOrder() async {
    if (!_isOrderValid() || _isSubmitting) return; // ← add _isSubmitting check
    setState(() => _isSubmitting = true);

    if (_paymentMethod == 'wallet') {
      final paymentConfirmed = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        isDismissible: !_isSubmitting,
        useSafeArea: true,
        builder: (ctx) => GasPaymentSheet(
          refillType: _selectedType,
          cylinderSize: _selectedSize,
          brand: _selectedBrand,
          quantity: _quantity,
          gasPrice: _selectedSize.refillPrice,
          deliveryFee: _deliveryFee,
          total: _total,
        ),
      );

      if (paymentConfirmed != true || !mounted) {
        if (mounted) setState(() => _isSubmitting = false);
        return;
      }
    }

    // ── Hold funds before placing gas order (wallet only) ─────────────────
    String? escrowId;
    if (_paymentMethod == 'wallet') {
      final escrowResult = await EscrowService.instance.holdBalance(
        amount: _total,
        serviceType: 'delivery',
        referenceType: 'gas_order',
      );
      if (!escrowResult.success) {
        if (mounted) {
          setState(() => _isSubmitting = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(escrowResult.shortfall != null
                ? 'Need GH₵${escrowResult.shortfall!.toStringAsFixed(2)} more. Top up wallet.'
                : escrowResult.error ?? 'Payment hold failed.'),
            backgroundColor: const Color(0xFFDC2626),
            action: SnackBarAction(
              label: 'Top Up',
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .pushNamed('/wallet'),
            ),
          ));
        }
        return;
      }
      escrowId = escrowResult.escrowId!;
    }

    try {
      final user = FirebaseAuth.instance.currentUser ??
          ref.read(authStateProvider).value;
      if (user == null) throw Exception('Please log in to place an order.');

      final order = GasRefillRequest(
        id: '',
        passengerId: user.uid,
        driverId: null,
        refillType: _selectedType,
        cylinderSize: _selectedSize,
        preferredBrand: _selectedBrand,
        quantity: _quantity,
        status: GasOrderStatus.pendingApproval,
        pickupLocation: _deliveryGeoPoint!,
        deliveryLocation: _deliveryGeoPoint!,
        preferredStation: null,
        pickupAddress: _deliveryAddress!,
        deliveryAddress: _deliveryAddress!,
        preferredStationAddress: null,
        pickupInstructions: null,
        deliveryInstructions: null,
        cylinderIsAvailable: true,
        cylinderInGoodCondition: true,
        cylinderConditionNotes: null,
        safetyChecklistCompleted: _safetyAccepted,
        gasAmount: _selectedSize.weight * _quantity,
        gasPrice: _selectedSize.refillPrice,
        serviceFee: 0,
        deliveryFee: _deliveryFee,
        totalPrice: _total,
        createdAt: DateTime.now(),
        scheduledPickupAt: null,
        scheduledDeliveryBy: null,
        pickupCompletedAt: null,
        refillCompletedAt: null,
        deliveredAt: null,
        cancelledAt: null,
        paymentMethod: _paymentMethod,
        requiresReceipt: false,
        receiptEmail: null,
        passengerRating: null,
        driverRating: null,
        metadata: {
          'appVersion': '1.0.0',
          'platform': 'flutter',
        },
      );

      final repo = ref.read(gasOrderRepositoryProvider);
      final orderId = await repo.createGasOrder(order);

      if (escrowId != null) {
        await EscrowService.instance.attachToOrder(
          escrowId: escrowId,
          referenceId: orderId,
          referenceType: 'gas_order',
        );
        // Save escrowId to gas order document for CF cancellation refund
        await FirebaseFirestore.instance
            .collection('gas_orders')
            .doc(orderId)
            .update({'escrowId': escrowId});
      }

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
              builder: (_) => GasOrderTrackingScreen(orderId: orderId)),
        );
      }
    } catch (e) {
      // Rollback escrow if order creation failed (wallet bookings only)
      if (escrowId != null) {
        try {
          final fns = FirebaseFunctions.instanceFor(region: 'europe-west2');
          await fns.httpsCallable('refundEscrowOnError').call({
            'escrowId': escrowId,
            'reason': 'order_creation_failed',
          });
        } catch (_) {/* Stuck escrow auto-releases after 2hrs */}
      }
      // Rollback escrow if order creation failed
      try {
        final fns = FirebaseFunctions.instanceFor(region: 'europe-west2');
        await fns.httpsCallable('refundEscrowOnError').call({
          'escrowId': escrowId,
          'reason': 'order_creation_failed',
        });
      } catch (_) {/* Stuck escrow auto-releases after 2hrs */}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: GasTheme.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showHelp() {
    showModalBottomSheet(
      context: context,
      backgroundColor: GasTheme.surface,
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
                  color: GasTheme.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Need Help?',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: GasTheme.textPrimary,
                )),
            const SizedBox(height: 16),
            _HelpRow(Icons.phone_rounded, '+233 XX XXX XXXX'),
            const SizedBox(height: 12),
            _HelpRow(Icons.email_rounded, 'support@ctstransport.com'),
            const SizedBox(height: 12),
            _HelpRow(Icons.access_time_rounded, '24/7 Support'),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    return '${d.inMinutes}m';
  }
}

// ─────────────────────────────────────────────
// PRIVATE WIDGETS
// ─────────────────────────────────────────────

class _RadioDot extends StatelessWidget {
  final bool selected;
  const _RadioDot({required this.selected});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? CtsTheme.primary : Colors.transparent,
          border: Border.all(
            color: selected ? CtsTheme.primary : CtsTheme.textTertiary,
            width: 1.5,
          ),
        ),
        child: selected
            ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
            : null,
      );
}

class _QtyBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _QtyBtn({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onTap != null,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          color: onTap != null ? CtsTheme.primaryTint : CtsTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon,
                  size: 20,
                  color: onTap != null
                      ? CtsTheme.primaryDeep
                      : CtsTheme.textTertiary),
            ),
          ),
        ),
      );
}

class _InfoPair extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _InfoPair(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, color: CtsTheme.primaryDeep, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: CtsTheme.textSecondary)),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: CtsTheme.textPrimary,
                    )),
              ],
            ),
          ),
        ],
      );
}

class _SafetyItem extends StatelessWidget {
  final String title, subtitle;
  const _SafetyItem(this.title, this.subtitle);

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: CtsTheme.primaryTint,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_rounded,
                color: CtsTheme.primaryDeep, size: 12),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: GasTheme.textPrimary,
                    )),
                const SizedBox(height: 1),
                Text(subtitle,
                    style:
                        TextStyle(fontSize: 11, color: GasTheme.textTertiary)),
              ],
            ),
          ),
        ],
      );
}

class _PriceLine extends StatelessWidget {
  final String label, value;
  const _PriceLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: CtsTheme.textSecondary)),
          ),
          const SizedBox(width: 12),
          Text(value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: CtsTheme.textPrimary,
              )),
        ],
      );
}

class _HelpRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _HelpRow(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: GasTheme.primaryDim,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: GasTheme.primary, size: 17),
          ),
          const SizedBox(width: 12),
          Text(text,
              style: TextStyle(
                fontSize: 14,
                color: GasTheme.textPrimary,
                fontWeight: FontWeight.w500,
              )),
        ],
      );
}
