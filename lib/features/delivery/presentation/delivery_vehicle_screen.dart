import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../../core/services/escrow_service.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/theme/cts_theme.dart';
import '../../../core/widgets/cts_ui.dart';
import '../../home/widgets/service_tile.dart';
import '../../ride/models/service_type.dart';
import 'delivery_matching_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/delivery_request.dart';
import '../../delivery/providers/delivery_provider.dart';
import 'package:geolocator/geolocator.dart';
import '../../../core/services/pricing_service.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../ride/services/route_service.dart';
import 'package:flutter/services.dart';

class DeliveryVehicleScreen extends ConsumerStatefulWidget {
  final String pickup;
  final GeoPoint pickupGeoPoint; // ← NEW
  final String dropoff;
  final GeoPoint dropoffGeoPoint; // ← NEW
  final String weightTier;
  final String weightRange;
  final List<String> eligibleVehicles;
  final String parcelType;
  final bool isFragile;
  final bool requiresHelpers;
  final bool hasPhoto;
  final String receiverPhone;
  final String receiverName; // ← NEW
  final String notes;
  final String? photoUrl;

  const DeliveryVehicleScreen({
    super.key,
    required this.pickup,
    required this.pickupGeoPoint,
    required this.dropoff,
    required this.dropoffGeoPoint,
    required this.weightTier,
    required this.weightRange,
    required this.eligibleVehicles,
    required this.parcelType,
    required this.isFragile,
    required this.requiresHelpers,
    required this.hasPhoto,
    required this.receiverPhone,
    required this.receiverName,
    required this.notes,
    this.photoUrl,
  });

  @override
  ConsumerState<DeliveryVehicleScreen> createState() =>
      _DeliveryVehicleScreenState();
}

class _DeliveryVehicleScreenState extends ConsumerState<DeliveryVehicleScreen> {
  int _selectedVehicleIndex = 0;

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

  @override
  void initState() {
    super.initState();
    PricingService.instance.fetch();
    _calculateDistance();
  }

  Future<void> _calculateDistance() async {
    try {
      final result = await ref.read(routeServiceProvider).getRoute(
            LatLng(widget.pickupGeoPoint.latitude,
                widget.pickupGeoPoint.longitude),
            LatLng(widget.dropoffGeoPoint.latitude,
                widget.dropoffGeoPoint.longitude),
          );
      if (!mounted) return;
      if (result != null) {
        setState(() {
          _distanceKm = result.distanceKm;
          _distanceApproximate = false;
          _calculatingDistance = false;
        });
        return;
      }
      _fallbackStraightLine(); // Directions returned null
    } catch (_) {
      _fallbackStraightLine();
    }
  }

  void _fallbackStraightLine() {
    if (!mounted) return;
    final metres = Geolocator.distanceBetween(
      widget.pickupGeoPoint.latitude,
      widget.pickupGeoPoint.longitude,
      widget.dropoffGeoPoint.latitude,
      widget.dropoffGeoPoint.longitude,
    );
    setState(() {
      _distanceKm = metres / 1000;
      _distanceApproximate = true;
      _calculatingDistance = false;
    });
  }

  double _distanceKm = 0.0;
  bool _calculatingDistance = true;
  bool _distanceApproximate = false;

  // Driver surcharges (Aboboya / Mini Truck only)
  final List<Map<String, dynamic>> _surchargeOptions = [
    {'label': 'None', 'amount': 0.0},
    {'label': 'Oversized load', 'amount': 15.0},
    {'label': 'Difficult access', 'amount': 8.0},
  ];
  int _selectedSurcharge = 0;

  // Display metadata only — pricing comes from PricingService, not these.
  final List<Map<String, dynamic>> _allVehicles = [
    {
      'key': 'Okada',
      'icon': Icons.two_wheeler_rounded,
      'name': 'Okada',
      'desc': 'Fast · small parcels only',
      'capacity': '0–5 kg',
    },
    {
      'key': 'Aboboya',
      'icon': Icons.electric_rickshaw_rounded,
      'name': 'Aboboya',
      'desc': 'Tricycle · medium loads',
      'capacity': '5–100 kg',
    },
    {
      'key': 'Mini Truck',
      'icon': Icons.local_shipping_rounded,
      'name': 'Mini Truck',
      'desc': 'Bulk goods · furniture · materials',
      'capacity': '100 kg+',
    },
  ];

  List<Map<String, dynamic>> get _vehicles => _allVehicles
      .where((v) => widget.eligibleVehicles.contains(v['key']))
      .toList();

  Map<String, dynamic> get _selected => _vehicles[_selectedVehicleIndex];

