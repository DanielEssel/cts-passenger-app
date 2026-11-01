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
import '../../../../core/widgets/cts_photo_header.dart';
import '../../../../core/widgets/cts_ui.dart';
import '../../theme/gas_theme.dart';
import '../../models/gas_refill_request.dart';
import '../../providers/gas_order_providers.dart' hide authStateProvider;
import '../../presentation/widgets/address_picker_sheet.dart';
import 'gas_order_tracking_screen.dart';
import '../../presentation/widgets/gas_payment_sheet.dart';
import '../../presentation/widgets/gas_booking_widgets.dart';
import '../../../../features/auth/providers/auth_providers.dart';
import 'dart:math' as math;
import '../../../../core/utils/cedi_format.dart';

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
  // Two areas: a compact service header with the gas photo and progress
  // that never scrolls, and under it the stepped sections, scrolling on
  // their own: service → cylinder (and provider) → address → safety →
  // payment, the price panel. A pinned "Place gas order" bar sits below.
  // Only fields relevant to the chosen service are shown. Sections live in a
  // lazily built SliverList and render at full opacity with the page
  // transition (no fade-in: it cost ~500 ms frames).
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
      GasSection(
        step: 5,
        icon: Icons.account_balance_wallet_rounded,
        title: 'Payment',
        caption: 'How you will pay for this order',
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
            CtsPhotoHeader(
              image: 'assets/images/services/gas.jpeg',
              imageAspectRatio: 1,
              // The cylinder stands a little right of the photo's centre.
              imageAlignment: const Alignment(0.1, 0),
              eyebrow: 'Cooking gas · LPG',
              title: 'Gas to your door',
              subtitle: 'Exchange, refill or buy a cylinder, brought to you.',
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
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding:
                        const EdgeInsets.fromLTRB(ctsGutter, 20, ctsGutter, 0),
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
                    _priceKnown ? formatCedis(_total) : null,
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

  static const Widget _gap = SizedBox(height: 18);

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
    final onDark = selected;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: '${type.displayName}. ${_typeDescription(type)}. '
          'About ${_formatDuration(type.estimatedDuration)}',
      excludeSemantics: true,
      onTap: () => _selectType(type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          gradient: selected ? GasPalette.selectedGradient : null,
          color: selected ? null : GasPalette.idleFill,
          borderRadius: BorderRadius.circular(20),
          boxShadow: selected ? GasPalette.selectedGlow : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _selectType(type),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: onDark
                          ? Colors.white.withValues(alpha: 0.14)
                          : CtsTheme.surface,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(type.icon,
                        size: 23,
                        color: onDark ? GasPalette.mint : GasPalette.greenDeep),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(type.displayName,
                            style: CtsText.cardTitle.copyWith(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color:
                                  onDark ? Colors.white : CtsTheme.textPrimary,
                            )),
                        const SizedBox(height: 2),
                        Text(_typeDescription(type),
                            style: CtsText.bodySmall.copyWith(
                              fontSize: 13.5,
                              height: 1.3,
                              color: onDark
                                  ? GasPalette.mint
                                  : CtsTheme.textSecondary,
                            )),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: onDark
                                ? Colors.white.withValues(alpha: 0.14)
                                : GasPalette.mint,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.schedule_rounded,
                                  size: 13,
                                  color: onDark
                                      ? Colors.white
                                      : GasPalette.greenDeep),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                    'About ${_formatDuration(type.estimatedDuration)}',
                                    style: CtsText.caption.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: onDark
                                          ? Colors.white
                                          : GasPalette.greenDeep,
                                    )),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  GasCheckBadge(selected: selected, onDark: onDark),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _selectType(GasRefillType type) {
    HapticFeedback.selectionClick();
    setState(() => _selectedType = type);
  }

  Widget _buildServiceTypeSection() => GasSection(
        step: 1,
        icon: Icons.local_fire_department_rounded,
        title: 'Service',
        caption: 'How would you like your gas?',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const GasGroupLabel('Delivered to you'),
            for (final type in const [
              GasRefillType.exchangeEmpty,
              GasRefillType.newCylinder,
              GasRefillType.commercialBulk,
            ]) ...[
              _typeCard(type),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 8),
            const GasGroupLabel('Refill my own cylinder'),
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

  // The tank icon grows with the cylinder, so sizes read at a glance.
  static double _tankIconSize(CylinderSize s) =>
      16 + 14 * (math.min(s.weight, 19) - 3) / 16;

  Widget _sizeTile(CylinderSize size) {
    final selected = size == _selectedSize;
    return GasOptionSurface(
      selected: selected,
      semanticLabel:
          '${size.displayName}, ${formatCedis(_unitPriceFor(size), decimals: 0)}',
      padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selectedSize = size);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Icon(Icons.propane_tank_rounded,
                      size: _tankIconSize(size),
                      color: selected
                          ? GasPalette.greenDeep
                          : CtsTheme.textTertiary),
                ),
              ),
              const Spacer(),
              if (selected)
                const Icon(Icons.check_circle_rounded,
                    size: 18, color: GasPalette.green),
            ],
          ),
          const SizedBox(height: 8),
          Text(size.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CtsText.cardTitle.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: CtsTheme.textPrimary,
              )),
          const SizedBox(height: 1),
          Text(formatCedis(_unitPriceFor(size), decimals: 0),
              maxLines: 1,
              style: CtsText.price.copyWith(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: GasPalette.greenDeep,
              )),
        ],
      ),
    );
  }

  Widget _buildCylinderSection() => GasSection(
        step: 2,
        icon: Icons.propane_tank_rounded,
        title: 'Cylinder',
        caption: 'Choose a size for your cylinder',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GasGroupLabel('Cylinder size',
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
                    SizedBox(width: w, child: _sizeTile(size)),
                ],
              );
            }),
            if (_selectedType == GasRefillType.commercialBulk) ...[
              const SizedBox(height: 16),
              _buildQuantitySection(),
            ],
            // Pickup & Return refills the customer's own cylinder, so no
            // provider is chosen.
            if (!_isRoundTrip) ...[
              const SizedBox(height: 20),
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
          GasGroupLabel('Gas provider',
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
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        decoration: BoxDecoration(
          color: GasPalette.mint,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quantity',
                      style: CtsText.cardTitle.copyWith(
                        fontWeight: FontWeight.w800,
                        color: GasPalette.forest,
                      )),
                  Text('Number of cylinders',
                      style: CtsText.caption
                          .copyWith(color: CtsTheme.textSecondary)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: CtsTheme.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: CtsTheme.cardShadow,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                    width: 40,
                    child: Text('$_quantity',
                        textAlign: TextAlign.center,
                        style: CtsText.price.copyWith(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: CtsTheme.textPrimary,
                        )),
                  ),
                  _QtyBtn(
                    icon: Icons.add_rounded,
                    label: 'More cylinders',
                    // The server prices at most GasPricing.maxQuantity
                    // cylinders.
                    onTap: _quantity < GasPricing.maxQuantity
                        ? () {
                            HapticFeedback.selectionClick();
                            setState(() => _quantity++);
                          }
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  // ─────────────────────────────────────────────
  // ADDRESS
  // ─────────────────────────────────────────────

  Widget _buildAddressSection() {
    final hasAddress = _deliveryAddress != null;
    return GasSection(
      step: 3,
      icon: _isRoundTrip ? Icons.sync_rounded : Icons.location_on_rounded,
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
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: hasAddress ? CtsTheme.primaryTint : GasPalette.idleFill,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: hasAddress ? GasPalette.green : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Material(
                type: MaterialType.transparency,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _selectAddress,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: hasAddress
                                ? GasPalette.green
                                : CtsTheme.surface,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                              hasAddress
                                  ? Icons.location_on_rounded
                                  : Icons.add_location_alt_rounded,
                              size: 22,
                              color: hasAddress
                                  ? Colors.white
                                  : GasPalette.greenDeep),
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
                                style: CtsText.caption.copyWith(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: GasPalette.greenDeep,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _deliveryAddress ?? 'Tap to set your location',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: CtsText.cardTitle.copyWith(
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
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: hasAddress
                                ? CtsTheme.surface
                                : GasPalette.greenDeep,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(hasAddress ? 'Change' : 'Set',
                              style: CtsText.label.copyWith(
                                fontWeight: FontWeight.w800,
                                color: hasAddress
                                    ? GasPalette.greenDeep
                                    : Colors.white,
                              )),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Estimates only once an address is set and measured.
          if (_deliveryGeoPoint != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _InfoPair(
                    icon: Icons.access_time_rounded,
                    label: 'Est. delivery',
                    value: _etaText,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _InfoPair(
                    icon: Icons.local_shipping_rounded,
                    label: _pricing.deliveryLabel,
                    value: formatCedis(_deliveryFee),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // SAFETY CHECKLIST
  // ─────────────────────────────────────────────

  Widget _buildSafetySection() => GasSection(
        step: 4,
        icon: Icons.health_and_safety_rounded,
        title: 'Safety check',
        caption: 'Please confirm before we send a driver',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A new cylinder needs no empty one; the others hand over
            // the customer's own cylinder.
            if (_selectedType != GasRefillType.newCylinder) ...[
              _SafetyItem(
                  Icons.verified_rounded,
                  _isRoundTrip
                      ? 'Your cylinder is ready for collection'
                      : 'Valid empty cylinder ready for exchange',
                  'Ensure cylinder is not expired and has valid certification'),
              const SizedBox(height: 12),
              const _SafetyItem(
                  Icons.build_circle_rounded,
                  'Cylinder in good condition — no leaks or damage',
                  'Check for rust, dents, or damaged valves'),
              const SizedBox(height: 12),
            ],
            const _SafetyItem(
                Icons.local_fire_department_rounded,
                'I understand gas safety guidelines',
                'Keep upright, away from heat, in ventilated area'),
            const SizedBox(height: 16),
            Semantics(
              checked: _safetyAccepted,
              label: 'I confirm all safety requirements are met',
              excludeSemantics: true,
              onTap: _toggleSafety,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  gradient:
                      _safetyAccepted ? GasPalette.selectedGradient : null,
                  color: _safetyAccepted ? null : GasPalette.idleFill,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: _safetyAccepted ? GasPalette.selectedGlow : null,
                ),
                child: Material(
                  type: MaterialType.transparency,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _toggleSafety,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 56),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: Row(
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: _safetyAccepted
                                    ? GasPalette.mint
                                    : CtsTheme.surface,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: _safetyAccepted
                                      ? GasPalette.mint
                                      : CtsTheme.textDisabled,
                                  width: 1.5,
                                ),
                              ),
                              child: _safetyAccepted
                                  ? const Icon(Icons.check_rounded,
                                      color: GasPalette.forest, size: 16)
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'I confirm all safety requirements are met',
                                style: CtsText.cardTitle.copyWith(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: _safetyAccepted
                                      ? Colors.white
                                      : CtsTheme.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  // ─────────────────────────────────────────────
  // PRICE SUMMARY — every figure comes from GasPricing (_pricing)
  // ─────────────────────────────────────────────

  Widget _buildPriceSummary() => CtsPriceSummary(
        lines: [
          CtsPriceLine(
            '${_pricing.unitLabel} · ${_selectedSize.displayName} × $_quantity',
            formatCedis(_basePrice),
          ),
          if (_brandPremium > 0)
            CtsPriceLine('${_selectedBrand!.displayName} premium',
                formatCedis(_brandPremium)),
          CtsPriceLine(
            _pricing.deliveryLabel,
            _priceKnown
                ? formatCedis(_deliveryFee)
                : 'After address',
          ),
        ],
        totalLabel: 'Total',
        total: _priceKnown ? formatCedis(_total) : null,
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
        .where('serviceType', whereIn: const ['delivery', 'gas']).get();

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
        child: GasOptionSurface(
          selected: selected,
          semanticLabel: '$label, $sub',
          padding: const EdgeInsets.all(12),
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _paymentMethod = value);
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: selected ? GasPalette.green : CtsTheme.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon,
                        size: 19,
                        color: selected ? Colors.white : GasPalette.greenDeep),
                  ),
                  const Spacer(),
                  GasCheckBadge(selected: selected),
                ],
              ),
              const SizedBox(height: 10),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CtsText.cardTitle.copyWith(
                    fontWeight: FontWeight.w800,
                    color: CtsTheme.textPrimary,
                  )),
              Text(sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style:
                      CtsText.caption.copyWith(color: CtsTheme.textSecondary)),
            ],
          ),
        ),
      );
    }

    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        option('wallet', Icons.account_balance_wallet_rounded, 'Wallet',
            'Pay from balance'),
        const SizedBox(width: 10),
        option('cash', Icons.payments_rounded, 'Cash', 'Pay driver directly'),
      ]),
    );
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
        content:
            Text('Gas prices are being updated. Please try again shortly.'),
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
                ? 'Need ${formatCedis(escrowResult.shortfall!)} more. Top up wallet.'
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

  Future<bool?> _confirmPriceChange(double was, double now) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Gas price updated'),
          content: Text(
              'The price changed while you were ordering. The total is now '
              '${formatCedis(now)} (was ${formatCedis(was)}).'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Pay ${formatCedis(now)}')),
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
          color: onTap != null ? GasPalette.green : CtsTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon,
                  size: 20,
                  color: onTap != null ? Colors.white : CtsTheme.textDisabled),
            ),
          ),
        ),
      );
}

/// A small estimate tile under the address: icon, label, value.
class _InfoPair extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _InfoPair(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: GasPalette.idleFill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: GasPalette.mint,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: GasPalette.greenDeep, size: 17),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CtsText.caption
                          .copyWith(color: CtsTheme.textSecondary)),
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CtsText.label.copyWith(
                        fontWeight: FontWeight.w800,
                        color: CtsTheme.textPrimary,
                      )),
                ],
              ),
            ),
          ],
        ),
      );
}

class _SafetyItem extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  const _SafetyItem(this.icon, this.title, this.subtitle);

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: GasPalette.mint,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: GasPalette.greenDeep, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: CtsText.label.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: CtsTheme.textPrimary,
                    )),
                const SizedBox(height: 2),
                Text(subtitle, style: CtsText.bodySmall.copyWith(fontSize: 13)),
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
                        color:
                            selected ? CtsTheme.primaryDeep : CtsTheme.charcoal,
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
