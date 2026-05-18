// lib/features/gas/presentation/screens/gas_order_screen.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cts_transport_app/core/theme/app_theme.dart';
import 'package:cts_transport_app/widgets/common/glass_card.dart';
import 'package:cts_transport_app/widgets/buttons/cta_button.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/gas/providers/gas_order_providers.dart';
import 'package:cts_transport_app/features/gas/widgets/address_picker_sheet.dart';
import 'package:cts_transport_app/features/gas/widgets/order_success_screen.dart';
import 'package:cts_transport_app/features/gas/widgets/gas_payment_sheet.dart'; // ← ADD THIS
//                                                                   ^^^^^^^ wrong folder

class GasOrderScreen extends ConsumerStatefulWidget {
  const GasOrderScreen({super.key});

  @override
  ConsumerState<GasOrderScreen> createState() => GasOrderScreenState();
}

class GasOrderScreenState extends ConsumerState<GasOrderScreen> {
  // ── Form state ──
  GasRefillType _selectedType = GasRefillType.exchangeEmpty;
  CylinderSize _selectedSize = CylinderSize.kg12_5;
  GasBrand? _selectedBrand;
  int _quantity = 1;
  bool _safetyChecklistAccepted = false;
  bool _isSubmitting = false;

  // ── Address state ──
  String? _deliveryAddress;
  GeoPoint? _deliveryGeoPoint;

  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // Price calculation
  // ─────────────────────────────────────────────

  static const double _deliveryFee = 30.0;

  double get _basePrice => _selectedSize.refillPrice * _quantity;

  double get _brandPremium =>
      _selectedBrand != null && _selectedBrand!.priceMultiplier != 1.0
          ? _basePrice * (_selectedBrand!.priceMultiplier - 1)
          : 0;

  double get _total => _basePrice + _brandPremium + _deliveryFee;

  // ─────────────────────────────────────────────
  // Step indicator logic
  // ─────────────────────────────────────────────

  int get _currentStep {
    if (_safetyChecklistAccepted) return 2;
    if (_deliveryAddress != null) return 1;
    return 0;
  }

