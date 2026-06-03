// lib/features/gas/presentation/screens/gas_order_screen.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../../../core/services/escrow_service.dart';
import '../../../../core/services/pricing_service.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/gas_theme.dart';
import '../../models/gas_refill_request.dart';
import '../../providers/gas_order_providers.dart' hide authStateProvider;
import '../../presentation/widgets/address_picker_sheet.dart';
import '../../presentation/widgets/order_success_screen.dart';
import '../../presentation/widgets/gas_payment_sheet.dart';
import '../../../../features/auth/providers/auth_providers.dart';

class GasOrderScreen extends ConsumerStatefulWidget {
  const GasOrderScreen({super.key});

  @override
  ConsumerState<GasOrderScreen> createState() => _GasOrderScreenState();
}

class _GasOrderScreenState extends ConsumerState<GasOrderScreen>
    with SingleTickerProviderStateMixin {

  GasRefillType  _selectedType  = GasRefillType.exchangeEmpty;
  CylinderSize   _selectedSize  = CylinderSize.kg12_5;
  GasBrand?      _selectedBrand;
  int            _quantity      = 1;
  bool           _safetyAccepted = false;
  bool           _isSubmitting  = false;
  String?        _deliveryAddress;
  GeoPoint?      _deliveryGeoPoint;

  late final AnimationController _animController;
  late final Animation<double>   _fadeAnim;

  double get _deliveryFee => PricingService.instance.gasDeliveryFee;

  double get _basePrice    => _selectedSize.refillPrice * _quantity;
  double get _brandPremium => _selectedBrand != null &&
      _selectedBrand!.priceMultiplier != 1.0
      ? _basePrice * (_selectedBrand!.priceMultiplier - 1)
      : 0;
  double get _total => _basePrice + _brandPremium + _deliveryFee;

  int get _currentStep {
    if (_safetyAccepted)      return 2;
    if (_deliveryAddress != null) return 1;
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(
        parent: _animController, curve: Curves.easeOut);
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: GasTheme.background,
        body: Stack(
          children: [
            CustomScrollView(
              slivers: [
                _buildSliverHeader(),
                SliverToBoxAdapter(
                  child: FadeTransition(
                    opacity: _fadeAnim,
                    child: Column(
                      children: [
                        _buildStepIndicator(),
                        const SizedBox(height: 24),
                        _buildServiceTypeSection(),
                        const SizedBox(height: 24),
                        _buildCylinderSection(),
                        const SizedBox(height: 24),
                        if (_selectedType != GasRefillType.pickupAndReturn)
                          _buildBrandSection(),
                        if (_selectedType == GasRefillType.commercialBulk) ...[
                          const SizedBox(height: 24),
                          _buildQuantitySection(),
                        ],
                        const SizedBox(height: 24),
                        _buildAddressSection(),
                        const SizedBox(height: 24),
                        _buildSafetySection(),
                        const SizedBox(height: 24),
                        _buildPriceSummary(),
                        const SizedBox(height: 140),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            _buildBottomCTA(),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // SLIVER HEADER
  // ─────────────────────────────────────────────

  Widget _buildSliverHeader() => SliverAppBar(
      expandedHeight: 200,
      pinned: true,
      stretch: true,
      backgroundColor: GasTheme.primaryDark,
      leading: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 16),
        ),
      ),
      actions: [
        GestureDetector(
          onTap: _showHelp,
          child: Container(
            margin: const EdgeInsets.all(8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.headset_mic_rounded, color: Colors.white, size: 16),
                SizedBox(width: 4),
                Text('Help',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [StretchMode.zoomBackground],
        background: Container(
          decoration: const BoxDecoration(gradient: GasTheme.heroGradient),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 56, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                // ── FIX: mainAxisSize.min stops overflow ──
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.local_fire_department_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      // ── ETA pill moved to same row as icon ──
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.access_time_rounded,
                                color: Colors.white, size: 12),
                            SizedBox(width: 4),
                            Text('~35 mins',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Order Cooking Gas',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'Fast · Safe · Doorstep Delivery',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

  // ─────────────────────────────────────────────
  // STEP INDICATOR
  // ─────────────────────────────────────────────

  Widget _buildStepIndicator() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: GasTheme.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: GasTheme.cardShadow,
          ),
          child: Row(
            children: [
              _Step(index: 0, current: _currentStep, label: 'Service'),
              _StepConnector(active: _currentStep >= 1),
              _Step(index: 1, current: _currentStep, label: 'Address'),
              _StepConnector(active: _currentStep >= 2),
              _Step(index: 2, current: _currentStep, label: 'Confirm'),
            ],
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // SERVICE TYPE
  // ─────────────────────────────────────────────

  Widget _buildServiceTypeSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Service Type', Icons.category_rounded),
          const SizedBox(height: 12),
          SizedBox(
            height: 120,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: GasRefillType.values.length,
              itemBuilder: (_, i) {
                final type    = GasRefillType.values[i];
                final selected = type == _selectedType;
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _selectedType = type);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 130,
                    margin: const EdgeInsets.only(right: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: selected ? GasTheme.heroGradient : null,
                      color: selected ? null : GasTheme.surface,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: selected
                            ? Colors.transparent
                            : GasTheme.border,
                      ),
                      boxShadow: selected ? GasTheme.emberGlow : GasTheme.cardShadow,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: selected
                                ? Colors.white.withValues(alpha: 0.2)
                                : GasTheme.primaryDim,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(type.icon,
                              size: 18,
                              color: selected
                                  ? Colors.white
                                  : GasTheme.primary),
                        ),
                        const Spacer(),
                        Text(
                          type.displayName,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? Colors.white
                                : GasTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _formatDuration(type.estimatedDuration),
                          style: TextStyle(
                            fontSize: 10,
                            color: selected
                                ? Colors.white70
                                : GasTheme.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );

  // ─────────────────────────────────────────────
  // CYLINDER SIZE
  // ─────────────────────────────────────────────

  Widget _buildCylinderSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Cylinder Size', Icons.propane_tank_rounded),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.5,
              ),
              itemCount: CylinderSize.values.length,
              itemBuilder: (_, i) {
                final size     = CylinderSize.values[i];
                final selected = size == _selectedSize;
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _selectedSize = size);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: selected
                          ? GasTheme.primaryDim
                          : GasTheme.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: selected
                            ? GasTheme.primary
                            : GasTheme.border,
                        width: selected ? 1.5 : 0.5,
                      ),
                      boxShadow: selected ? [] : GasTheme.cardShadow,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          size.displayName,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: selected
                                ? GasTheme.primary
                                : GasTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '₵${size.refillPrice.toStringAsFixed(0)}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: selected
                                ? GasTheme.primaryDark
                                : GasTheme.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );

  // ─────────────────────────────────────────────
  // BRAND
  // ─────────────────────────────────────────────

  Widget _buildBrandSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Preferred Brand', Icons.business_rounded,
              subtitle: 'Optional'),
          const SizedBox(height: 12),
          SizedBox(
            height: 44,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: GasBrand.values.length,
              itemBuilder: (_, i) {
                final brand    = GasBrand.values[i];
                final selected = brand == _selectedBrand;
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() =>
                        _selectedBrand =
                            selected ? null : brand);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected
                          ? GasTheme.primary
                          : GasTheme.surface,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: selected
                            ? GasTheme.primary
                            : GasTheme.border,
                      ),
                      boxShadow:
                          selected ? GasTheme.emberGlow : [],
                    ),
                    child: Text(
                      brand.displayName,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? Colors.white
                            : GasTheme.textSecondary,
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
  // QUANTITY
  // ─────────────────────────────────────────────

  Widget _buildQuantitySection() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: GasTheme.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: GasTheme.cardShadow,
          ),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Quantity',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: GasTheme.textPrimary,
                      )),
                  Text('Number of cylinders',
                      style: TextStyle(
                          fontSize: 12, color: GasTheme.textTertiary)),
                ],
              ),
              const Spacer(),
              _QtyBtn(
                icon: Icons.remove_rounded,
                onTap: () {
                  if (_quantity > 1) {
                    HapticFeedback.selectionClick();
                    setState(() => _quantity--);
                  }
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  '$_quantity',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: GasTheme.textPrimary,
                  ),
                ),
              ),
              _QtyBtn(
                icon: Icons.add_rounded,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _quantity++);
                },
              ),
            ],
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // ADDRESS
  // ─────────────────────────────────────────────

  Widget _buildAddressSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Delivery Address', Icons.location_on_rounded),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GestureDetector(
              onTap: _selectAddress,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: GasTheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _deliveryAddress != null
                        ? GasTheme.primary.withValues(alpha: 0.4)
                        : GasTheme.border,
                    width: _deliveryAddress != null ? 1.5 : 0.5,
                  ),
                  boxShadow: GasTheme.cardShadow,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        gradient: _deliveryAddress != null
                            ? GasTheme.heroGradient
                            : null,
                        color: _deliveryAddress != null
                            ? null
                            : GasTheme.surfaceAlt,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.location_on_rounded,
                        color: _deliveryAddress != null
                            ? Colors.white
                            : GasTheme.textTertiary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _deliveryAddress != null
                                ? 'Delivery Address'
                                : 'Select location',
                            style: TextStyle(
                              fontSize: 11,
                              color: _deliveryAddress != null
                                  ? GasTheme.primary
                                  : GasTheme.textTertiary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _deliveryAddress ??
                                'Tap to set your delivery location',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              fontWeight: _deliveryAddress != null
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: _deliveryAddress != null
                                  ? GasTheme.textPrimary
                                  : GasTheme.textTertiary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _deliveryAddress != null
                          ? Icons.edit_rounded
                          : Icons.chevron_right_rounded,
                      color: _deliveryAddress != null
                          ? GasTheme.primary
                          : GasTheme.textTertiary,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );

  // ─────────────────────────────────────────────
  // SAFETY CHECKLIST
  // ─────────────────────────────────────────────

  Widget _buildSafetySection() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: GasTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _safetyAccepted
                  ? GasTheme.success.withValues(alpha: 0.3)
                  : GasTheme.border,
            ),
            boxShadow: GasTheme.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: GasTheme.success.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.shield_rounded,
                        color: GasTheme.success, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Safety Checklist',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: GasTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SafetyItem(
                  'Valid empty cylinder ready for exchange',
                  'Ensure cylinder is not expired and has valid certification'),
              const SizedBox(height: 10),
              _SafetyItem(
                  'Cylinder in good condition — no leaks or damage',
                  'Check for rust, dents, or damaged valves'),
              const SizedBox(height: 10),
              _SafetyItem(
                  'I understand gas safety guidelines',
                  'Keep upright, away from heat, in ventilated area'),
              Divider(
                  height: 24,
                  color: GasTheme.border),
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _safetyAccepted = !_safetyAccepted);
                },
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: _safetyAccepted
                            ? GasTheme.success
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: _safetyAccepted
                              ? GasTheme.success
                              : GasTheme.textTertiary,
                          width: 1.5,
                        ),
                      ),
                      child: _safetyAccepted
                          ? const Icon(Icons.check_rounded,
                              color: Colors.white, size: 14)
                          : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'I confirm all safety requirements are met',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: GasTheme.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // PRICE SUMMARY
  // ─────────────────────────────────────────────

  Widget _buildPriceSummary() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: GasTheme.cardGradient,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: GasTheme.primary.withValues(alpha: 0.15)),
            boxShadow: GasTheme.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.receipt_long_rounded,
                      color: GasTheme.primary, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Order Summary',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: GasTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _PriceLine(
                label:
                    '${_selectedSize.displayName} × $_quantity',
                value: '₵${_basePrice.toStringAsFixed(2)}',
              ),
              const SizedBox(height: 8),
              _PriceLine(
                  label: 'Delivery fee',
                  value:
                      '₵${_deliveryFee.toStringAsFixed(2)}'),
              if (_brandPremium > 0) ...[
                const SizedBox(height: 8),
                _PriceLine(
                  label:
                      '${_selectedBrand!.displayName} premium',
                  value:
                      '₵${_brandPremium.toStringAsFixed(2)}',
                ),
              ],
              Divider(height: 24, color: GasTheme.border),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Total',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: GasTheme.textPrimary,
                      )),
                  Text(
                    '₵${_total.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: GasTheme.primary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // BOTTOM CTA
  // ─────────────────────────────────────────────

  Widget _buildBottomCTA() => Positioned(
        bottom: 0, left: 0, right: 0,
        child: Container(
          padding: EdgeInsets.fromLTRB(
              20, 16, 20, MediaQuery.of(context).padding.bottom + 16),
          decoration: BoxDecoration(
            color: GasTheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_isOrderValid()) _buildValidationHint(),
              if (!_isOrderValid()) const SizedBox(height: 10),
              GestureDetector(
                onTap: _isSubmitting || !_isOrderValid()
                    ? null
                    : _placeOrder,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    gradient: _isOrderValid() && !_isSubmitting
                        ? GasTheme.heroGradient
                        : null,
                    color: _isOrderValid() && !_isSubmitting
                        ? null
                        : GasTheme.border,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: _isOrderValid() && !_isSubmitting
                        ? GasTheme.emberGlow
                        : [],
                  ),
                  child: Center(
                    child: _isSubmitting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                  Icons.local_fire_department_rounded,
                                  color: Colors.white,
                                  size: 18),
                              const SizedBox(width: 8),
                              Text(
                                'Place Order  ₵${_total.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
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

  Widget _buildValidationHint() {
    final hints = <String>[];
    if (_deliveryAddress == null) hints.add('Select a delivery address');
    if (!_safetyAccepted) hints.add('Accept the safety checklist');
    if (hints.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: GasTheme.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: GasTheme.warning.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded,
              color: GasTheme.warning, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hints.join(' · '),
              style: TextStyle(
                fontSize: 12,
                color: GasTheme.warning,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────

  Widget _sectionTitle(String title, IconData icon,
      {String? subtitle}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: GasTheme.primaryDim,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: GasTheme.primary, size: 16),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: GasTheme.textPrimary,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: GasTheme.surfaceAlt,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(subtitle,
                    style: TextStyle(
                        fontSize: 10,
                        color: GasTheme.textTertiary,
                        fontWeight: FontWeight.w500)),
              ),
            ],
          ],
        ),
      );

  bool _isOrderValid() =>
      _deliveryAddress != null &&
      _deliveryGeoPoint != null &&
      _safetyAccepted;

  Future<void> _selectAddress() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AddressPickerSheet(),
    );
    if (result != null && mounted) {
      setState(() {
        _deliveryAddress  = result['address'] as String;
        _deliveryGeoPoint = result['location'] as GeoPoint;
      });
    }
  }

  Future<void> _placeOrder() async {
    if (!_isOrderValid()) return;

    final paymentConfirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: !_isSubmitting,
      useSafeArea: true,
      builder: (ctx) => GasPaymentSheet(
        refillType:   _selectedType,
        cylinderSize: _selectedSize,
        brand:        _selectedBrand,
        quantity:     _quantity,
        gasPrice:     _selectedSize.refillPrice,
        deliveryFee:  _deliveryFee,
        total:        _total,
      ),
    );

    if (paymentConfirmed != true || !mounted) return;

    // ── Hold funds before placing gas order ──────────────────────────────
    final escrowResult = await EscrowService.instance.holdBalance(
      amount:        _total,
      serviceType:   'gas',
      referenceType: 'gas_order',
    );
    if (!escrowResult.success) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(escrowResult.shortfall != null
            ? 'Need GH₵${escrowResult.shortfall!.toStringAsFixed(2)} more. Top up wallet.'
            : escrowResult.error ?? 'Payment hold failed.'),
          backgroundColor: const Color(0xFFDC2626),
          action: SnackBarAction(
            label: 'Top Up',
            onPressed: () => Navigator.pushNamed(context, '/wallet'),
          ),
        ));
      }
      return;
    }
    final escrowId = escrowResult.escrowId!;

    setState(() => _isSubmitting = true);

    try {
      final user = FirebaseAuth.instance.currentUser
          ?? ref.read(authStateProvider).value;
      if (user == null) throw Exception('Please log in to place an order.');

      final order = GasRefillRequest(
        id:                      '',
        passengerId:             user.uid,
        driverId:                null,
        refillType:              _selectedType,
        cylinderSize:            _selectedSize,
        preferredBrand:          _selectedBrand,
        quantity:                _quantity,
        status:                  GasOrderStatus.pendingApproval,
        pickupLocation:          _deliveryGeoPoint!,
        deliveryLocation:        _deliveryGeoPoint!,
        preferredStation:        null,
        pickupAddress:           _deliveryAddress!,
        deliveryAddress:         _deliveryAddress!,
        preferredStationAddress: null,
        pickupInstructions:      null,
        deliveryInstructions:    null,
        cylinderIsAvailable:     true,
        cylinderInGoodCondition: true,
        cylinderConditionNotes:  null,
        safetyChecklistCompleted: _safetyAccepted,
        gasAmount:      _selectedSize.weight * _quantity,
        gasPrice:       _selectedSize.refillPrice,
        serviceFee:     0,
        deliveryFee:    _deliveryFee,
        totalPrice:     _total,
        createdAt:      DateTime.now(),
        scheduledPickupAt:   null,
        scheduledDeliveryBy: null,
        pickupCompletedAt:   null,
        refillCompletedAt:   null,
        deliveredAt:         null,
        cancelledAt:         null,
        paymentMethod:   'wallet',
        requiresReceipt: false,
        receiptEmail:    null,
        passengerRating: null,
        driverRating:    null,
        metadata: {
          'appVersion': '1.0.0',
          'platform':   'flutter',
        },
      );

      final repo    = ref.read(gasOrderRepositoryProvider);
      final orderId = await repo.createGasOrder(order);

      await EscrowService.instance.attachToOrder(
        escrowId:      escrowId,
        referenceId:   orderId,
        referenceType: 'gas_order',
      );

      // Save escrowId to gas order document for CF cancellation refund
      await FirebaseFirestore.instance
          .collection('gas_orders')
          .doc(orderId)
          .update({'escrowId': escrowId});

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
              builder: (_) => OrderSuccessScreen(orderId: orderId)),
        );
      }
    } catch (e) {
      // Rollback escrow if order creation failed
      try {
        final fns = FirebaseFunctions.instanceFor(region: 'europe-west2');
        await fns.httpsCallable('refundEscrowOnError').call({
          'escrowId': escrowId,
          'reason':   'order_creation_failed',
        });
      } catch (_) { /* Stuck escrow auto-releases after 2hrs */ }

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
                width: 40, height: 4,
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
            _HelpRow(Icons.phone_rounded,       '+233 XX XXX XXXX'),
            const SizedBox(height: 12),
            _HelpRow(Icons.email_rounded,       'support@ctstransport.com'),
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

class _Step extends StatelessWidget {
  final int index, current;
  final String label;
  const _Step({required this.index, required this.current, required this.label});

  @override
  Widget build(BuildContext context) {
    final done   = current > index;
    final active = current >= index;
    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: active ? GasTheme.primary : GasTheme.surfaceAlt,
            shape: BoxShape.circle,
            border: Border.all(
              color: active ? GasTheme.primary : GasTheme.border,
            ),
          ),
          child: Center(
            child: done
                ? const Icon(Icons.check_rounded,
                    color: Colors.white, size: 16)
                : Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: active
                          ? Colors.white
                          : GasTheme.textTertiary,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(
              fontSize: 11,
              fontWeight:
                  active ? FontWeight.w600 : FontWeight.w400,
              color: active
                  ? GasTheme.primary
                  : GasTheme.textTertiary,
            )),
      ],
    );
  }
}

class _StepConnector extends StatelessWidget {
  final bool active;
  const _StepConnector({required this.active});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Padding(
          padding:
              const EdgeInsets.only(bottom: 18, left: 4, right: 4),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            height: 2,
            color: active ? GasTheme.primary : GasTheme.border,
          ),
        ),
      );
}

class _QtyBtn extends StatelessWidget {
  final IconData     icon;
  final VoidCallback onTap;
  const _QtyBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: GasTheme.primaryDim,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: GasTheme.primary.withValues(alpha: 0.3)),
          ),
          child: Icon(icon, color: GasTheme.primary, size: 18),
        ),
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
            width: 20, height: 20,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: GasTheme.success.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.check_rounded,
                color: GasTheme.success, size: 12),
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
                    style: TextStyle(
                        fontSize: 11,
                        color: GasTheme.textTertiary)),
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
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13, color: GasTheme.textSecondary)),
          Text(value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: GasTheme.textPrimary,
              )),
        ],
      );
}

class _HelpRow extends StatelessWidget {
  final IconData icon;
  final String   text;
  const _HelpRow(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 36, height: 36,
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