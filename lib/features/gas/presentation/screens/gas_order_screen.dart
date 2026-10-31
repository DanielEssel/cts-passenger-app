// lib/features/gas/presentation/screens/gas_order_screen.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../../../core/services/escrow_service.dart';
import '../../../../core/services/pricing_service.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/gas_checkout.dart';
import '../../domain/gas_pricing.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../../core/theme/cts_theme.dart';
import '../../../../core/widgets/cts_booking.dart';
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
  /// Outside calls; the defaults are the real services.
  final GasCheckoutDeps deps;

  const GasOrderScreen({super.key, this.deps = const GasCheckoutDeps()});

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
  double? _distanceKm = 5.0; // one-way estimate, for the ETA only; null: failed
  bool _calculatingDistance = false;

  /// Bumped for every distance request; only the newest one may apply its
  /// result, so a slow answer for an earlier address can't replace the
  /// price for the address now shown.
  int _distanceRequest = 0;
  String _paymentMethod = 'wallet'; // 'wallet' | 'cash'

  /// Single source of truth for this order's pricing (type-aware). The
  /// delivery charge is at the standard distance the server charges
  /// (functions/gas_pricing.js), never the distance estimate.
  GasPriceBreakdown get _pricing {
    final p = PricingService.instance;
    return GasPricing.compute(
      type: _selectedType,
      size: _selectedSize,
      quantity: _quantity,
      brand: _selectedBrand,
      distanceKm: GasPricing.standardDistanceKm,
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
    final distanceKm = _distanceKm;
    if (distanceKm == null) return 'Unavailable';
    final isRoundTrip = _selectedType == GasRefillType.pickupAndReturn;
    final legs = isRoundTrip ? 2 : 1;
    final travel = distanceKm * 3 * legs; // ~3 min/km
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

  bool get _isRoundTrip => _selectedType == GasRefillType.pickupAndReturn;

  /// The total is shown once an address is set (the order is priced for
  /// it), unless the configured Gas prices cannot be used.
  bool get _priceKnown => _deliveryGeoPoint != null && _pricingProblem == null;

  /// Why Gas cannot be priced now (malformed settings), or null.
  String? get _pricingProblem => PricingService.instance.gasPricingProblem;

  // ─────────────────────────────────────────────
  // BUILD
  //
  // Forest header with progress, then numbered sections: service → cylinder
  // (and provider) → address → safety → payment, the price panel, and a
  // pinned "Place gas order" bar. Only fields relevant to the chosen service
  // are shown. Sections live in a lazily built SliverList and render at full
  // opacity with the page transition (no fade-in: it cost ~500 ms frames).
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[
      _buildServiceTypeSection(),
      _gap,
      _buildCylinderSection(),
      _gap,
      _buildAddressSection(),
      _gap,
      _buildSafetySection(),
      _gap,
      CtsFormSection(
        number: '5',
        title: 'Payment',
        child: _buildPaymentSelector(),
      ),
      _gap,
      _buildPriceSummary(),
      const SizedBox(height: 24),
    ];
    final valid = _isOrderValid();
    final canSubmit = _canSubmit;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: ctsBrandOverlay,
      child: Scaffold(
        backgroundColor: CtsTheme.canvas,
        body: Column(
          children: [
            const CtsStatusBarStrip(),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: CtsBrandHeader(
                      eyebrow: 'Cooking gas · LPG',
                      title: 'Gas to your door',
                      subtitle:
                          'Exchange, refill or buy a cylinder. A driver brings '
                          'it to you.',
                      visual: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: const SizedBox(
                          width: 72,
                          child: ServiceImage(
                              service: ServiceType.gas, aspectRatio: 1),
                        ),
                      ),
                      trailing: CtsHeaderIconButton(
                        icon: Icons.support_agent_rounded,
                        label: 'Help and support',
                        onTap: _showHelp,
                      ),
                      footer: CtsHeaderProgress(
                        steps: const ['Order', 'Delivery', 'Review'],
                        current: _currentStep,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding:
                        const EdgeInsets.fromLTRB(ctsGutter, 18, ctsGutter, 0),
                    sliver: SliverList.list(children: sections),
                  ),
                ],
              ),
            ),
            CtsBookingBar(
              hint: _pricingProblem != null
                  ? 'Gas ordering is unavailable while prices are being '
                      'updated. Please try again shortly.'
                  : !valid
                      ? _validationHint
                      : null,
              action: CtsPrimaryButton(
                label: 'Place gas order',
                trailingText:
                    _priceKnown ? 'GHS ${_total.toStringAsFixed(2)}' : null,
                icon: Icons.local_fire_department_rounded,
                loading: _isSubmitting,
                onPressed: canSubmit ? _placeOrder : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const Widget _gap = SizedBox(height: 16);

  void _toggleBrand(GasBrand brand) {
    HapticFeedback.selectionClick();
    setState(() => _selectedBrand = _selectedBrand == brand ? null : brand);
  }

  void _toggleSafety() {
    HapticFeedback.selectionClick();
    setState(() => _safetyAccepted = !_safetyAccepted);
  }

  // ─────────────────────────────────────────────
  // SERVICE TYPE
  // ─────────────────────────────────────────────

  static String _typeDescription(GasRefillType t) => switch (t) {
        GasRefillType.exchangeEmpty =>
          'Swap your empty cylinder for a full one',
        GasRefillType.newCylinder => 'Buy a new, filled cylinder',
        GasRefillType.pickupAndReturn =>
          'We collect your cylinder, refill it and bring it back',
        GasRefillType.commercialBulk => 'Several cylinders for a business',
      };

  Widget _typeCard(GasRefillType type) {
    final selected = type == _selectedType;
    return CtsSelectableCard(
      selected: selected,
      semanticLabel: '${type.displayName}. ${_typeDescription(type)}. '
          'About ${_formatDuration(type.estimatedDuration)}',
      showCheck: false,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selectedType = type);
      },
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: selected ? CtsTheme.forest : CtsTheme.mint,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(type.icon,
                size: 22, color: selected ? Colors.white : CtsTheme.forest),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(type.displayName,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      color: CtsTheme.charcoal,
                    )),
                const SizedBox(height: 2),
                Text(_typeDescription(type),
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.3,
                      color: CtsTheme.textSecondary,
                    )),
                const SizedBox(height: 2),
                Text('About ${_formatDuration(type.estimatedDuration)}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: CtsTheme.forest,
                    )),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _RadioDot(selected: selected),
        ],
      ),
    );
  }

  Widget _buildServiceTypeSection() => CtsFormSection(
        number: '1',
        title: 'Service',
        caption: 'How would you like your gas?',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const CtsSubheading('Delivered to you'),
            for (final type in const [
              GasRefillType.exchangeEmpty,
              GasRefillType.newCylinder,
              GasRefillType.commercialBulk,
            ]) ...[
              _typeCard(type),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            const CtsSubheading('Refill my own cylinder'),
            _typeCard(GasRefillType.pickupAndReturn),
          ],
        ),
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

  Widget _buildCylinderSection() => CtsFormSection(
        number: '2',
        title: 'Cylinder',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CtsSubheading('Cylinder size',
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
                            '${size.displayName}, GHS ${_unitPriceFor(size).toStringAsFixed(0)}',
                        padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _selectedSize = size);
                        },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.propane_tank_rounded,
                                size: 22,
                                color: size == _selectedSize
                                    ? CtsTheme.forest
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
                            Text('GHS ${_unitPriceFor(size).toStringAsFixed(0)}',
                                maxLines: 1,
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w800,
                                  color: CtsTheme.forest,
                                )),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            }),
            if (_selectedType == GasRefillType.commercialBulk) ...[
              const SizedBox(height: 14),
              _buildQuantitySection(),
            ],
            // Pickup & Return refills the customer's own cylinder, so no
            // provider is chosen.
            if (!_isRoundTrip) ...[
              const SizedBox(height: 18),
              _buildBrandSection(),
            ],
          ],
        ),
      );

  // ─────────────────────────────────────────────
  // BRAND (optional)
  // ─────────────────────────────────────────────

  /// The brand's real price effect, from the multiplier GasPricing applies.
  static String _brandPriceNote(GasBrand b) {
    final pct = ((b.priceMultiplier - 1) * 100).round();
    return pct > 0 ? '+$pct% on gas' : 'Standard price';
  }

  /// Short form of [_brandPriceNote] for the chip badge; null when standard.
  static String? _brandPremiumBadge(GasBrand b) {
    final pct = ((b.priceMultiplier - 1) * 100).round();
    return pct > 0 ? '+$pct%' : null;
  }

  // Compact chips that wrap to the width: one 48dp row holds 2–4 providers,
  // so the full list stays visible without a tall grid of cards.
  Widget _buildBrandSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CtsSubheading('Gas provider',
              caption: _selectedBrand == null
                  ? 'Optional · standard price unless marked'
                  : 'Tap again to clear'),
          LayoutBuilder(
            builder: (_, c) => Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final brand in GasBrand.values)
                  ConstrainedBox(
                    // A chip never exceeds the row, so long names wrap
                    // inside it instead of clipping.
                    constraints: BoxConstraints(maxWidth: c.maxWidth),
                    child: _BrandChip(
                      name: brand.displayName,
                      badge: _brandPremiumBadge(brand),
                      selected: brand == _selectedBrand,
                      semanticLabel:
                          '${brand.displayName}, ${_brandPriceNote(brand)}',
                      onTap: () => _toggleBrand(brand),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );

  // ─────────────────────────────────────────────
  // QUANTITY (commercial only)
  // ─────────────────────────────────────────────

  Widget _buildQuantitySection() => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(
          color: CtsTheme.mint,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: CtsTheme.mintBorder),
        ),
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
              // The server prices at most GasPricing.maxQuantity cylinders.
              onTap: _quantity < GasPricing.maxQuantity
                  ? () {
                      HapticFeedback.selectionClick();
                      setState(() => _quantity++);
                    }
                  : null,
            ),
          ],
        ),
      );

  // ─────────────────────────────────────────────
  // ADDRESS
  // ─────────────────────────────────────────────

  Widget _buildAddressSection() {
    final hasAddress = _deliveryAddress != null;
    return CtsFormSection(
      number: '3',
      title: _isRoundTrip ? 'Collection & return address' : 'Delivery address',
      caption: _isRoundTrip
          ? 'We collect your cylinder here, refill it at a station and bring '
              'it back here.'
          : 'Where the driver brings your gas',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            label: hasAddress
                ? 'Delivery address, $_deliveryAddress. Change'
                : 'Set your delivery location',
            excludeSemantics: true,
            onTap: _selectAddress,
            child: Material(
              color: hasAddress ? CtsTheme.mint : CtsTheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: hasAddress ? CtsTheme.primary : CtsTheme.cardEdge,
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
                                  ? (_isRoundTrip
                                      ? 'Collect from'
                                      : 'Deliver to')
                                  : 'Where are you?',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: CtsTheme.forest,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _deliveryAddress ?? 'Tap to set your location',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 15,
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
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: CtsTheme.forest,
                          )),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Estimates only once an address is set and measured.
          if (_deliveryGeoPoint != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: CtsTheme.canvas,
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
                      value: 'GHS ${_deliveryFee.toStringAsFixed(2)}',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // SAFETY CHECKLIST
  // ─────────────────────────────────────────────

  Widget _buildSafetySection() => CtsFormSection(
        number: '4',
        title: 'Safety check',
        caption: 'Please confirm before we send a driver',
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
          decoration: BoxDecoration(
            color: _safetyAccepted ? CtsTheme.mint : CtsTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _safetyAccepted ? CtsTheme.primary : CtsTheme.cardEdge,
              width: _safetyAccepted ? 1.5 : 1,
            ),
          ),
          child: Column(
            children: [
              // A new cylinder needs no empty one; the others hand over
              // the customer's own cylinder.
              if (_selectedType != GasRefillType.newCylinder) ...[
                _SafetyItem(
                    _isRoundTrip
                        ? 'Your cylinder is ready for collection'
                        : 'Valid empty cylinder ready for exchange',
                    'Ensure cylinder is not expired and has valid certification'),
                const SizedBox(height: 10),
                const _SafetyItem(
                    'Cylinder in good condition — no leaks or damage',
                    'Check for rust, dents, or damaged valves'),
                const SizedBox(height: 10),
              ],
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
                              fontSize: 14.5,
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
      );

  // ─────────────────────────────────────────────
  // PRICE SUMMARY — every figure comes from GasPricing (_pricing)
  // ─────────────────────────────────────────────

  Widget _buildPriceSummary() => CtsPriceSummary(
        lines: [
          CtsPriceLine(
            '${_pricing.unitLabel} · ${_selectedSize.displayName} × $_quantity',
            'GHS ${_basePrice.toStringAsFixed(2)}',
          ),
          if (_brandPremium > 0)
            CtsPriceLine('${_selectedBrand!.displayName} premium',
                'GHS ${_brandPremium.toStringAsFixed(2)}'),
          CtsPriceLine(
            _pricing.deliveryLabel,
            _priceKnown ? 'GHS ${_deliveryFee.toStringAsFixed(2)}' : 'After address',
          ),
        ],
        totalLabel: 'Total',
        total: _priceKnown ? 'GHS ${_total.toStringAsFixed(2)}' : null,
        pendingText: 'Set your address',
        note: _priceKnown
            ? null
            : 'The total appears once your address is set. The delivery fee '
                'is a flat charge, the same for every address.',
      );

  // ─────────────────────────────────────────────
  // BOTTOM BAR — hint, payment method, confirm
  // ─────────────────────────────────────────────

  /// What is still missing before the order can be placed.
  String get _validationHint {
    final hints = <String>[];
    if (_deliveryAddress == null) hints.add('Set a delivery address');
    if (!_safetyAccepted) hints.add('confirm the safety checklist');
    if (hints.isEmpty) return '';
    final text = hints.join(' and ');
    return '${text[0].toUpperCase()}${text.substring(1)} to continue.';
  }

  bool _isOrderValid() =>
      _deliveryAddress != null && _deliveryGeoPoint != null && _safetyAccepted;

  /// The order may be placed: the form is complete and Gas can be priced.
  /// The distance estimate (ETA only) is not waited for.
  bool get _canSubmit => _isOrderValid() && _pricingProblem == null;

  /// Fixes the order's inputs and price at the moment of submission.
  GasOrderQuote _captureQuote() => GasOrderQuote(
        type: _selectedType,
        size: _selectedSize,
        brand: _selectedBrand,
        quantity: _quantity,
        address: _deliveryAddress!,
        location: _deliveryGeoPoint!,
        paymentMethod: _paymentMethod,
        safetyAccepted: _safetyAccepted,
        pricing: _pricing,
      );

  Future<void> _selectAddress() async {
    final pick = widget.deps.pickAddress;
    final result = pick != null
        ? await pick(context)
        : await showModalBottomSheet<Map<String, dynamic>>(
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
  /// gas driver (haversine × road factor), for the ETA only. Falls back to
  /// 5km if none online; when the estimate fails the ETA is shown as
  /// unavailable rather than guessed. The price never uses it.

  Future<void> _updateDistance() async {
    final dest = _deliveryGeoPoint;
    if (dest == null) return;
    final request = ++_distanceRequest;
    setState(() => _calculatingDistance = true);
    double? km;
    try {
      final estimate = widget.deps.estimateDistanceKm ?? _nearestDriverKm;
      km = await estimate(dest);
    } catch (e) {
      debugPrint('gas distance calc failed: $e');
    }
    // A newer address was chosen meanwhile: its own request decides.
    if (!mounted || request != _distanceRequest) return;
    setState(() {
      _distanceKm = km;
      _calculatingDistance = false;
    });
  }

  // Passengers may not read drivers/{id}. driver_map (functions/driver_map.js)
  // holds only the rounded position and vehicle type of online, approved,
  // available drivers.
  Future<double> _nearestDriverKm(GeoPoint dest) async {
    final snap = await FirebaseFirestore.instance
        .collection('driver_map')
        .where('serviceType', whereIn: const ['delivery', 'gas'])
        .get();

    double? nearest;
    var matched = 0;
    for (final doc in snap.docs) {
      final loc = doc.data()['location'];
      if (loc is! GeoPoint) continue;
      matched++;
      final km = _haversineKm(
          dest.latitude, dest.longitude, loc.latitude, loc.longitude);
      if (nearest == null || km < nearest) nearest = km;
    }
    debugPrint('GAS distance: ${snap.docs.length} online, '
        '$matched delivery-with-location, nearest=${nearest?.toStringAsFixed(2)}km');

    final oneWay = nearest != null ? (nearest * 1.3).clamp(1.0, 30.0) : 5.0;
    return oneWay.toDouble();
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
                          fontSize: 12, color: CtsTheme.textSecondary)),
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
    // Never while the delivery fee is still being worked out: the total
    // would not be final.
    if (!_canSubmit || _isSubmitting) return;
    final shown = _captureQuote();
    setState(() => _isSubmitting = true);

    // The server accepts the order only at the current price
    // (functions/gas_pricing.js). Read the prices again; if they changed
    // since the customer saw the total, show the new total and go on only
    // with their agreement — never a silently different amount.
    // Without the server's prices nothing is held or ordered: a total built
    // from cached or built-in prices is never charged.
    final refresh = widget.deps.refreshPricing;
    final pricesLoaded = await (refresh != null
        ? refresh()
        : PricingService.instance.fetchFromServer());
    if (!mounted) return;
    if (!pricesLoaded) {
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Couldn't confirm current gas prices. Check your "
            'connection and try again.'),
      ));
      return;
    }
    if (_pricingProblem != null) {
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Gas prices are being updated. Please try again shortly.'),
      ));
      return;
    }
    // Everything below uses this one quote: the payment sheet, the wallet
    // hold and the order document carry the same total.
    final quote = _captureQuote();
    if (quote.total != shown.total) {
      final confirm = widget.deps.confirmPriceChange;
      final agreed = confirm != null
          ? await confirm(context, shown.total, quote.total)
          : await _confirmPriceChange(shown.total, quote.total);
      if (agreed != true || !mounted) {
        if (mounted) setState(() => _isSubmitting = false);
        return;
      }
    }

    if (quote.paymentMethod == 'wallet') {
      final sheet = GasPaymentSheet(
        refillType: quote.type,
        cylinderSize: quote.size,
        brand: quote.brand,
        quantity: quote.quantity,
        gasPrice: quote.pricing.unitPrice,
        deliveryFee: quote.deliveryFee,
        total: quote.total,
        pricing: quote.pricing,
      );
      final confirm = widget.deps.confirmWalletPayment;
      final paymentConfirmed = confirm != null
          ? await confirm(context, sheet)
          : await showModalBottomSheet<bool>(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              isDismissible: !_isSubmitting,
              useSafeArea: true,
              builder: (ctx) => sheet,
            );

      if (paymentConfirmed != true || !mounted) {
        if (mounted) setState(() => _isSubmitting = false);
        return;
      }
    }

    // ── Hold funds before placing gas order (wallet only) ─────────────────
    String? escrowId;
    if (quote.paymentMethod == 'wallet') {
      final hold = widget.deps.holdBalance;
      final escrowResult = hold != null
          ? await hold(quote.total)
          : await EscrowService.instance.holdBalance(
              amount: quote.total,
              serviceType: 'delivery',
              referenceType: 'gas_order',
            );
      if (!escrowResult.success) {
        if (mounted) {
          setState(() => _isSubmitting = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(escrowResult.shortfall != null
                ? 'Need GHS ${escrowResult.shortfall!.toStringAsFixed(2)} more. Top up wallet.'
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
      final uid = widget.deps.currentUserId != null
          ? widget.deps.currentUserId!()
          : (FirebaseAuth.instance.currentUser ??
                  ref.read(authStateProvider).value)
              ?.uid;
      if (uid == null) throw Exception('Please log in to place an order.');

      final order = GasRefillRequest(
        id: '',
        passengerId: uid,
        driverId: null,
        refillType: quote.type,
        cylinderSize: quote.size,
        preferredBrand: quote.brand,
        quantity: quote.quantity,
        status: GasOrderStatus.pendingApproval,
        pickupLocation: quote.location,
        deliveryLocation: quote.location,
        preferredStation: null,
        pickupAddress: quote.address,
        deliveryAddress: quote.address,
        preferredStationAddress: null,
        pickupInstructions: null,
        deliveryInstructions: null,
        cylinderIsAvailable: true,
        cylinderInGoodCondition: true,
        cylinderConditionNotes: null,
        safetyChecklistCompleted: quote.safetyAccepted,
        gasAmount: quote.size.weight * quote.quantity,
        // The unit price of what is ordered (a full cylinder for New
        // cylinder), as the server's verifiedPrice.unitPrice.
        gasPrice: quote.pricing.unitPrice,
        serviceFee: 0,
        deliveryFee: quote.deliveryFee,
        totalPrice: quote.total,
        createdAt: DateTime.now(),
        scheduledPickupAt: null,
        scheduledDeliveryBy: null,
        pickupCompletedAt: null,
        refillCompletedAt: null,
        deliveredAt: null,
        cancelledAt: null,
        paymentMethod: quote.paymentMethod,
        requiresReceipt: false,
        receiptEmail: null,
        passengerRating: null,
        driverRating: null,
        metadata: {
          'appVersion': '1.0.1',
          'platform': 'flutter',
        },
      );

      final repo = ref.read(gasOrderRepositoryProvider);
      final orderId = await repo.createGasOrder(order);

      if (escrowId != null) {
        final attach = widget.deps.attachEscrow;
        if (attach != null) {
          await attach(escrowId, orderId);
        } else {
          await EscrowService.instance.attachToOrder(
            escrowId: escrowId,
            referenceId: orderId,
            referenceType: 'gas_order',
          );
        }
        // Save escrowId to gas order document for CF cancellation refund
        final save = widget.deps.saveOrderEscrowId;
        if (save != null) {
          await save(orderId, escrowId);
        } else {
          await FirebaseFirestore.instance
              .collection('gas_orders')
              .doc(orderId)
              .update({'escrowId': escrowId});
        }
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

  Future<bool?> _confirmPriceChange(double was, double now) =>
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Gas price updated'),
          content: Text(
              'The price changed while you were ordering. The total is now '
              'GHS ${now.toStringAsFixed(2)} (was GHS ${was.toStringAsFixed(2)}).'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Pay GHS ${now.toStringAsFixed(2)}')),
          ],
        ),
      );

  void _showHelp() => Navigator.of(context, rootNavigator: true)
      .pushNamed(AppRoutes.helpSupport);

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
                        fontSize: 12, color: CtsTheme.textSecondary)),
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
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: CtsTheme.charcoal,
                    )),
                const SizedBox(height: 1),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 13, color: CtsTheme.textSecondary)),
              ],
            ),
          ),
        ],
      );
}

/// One gas provider as a compact selectable chip: at least 48dp tall, a
/// check icon (not colour alone) when selected, and a short price badge for
/// providers that cost more.
class _BrandChip extends StatelessWidget {
  final String name;
  final String? badge;
  final bool selected;
  final String semanticLabel;
  final VoidCallback onTap;

  const _BrandChip({
    required this.name,
    required this.badge,
    required this.selected,
    required this.semanticLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => CtsSelectableCard(
        selected: selected,
        semanticLabel: semanticLabel,
        showCheck: false,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            heightFactor: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              // A Wrap, so on narrow screens / large text the badge drops
              // under the name instead of squeezing or clipping it.
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 5,
                runSpacing: 2,
                children: [
                  if (selected)
                    const Icon(Icons.check_rounded,
                        size: 16, color: CtsTheme.primaryDeep),
                  Text(name,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? CtsTheme.primaryDeep
                            : CtsTheme.charcoal,
                      )),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(badge!,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF92400E),
                          )),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
}