  // ─────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          _buildHeroHeader(),
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.of(context).size.height * 0.28,
                ),
              ),
              SliverToBoxAdapter(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.background,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(32)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        _buildStepIndicator(),
                        const SizedBox(height: 32),
                        _buildSectionLabel('Service Type'),
                        const SizedBox(height: 12),
                        _buildOrderTypeSelector(),
                        const SizedBox(height: 32),
                        _buildCylinderSizeSelector(),
                        const SizedBox(height: 32),
                        if (_selectedType != GasRefillType.pickupAndReturn) ...[
                          _buildGasBrandSelector(),
                          const SizedBox(height: 32),
                        ],
                        if (_selectedType == GasRefillType.commercialBulk) ...[
                          _buildQuantitySelector(),
                          const SizedBox(height: 32),
                        ],
                        _buildAddressSection(),
                        const SizedBox(height: 32),
                        _buildSafetyChecklist(),
                        const SizedBox(height: 32),
                        _buildPriceBreakdown(),
                        const SizedBox(height: 120),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  // ─────────────────────────────────────────────
  // Hero header
  // ─────────────────────────────────────────────

  Widget _buildHeroHeader() => Container(
        height: MediaQuery.of(context).size.height * 0.32,
        decoration: BoxDecoration(gradient: AppTheme.primaryGradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _showHelpDialog,
                      icon: const Icon(Icons.support_agent,
                          color: Colors.white, size: 20),
                      label: const Text('Help',
                          style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Order Cooking Gas',
                  style: AppTheme.headlineMedium.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Fast • Safe • Doorstep Delivery',
                  style: AppTheme.bodyMedium
                      .copyWith(color: Colors.white.withValues(alpha: 0.85)),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.local_fire_department,
                          color: Colors.white, size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Average delivery: 35 mins',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // Step indicator
  // ─────────────────────────────────────────────

  Widget _buildStepIndicator() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: GlassCard(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _StepItem(step: 0, currentStep: _currentStep, label: 'Service'),
              _StepLine(isActive: _currentStep >= 1),
              _StepItem(step: 1, currentStep: _currentStep, label: 'Address'),
              _StepLine(isActive: _currentStep >= 2),
              _StepItem(step: 2, currentStep: _currentStep, label: 'Confirm'),
            ],
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // Section label helper
  // ─────────────────────────────────────────────

  Widget _buildSectionLabel(String label) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(
          label,
          style: AppTheme.titleMedium.copyWith(fontWeight: FontWeight.bold),
        ),
      );

  // ─────────────────────────────────────────────
  // Order type selector
  // ─────────────────────────────────────────────

  Widget _buildOrderTypeSelector() {
    final types = GasRefillType.values;
    return SizedBox(
      height: 130,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: types.length,
        itemBuilder: (_, i) {
          final type = types[i];
          final selected = type == _selectedType;
          return GestureDetector(
            onTap: () => setState(() => _selectedType = type),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 140,
              margin: const EdgeInsets.only(right: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: selected ? AppTheme.primaryGradient : null,
                color: selected ? null : AppTheme.surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: selected ? Colors.transparent : Colors.grey[800]!,
                  width: 1,
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: AppTheme.primaryColor.withValues(alpha: 0.4),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        )
                      ]
                    : [],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(type.icon,
                      size: 32,
                      color: selected ? Colors.white : AppTheme.primaryColor),
                  const SizedBox(height: 12),
                  Text(
                    type.displayName,
                    textAlign: TextAlign.center,
                    style: AppTheme.labelMedium.copyWith(
                      color: selected ? Colors.white : Colors.grey[300],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatDuration(type.estimatedDuration),
                    style: AppTheme.labelSmall.copyWith(
                      color: selected ? Colors.white70 : Colors.grey[500],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Cylinder & brand chip selectors
  // ─────────────────────────────────────────────

  Widget _buildCylinderSizeSelector() => _chipSelector(
        'Cylinder Size',
        CylinderSize.values
            .map(
                (e) => '${e.displayName}  ₵${e.refillPrice.toStringAsFixed(0)}')
            .toList(),
        (i) => setState(() => _selectedSize = CylinderSize.values[i]),
        CylinderSize.values.indexOf(_selectedSize),
      );

  Widget _buildGasBrandSelector() => _chipSelector(
        'Gas Brand (Optional)',
        GasBrand.values.map((e) => e.displayName).toList(),
        (i) => setState(() {
          final tapped = GasBrand.values[i];
          // Toggle off if already selected
          _selectedBrand = _selectedBrand == tapped ? null : tapped;
        }),
        _selectedBrand == null ? -1 : GasBrand.values.indexOf(_selectedBrand!),
      );

  Widget _chipSelector(
    String title,
    List<String> items,
    Function(int) onTap,
    int selected,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel(title),
        const SizedBox(height: 12),
        SizedBox(
          height: 50,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final isSelected = i == selected;
              return GestureDetector(
                onTap: () => onTap(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.only(right: 12),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    gradient: isSelected ? AppTheme.primaryGradient : null,
                    color: isSelected ? null : AppTheme.surface,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color:
                          isSelected ? Colors.transparent : Colors.grey[800]!,
                      width: 1,
                    ),
                  ),
                  child: Text(
                    items[i],
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.grey[300],
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────
  // Quantity selector (commercial bulk only)
  // ─────────────────────────────────────────────

  Widget _buildQuantitySelector() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: GlassCard(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Quantity (cylinders)',
                style:
                    AppTheme.titleMedium.copyWith(fontWeight: FontWeight.bold),
              ),
              Row(
                children: [
                  _QtyButton(
                    icon: Icons.remove,
                    onTap: () {
                      if (_quantity > 1) setState(() => _quantity--);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      '$_quantity',
                      style: AppTheme.titleLarge
                          .copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  _QtyButton(
                    icon: Icons.add,
                    onTap: () => setState(() => _quantity++),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // Address section
  // ─────────────────────────────────────────────

  Widget _buildAddressSection() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionLabel('Delivery Address'),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _selectAddress,
              child: GlassCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: const BoxDecoration(
                        gradient: AppTheme.primaryGradient,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.location_on,
                          color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _deliveryAddress == null
                                ? 'Select delivery address'
                                : 'Delivery Address',
                            style: AppTheme.labelSmall
                                .copyWith(color: Colors.grey),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _deliveryAddress ??
                                'Tap to select your delivery location',
                            style: AppTheme.bodyMedium.copyWith(
                              color: _deliveryAddress == null
                                  ? Colors.grey
                                  : Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _deliveryAddress != null
                          ? Icons.edit_rounded
                          : Icons.chevron_right,
                      color: Colors.grey,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  // ─────────────────────────────────────────────
  // Safety checklist
  // ─────────────────────────────────────────────

  Widget _buildSafetyChecklist() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Safety Checklist',
                style:
                    AppTheme.titleMedium.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _ChecklistItem(
                'Valid empty cylinder ready for exchange',
                'Ensure your cylinder is not expired and has valid certification',
              ),
              const SizedBox(height: 12),
              _ChecklistItem(
                'Cylinder in good condition — no leaks or damage',
                'Check for rust, dents, or damaged valves',
              ),
              const SizedBox(height: 12),
              _ChecklistItem(
                'I understand gas safety guidelines',
                'Keep cylinder upright, away from heat, in ventilated area',
              ),
              const Divider(height: 24, color: Colors.grey),
              Theme(
                data: Theme.of(context).copyWith(
                  unselectedWidgetColor: Colors.grey,
                ),
                child: CheckboxListTile(
                  value: _safetyChecklistAccepted,
                  onChanged: (v) =>
                      setState(() => _safetyChecklistAccepted = v ?? false),
                  title: Text(
                    'I confirm all safety requirements are met',
                    style: AppTheme.bodyMedium
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: AppTheme.primaryColor,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // Price breakdown
  // ─────────────────────────────────────────────

  Widget _buildPriceBreakdown() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: GlassCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              _PriceRow(
                label: 'Gas Price (${_selectedSize.displayName} × $_quantity)',
                amount: _basePrice,
              ),
              const SizedBox(height: 12),
              _PriceRow(label: 'Delivery Fee', amount: _deliveryFee),
              if (_brandPremium > 0) ...[
                const SizedBox(height: 12),
                _PriceRow(
                  label: 'Brand Premium (${_selectedBrand!.displayName})',
                  amount: _brandPremium,
                ),
              ],
              const Divider(height: 24, color: Colors.grey),
              _PriceRow(label: 'Total', amount: _total, isTotal: true),
            ],
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // Bottom bar + Place Order button
  // ─────────────────────────────────────────────

  Widget _buildBottomBar() => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, AppTheme.surface],
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Validation hints
              if (!_isOrderValid()) _buildValidationHint(),
              const SizedBox(height: 12),
              CTAButton(
                onTap: _isSubmitting ? null : _placeOrder,
                text: _isSubmitting
                    ? 'Placing Order...'
                    : 'Place Order  ₵${_total.toStringAsFixed(2)}',
                isEnabled: _isOrderValid() && !_isSubmitting,
              ),
            ],
          ),
        ),
      );

  Widget _buildValidationHint() {
    final hints = <String>[];
    if (_deliveryAddress == null) hints.add('• Select a delivery address');
    if (!_safetyChecklistAccepted) hints.add('• Accept the safety checklist');

    if (hints.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: hints
            .map((h) => Text(
                  h,
                  style: AppTheme.labelSmall.copyWith(color: Colors.orange),
                ))
            .toList(),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Logic helpers
  // ─────────────────────────────────────────────

  bool _isOrderValid() =>
      _deliveryAddress != null &&
      _deliveryGeoPoint != null &&
      _safetyChecklistAccepted;

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
    }
  }

 Future<void> _placeOrder() async {
  if (!_isOrderValid()) return;
 
 // ── Step 1: Show payment confirmation sheet ──
final paymentConfirmed = await showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  isDismissible: !_isSubmitting,
  useSafeArea: true,
  builder: (BuildContext ctx) {
    return GasPaymentSheet (
      refillType: _selectedType,
      cylinderSize: _selectedSize,
      brand: _selectedBrand,
      quantity: _quantity,
      gasPrice: _selectedSize.refillPrice,
      deliveryFee: _deliveryFee,
      total: _total,
    );
  },
);
 
  // User cancelled the sheet
  if (paymentConfirmed != true) return;
  if (!mounted) return;
 
  // ── Step 2: Payment succeeded → create the order ──
  setState(() => _isSubmitting = true);
 
  try {
    final user = FirebaseAuth.instance.currentUser
        ?? ref.read(authStateProvider).value;
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
      safetyChecklistCompleted: _safetyChecklistAccepted,
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
      paymentMethod: 'wallet',   // ← wallet payment
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
 
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => OrderSuccessScreen(orderId: orderId),
        ),
      );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        backgroundColor: Colors.red,
      ));
    }
  } finally {
    if (mounted) setState(() => _isSubmitting = false);
  }
}

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text('Need Help?', style: AppTheme.titleLarge),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HelpItem(
                icon: Icons.phone_rounded, text: 'Call: +233 XX XXX XXXX'),
            const SizedBox(height: 12),
            _HelpItem(
                icon: Icons.email_rounded, text: 'support@ctstransport.com'),
            const SizedBox(height: 12),
            _HelpItem(icon: Icons.access_time_rounded, text: '24/7 Support'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                Text('Close', style: TextStyle(color: AppTheme.primaryColor)),
          ),
        ],
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
// Private sub-widgets (same file for locality)
// ─────────────────────────────────────────────

class _StepItem extends StatelessWidget {
  final int step;
  final int currentStep;
  final String label;

  const _StepItem({
    required this.step,
    required this.currentStep,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final isCompleted = currentStep > step;
    final isActive = currentStep >= step;

    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            gradient: isActive ? AppTheme.primaryGradient : null,
            color: isActive ? null : Colors.grey[800],
            shape: BoxShape.circle,
          ),
          child: Center(
            child: isCompleted
                ? const Icon(Icons.check, size: 18, color: Colors.white)
                : Text(
                    '${step + 1}',
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: AppTheme.labelSmall.copyWith(
            color: isActive ? AppTheme.primaryColor : Colors.grey,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}

class _StepLine extends StatelessWidget {
  final bool isActive;

  const _StepLine({required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 2,
        color: isActive ? AppTheme.primaryColor : Colors.grey[800],
      ),
    );
  }
}

class _QtyButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _QtyButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(50),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: const BoxDecoration(
          gradient: AppTheme.primaryGradient,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}

class _ChecklistItem extends StatelessWidget {
  final String title;
  final String subtitle;

  const _ChecklistItem(this.title, this.subtitle);

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle_outline, color: Colors.green, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTheme.bodyMedium),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: AppTheme.labelSmall.copyWith(color: Colors.grey)),
            ],
          ),
        ),
      ],
    );
  }
}

class _PriceRow extends StatelessWidget {
  final String label;
  final double amount;
  final bool isTotal;

  const _PriceRow({
    required this.label,
    required this.amount,
    this.isTotal = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: isTotal
                ? AppTheme.titleMedium.copyWith(fontWeight: FontWeight.bold)
                : AppTheme.bodyMedium,
          ),
        ),
        Text(
          '₵${amount.toStringAsFixed(2)}',
          style: isTotal
              ? AppTheme.titleLarge.copyWith(
                  color: AppTheme.primaryColor,
                  fontWeight: FontWeight.bold,
                )
              : AppTheme.bodyMedium,
        ),
      ],
    );
  }
}

class _HelpItem extends StatelessWidget {
  final IconData icon;
  final String text;

  const _HelpItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.primaryColor, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: AppTheme.bodyMedium)),
      ],
    );
  }
}