  // Full fare from PricingService (single source of truth, matches the CF).
  // Includes vehicle base+perKm, weight tier, fragile, and helper surcharges.
  double get _totalFare {
    final pricing = PricingService.instance.calculateDeliveryFare(
      _distanceKm,
      vehicleType: _selected['key'] as String,
      weightTier: widget.weightTier,
      isFragile: widget.isFragile,
      requiresHelpers: widget.requiresHelpers,
    );
    // Optional driver-requested surcharge (passenger-approved) adds on top.
    return pricing + _surchargeAmount;
  }

  double get _surchargeAmount =>
      _surchargeOptions[_selectedSurcharge]['amount'] as double;

  @override
  Widget build(BuildContext context) {
    final name = _selected['name'] as String;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: CtsTheme.background,
        body: Column(
          children: [
            const CtsServiceHeader(
              title: 'Choose a vehicle',
              subtitle: 'Review your delivery, then confirm',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(ctsGutter, 6, ctsGutter, 24),
                children: [
                  _buildRouteSummary(),
                  const SizedBox(height: 12),
                  _buildInfoChips(),
                  const SizedBox(height: 22),
                  CtsSectionHeader('Available vehicles',
                      caption:
                          'For ${widget.weightTier.toLowerCase()} parcels (${widget.weightRange})'),
                  for (final e in _vehicles.asMap().entries) ...[
                    if (e.key > 0) const SizedBox(height: 8),
                    _VehicleCard(
                      vehicle: e.value,
                      isSelected: _selectedVehicleIndex == e.key,
                      fare: _calculatingDistance
                          ? null
                          : PricingService.instance.calculateDeliveryFare(
                              _distanceKm,
                              vehicleType: e.value['key'] as String,
                              weightTier: widget.weightTier,
                              isFragile: widget.isFragile,
                              requiresHelpers: widget.requiresHelpers,
                            ),
                      onTap: () => setState(() {
                        _selectedVehicleIndex = e.key;
                        _selectedSurcharge = 0;
                      }),
                    ),
                  ],
                  const SizedBox(height: 22),
                  const CtsSectionHeader('Payment'),
                  _buildPaymentSelector(),
                  const SizedBox(height: 22),
                  const CtsSectionHeader('Fare estimate'),
                  _buildFareBreakdown(),
                ],
              ),
            ),
            Container(
              decoration: const BoxDecoration(
                color: CtsTheme.surface,
                border: Border(top: BorderSide(color: CtsTheme.border)),
              ),
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding:
                      const EdgeInsets.fromLTRB(ctsGutter, 12, ctsGutter, 0),
                  child: CtsPrimaryButton(
                    label: _calculatingDistance
                        ? 'Calculating fare…'
                        : 'Confirm $name delivery',
                    trailingText: _calculatingDistance
                        ? null
                        : 'GHS ${_totalFare.toStringAsFixed(2)}',
                    icon: Icons.local_shipping_rounded,
                    loading: _isCreating,
                    onPressed: _calculatingDistance || _isCreating
                        ? null
                        : _confirmDelivery,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteSummary() {
    return CtsCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RouteRow(caption: 'Pickup', label: widget.pickup, filled: false),
          const Padding(
            padding: EdgeInsets.only(left: 5, top: 2, bottom: 2),
            child: SizedBox(
              height: 12,
              child: VerticalDivider(
                  width: 2, thickness: 2, color: CtsTheme.border),
            ),
          ),
          _RouteRow(caption: 'Drop-off', label: widget.dropoff, filled: true),
          const Divider(height: 22, color: CtsTheme.border),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _StatPill(
                  icon: Icons.straighten_rounded,
                  label: _calculatingDistance
                      ? 'Measuring route…'
                      : _distanceApproximate
                          ? '~${_distanceKm.toStringAsFixed(1)} km'
                          : '${_distanceKm.toStringAsFixed(1)} km'),
              _StatPill(icon: Icons.scale_rounded, label: widget.weightRange),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChips() {
    final pricing = PricingService.instance;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Chip(label: widget.parcelType, icon: Icons.inventory_2_rounded),
        _Chip(label: widget.weightTier, icon: Icons.scale_rounded),
        if (widget.isFragile)
          _Chip(
              label:
                  'Fragile +GHS ${pricing.deliveryFragileSurcharge.toStringAsFixed(0)}',
              icon: Icons.wine_bar_rounded),
        if (widget.requiresHelpers)
          _Chip(
              label:
                  'Helpers +GHS ${pricing.deliveryHelperSurcharge.toStringAsFixed(0)}',
              icon: Icons.people_rounded),
        if (widget.hasPhoto)
          const _Chip(
              label: 'Photo attached', icon: Icons.photo_camera_rounded),
      ],
    );
  }

  Widget _buildFareBreakdown() {
    if (_calculatingDistance) {
      return const CtsCard(
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: CtsTheme.primary),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text('Measuring the route to price your delivery…',
                  style:
                      TextStyle(fontSize: 13, color: CtsTheme.textSecondary)),
            ),
          ],
        ),
      );
    }
    final pricing = PricingService.instance;
    // Real component values from settings (same ones PricingService uses).
    final fragileAmt =
        widget.isFragile ? pricing.deliveryFragileSurcharge : 0.0;
    final helperAmt =
        widget.requiresHelpers ? pricing.deliveryHelperSurcharge : 0.0;
    final weightAmt = switch (widget.weightTier.toLowerCase()) {
      'medium' => pricing.deliveryWeightMedium,
      'large' => pricing.deliveryWeightLarge,
      _ => pricing.deliveryWeightSmall,
    };
    // Base = total minus the itemized add-ons (and minus optional surcharge).
    final base =
        _totalFare - _surchargeAmount - fragileAmt - helperAmt - weightAmt;

    return CtsCard(
      child: Column(
        children: [
          _FareRow(
              label: 'Base fare (${_distanceKm.toStringAsFixed(1)} km)',
              value: 'GHS ${base.toStringAsFixed(2)}'),
          if (weightAmt > 0) ...[
            const SizedBox(height: 8),
            _FareRow(
                label: '${widget.weightTier} package',
                value: '+GHS ${weightAmt.toStringAsFixed(2)}'),
          ],
          if (fragileAmt > 0) ...[
            const SizedBox(height: 8),
            _FareRow(
                label: 'Fragile handling',
                value: '+GHS ${fragileAmt.toStringAsFixed(2)}'),
          ],
          if (helperAmt > 0) ...[
            const SizedBox(height: 8),
            _FareRow(
                label: 'Loading helpers',
                value: '+GHS ${helperAmt.toStringAsFixed(2)}'),
          ],
          if (_surchargeAmount > 0) ...[
            const SizedBox(height: 8),
            _FareRow(
                label: _surchargeOptions[_selectedSurcharge]['label'],
                value: '+GHS ${_surchargeAmount.toStringAsFixed(2)}'),
          ],
          const Divider(height: 24, color: CtsTheme.border),
          Row(
            children: [
              const Expanded(
                child: Text('Total estimate',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: CtsTheme.textPrimary,
                    )),
              ),
              Text('GHS ${_totalFare.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: CtsTheme.textPrimary,
                  )),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline_rounded,
                  size: 14, color: CtsTheme.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _distanceApproximate
                      ? 'Distance is approximate — final fare may vary.'
                      : 'Final fare may vary slightly based on actual distance.',
                  style: const TextStyle(
                      fontSize: 12, color: CtsTheme.textSecondary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _isCreating = false;

  String _paymentMethod = 'wallet'; // 'wallet' | 'cash'

  Future<void> _confirmDelivery() async {
    if (_isCreating) return; // re-entry guard
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please sign in again to place this delivery.'),
      ));
      return;
    }

    HapticFeedback.mediumImpact(); // instant tactile feedback
    setState(() => _isCreating = true); // immediate loading state

    // ── Step 1: Hold funds (wallet only — cash is collected by the driver) ──
    String? escrowId;
    if (_paymentMethod == 'wallet') {
      final escrowResult = await EscrowService.instance.holdBalance(
        amount: _totalFare,
        serviceType: 'delivery',
        referenceType: 'delivery',
      );
      if (!escrowResult.success) {
        if (mounted) {
          setState(() => _isCreating = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(escrowResult.shortfall != null
                ? 'Need GH₵${escrowResult.shortfall!.toStringAsFixed(2)} more. Top up your wallet.'
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
    // ─────────────────────────────────────────────────────────────────────

    try {
      final request = DeliveryRequest(
        id: '',
        passengerId: uid,
        status: DeliveryStatus.pending,
        pickupLocation: widget.pickupGeoPoint,
        dropoffLocation: widget.dropoffGeoPoint,
        pickupAddress: widget.pickup,
        photoUrl: widget.photoUrl,
        dropoffAddress: widget.dropoff,
        parcelType: widget.parcelType,
        weightTier: widget.weightTier,
        weightRange: widget.weightRange,
        isFragile: widget.isFragile,
        requiresHelpers: widget.requiresHelpers,
        notes: widget.notes.isEmpty ? null : widget.notes,
        vehicleType: _selected['name'],
        receiverPhone:
            widget.receiverPhone.isEmpty ? null : widget.receiverPhone,
        receiverName: widget.receiverName.isEmpty ? null : widget.receiverName,
        estimatedFare: _totalFare,
        createdAt: DateTime.now(),
        paymentMethod: _paymentMethod,
      );

      final repo = ref.read(deliveryRepositoryProvider);
      final deliveryId = await repo.createDelivery(request);
      // ── Step 2: Attach escrow (wallet bookings only) ──────────────────────
      if (escrowId != null) {
        await EscrowService.instance.attachToOrder(
          escrowId: escrowId,
          referenceId: deliveryId,
          referenceType: 'delivery',
        );
        // Save escrowId to delivery document for CF cancellation refund
        await FirebaseFirestore.instance
            .collection('deliveries')
            .doc(deliveryId)
            .update({'escrowId': escrowId});
      }

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => DeliveryMatchingScreen(
            deliveryId: deliveryId,
            vehicleName: _selected['name'],
            dropoff: widget.dropoff,
            fare: 'GHS ${_totalFare.toStringAsFixed(2)}',
          ),
        ),
      );
    } catch (e) {
      // Rollback escrow if delivery creation failed
      if (escrowId != null) {
        try {
          final fns = FirebaseFunctions.instanceFor(region: 'europe-west2');
          await fns.httpsCallable('refundEscrowOnError').call({
            'escrowId': escrowId,
            'reason': 'order_creation_failed',
          });
        } catch (_) {}
      }
      debugPrint('Delivery creation failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text(
            'We couldn\'t place your delivery. Check your connection and try again.'),
        backgroundColor: AppColors.error,
      ));
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }
}

// ─── Vehicle Card ─────────────────────────────────────────────────────────────
class _VehicleCard extends StatelessWidget {
  final Map<String, dynamic> vehicle;
  final bool isSelected;
  final double? fare; // null while the route distance is still loading
  final VoidCallback onTap;

  const _VehicleCard({
    required this.vehicle,
    required this.isSelected,
    required this.fare,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fareText =
        fare == null ? 'Calculating…' : 'GHS ${fare!.toStringAsFixed(2)}';
    return CtsSelectableCard(
      selected: isSelected,
      showCheck: false,
      semanticLabel:
          '${vehicle['name']}, ${vehicle['desc']}, ${vehicle['capacity']}, $fareText estimate',
      padding: const EdgeInsets.all(10),
      onTap: onTap,
      child: Row(
        children: [
          _VehicleThumb(vehicle: vehicle, isSelected: isSelected),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(vehicle['name'],
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: CtsTheme.textPrimary,
                    )),
                Text(vehicle['desc'],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: CtsTheme.textSecondary)),
                const SizedBox(height: 2),
                Text('Carries ${vehicle['capacity']}',
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: CtsTheme.textTertiary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 104),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(fareText,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: fare == null ? 12.5 : 15.5,
                        fontWeight: FontWeight.w800,
                        color: fare == null
                            ? CtsTheme.textSecondary
                            : CtsTheme.textPrimary,
                      )),
                ),
                const Text('Estimate',
                    style: TextStyle(
                        fontSize: 11.5, color: CtsTheme.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Okada has a real photo; Aboboya and Mini Truck have none yet, so they get
/// an icon tile of the same size rather than a photo of a different vehicle.
class _VehicleThumb extends StatelessWidget {
  final Map<String, dynamic> vehicle;
  final bool isSelected;
  const _VehicleThumb({required this.vehicle, required this.isSelected});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 64,
          height: 54,
          child: vehicle['key'] == 'Okada'
              ? const ServiceImage(
                  service: ServiceType.okada, aspectRatio: 64 / 54)
              : ColoredBox(
                  color: isSelected ? CtsTheme.surface : CtsTheme.surfaceAlt,
                  child: Icon(vehicle['icon'] as IconData,
                      size: 26,
                      color: isSelected
                          ? CtsTheme.primaryDeep
                          : CtsTheme.textSecondary),
                ),
        ),
      );
}

// ─── Small shared widgets ─────────────────────────────────────────────────────
class _RouteRow extends StatelessWidget {
  final String caption;
  final String label;
  final bool filled;
  const _RouteRow(
      {required this.caption, required this.label, required this.filled});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 3),
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: filled ? CtsTheme.primary : CtsTheme.surface,
            shape: BoxShape.circle,
            border: Border.all(color: CtsTheme.primary, width: 2.5),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(caption,
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: CtsTheme.textSecondary)),
              Text(label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: CtsTheme.textPrimary,
                  )),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String label;
  const _StatPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: CtsTheme.textSecondary),
        const SizedBox(width: 5),
        Flexible(
          child: Text(label,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: CtsTheme.textPrimary,
              )),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final IconData icon;
  const _Chip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: CtsTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: CtsTheme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: CtsTheme.textSecondary),
          const SizedBox(width: 5),
          Flexible(
            child: Text(label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: CtsTheme.textPrimary,
                )),
          ),
        ],
      ),
    );
  }
}

class _FareRow extends StatelessWidget {
  final String label;
  final String value;
  const _FareRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(label,
              style:
                  const TextStyle(fontSize: 13, color: CtsTheme.textSecondary)),
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
}
