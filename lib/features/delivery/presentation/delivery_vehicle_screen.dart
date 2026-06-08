import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../../core/services/escrow_service.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';
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
          _durationMin = result.durationMin.toDouble();
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
  double _durationMin = 0.0;
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
      'eta': '2 min',
      'etaColor': AppColors.success,
    },
    {
      'key': 'Aboboya',
      'icon': Icons.electric_rickshaw_rounded,
      'name': 'Aboboya',
      'desc': 'Tricycle · medium loads',
      'capacity': '5–100 kg',
      'eta': '5 min',
      'etaColor': AppColors.success,
    },
    {
      'key': 'Mini Truck',
      'icon': Icons.local_shipping_rounded,
      'name': 'Mini Truck',
      'desc': 'Bulk goods · furniture · materials',
      'capacity': '100 kg+',
      'eta': '8 min',
      'etaColor': AppColors.warning,
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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const CTSRideAppBar(title: 'Choose vehicle'),
      body: Column(
        children: [
          // ── Route summary strip ─────────────────────────────────────────
          _buildRouteSummary(),

          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Weight + parcel info row
                  _buildInfoChips(),
                  const SizedBox(height: 16),

                  const Text('Available vehicles',
                      style: AppTextStyles.heading4),
                  const SizedBox(height: 10),

                  // Vehicle cards
                  ..._vehicles.asMap().entries.map((e) {
                    final vfare = PricingService.instance.calculateDeliveryFare(
                      _distanceKm,
                      vehicleType: e.value['key'] as String,
                      weightTier: widget.weightTier,
                      isFragile: widget.isFragile,
                      requiresHelpers: widget.requiresHelpers,
                    );
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _VehicleCard(
                        vehicle: e.value,
                        isSelected: _selectedVehicleIndex == e.key,
                        fare: vfare,
                        onTap: () => setState(() {
                          _selectedVehicleIndex = e.key;
                          _selectedSurcharge = 0;
                        }),
                      ),
                    );
                  }),

                  const SizedBox(height: 16),

                  // Fare breakdown
                  _buildFareBreakdown(),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),

          // ── Confirm button ─────────────────────────────────────────────
          _buildConfirmButton(),
        ],
      ),
    );
  }

  Widget _buildRouteSummary() {
    return ColoredBox(
      color: AppColors.surfaceAlt,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          children: [
            _RouteRow(dot: AppColors.success, label: widget.pickup),
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 3, bottom: 3),
              child: Row(children: [
                Container(
                    width: 2,
                    height: 14,
                    decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(1)))
              ]),
            ),
            _RouteRow(dot: AppColors.primary, label: widget.dropoff),
            const SizedBox(height: 8),
            Row(
              children: [
                _StatPill(
                    icon: Icons.straighten_rounded,
                    label: _distanceApproximate
                        ? '~${_distanceKm.toStringAsFixed(1)} km'
                        : '${_distanceKm.toStringAsFixed(1)} km'),
                const SizedBox(width: 10),
                _StatPill(icon: Icons.scale_rounded, label: widget.weightRange),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _Chip(
            label: widget.parcelType,
            icon: Icons.inventory_2_rounded,
            color: AppColors.info),
        _Chip(
            label: widget.weightTier,
            icon: Icons.scale_rounded,
            color: AppColors.primary),
        if (widget.isFragile)
          _Chip(
              label:
                  'Fragile +GHS ${PricingService.instance.deliveryFragileSurcharge.toStringAsFixed(0)}',
              icon: Icons.broken_image_rounded,
              color: AppColors.warning),
        if (widget.requiresHelpers)
          _Chip(
              label:
                  'Helpers +GHS ${PricingService.instance.deliveryHelperSurcharge.toStringAsFixed(0)}',
              icon: Icons.people_rounded,
              color: AppColors.warning),
        if (widget.hasPhoto)
          const _Chip(
              label: 'Photo attached',
              icon: Icons.photo_camera_rounded,
              color: AppColors.success),
      ],
    );
  }

  Widget _buildFareBreakdown() {
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

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.darkNavy,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _DarkRow(
              label: 'Base fare (${_distanceKm.toStringAsFixed(1)} km)',
              value: 'GHS ${base.toStringAsFixed(2)}'),
          if (weightAmt > 0) ...[
            const SizedBox(height: 8),
            _DarkRow(
                label: '${widget.weightTier} package',
                value: '+GHS ${weightAmt.toStringAsFixed(2)}'),
          ],
          if (fragileAmt > 0) ...[
            const SizedBox(height: 8),
            _DarkRow(
                label: 'Fragile handling',
                value: '+GHS ${fragileAmt.toStringAsFixed(2)}'),
          ],
          if (helperAmt > 0) ...[
            const SizedBox(height: 8),
            _DarkRow(
                label: 'Loading helpers',
                value: '+GHS ${helperAmt.toStringAsFixed(2)}'),
          ],
          if (_surchargeAmount > 0) ...[
            const SizedBox(height: 8),
            _DarkRow(
                label: _surchargeOptions[_selectedSurcharge]['label'],
                value: '+GHS ${_surchargeAmount.toStringAsFixed(2)}'),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Container(
                height: 0.5, color: Colors.white.withValues(alpha: 0.15)),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total estimate',
                  style: AppTextStyles.bodySmall
                      .copyWith(color: AppColors.textOnDarkMuted)),
              Text('GHS ${_totalFare.toStringAsFixed(2)}',
                  style: AppTextStyles.heading3
                      .copyWith(color: AppColors.background)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _distanceApproximate
                ? 'Distance is approximate — final fare may vary.'
                : 'Final fare may vary slightly based on actual distance.',
            style: AppTextStyles.caption
                .copyWith(color: AppColors.textOnDarkMuted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  bool _isCreating = false;

  Widget _buildConfirmButton() => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
        ),
        child: PrimaryButton(
          label: _calculatingDistance
              ? 'Calculating fare…'
              : _isCreating
                  ? 'Placing order…'
                  : 'Confirm ${_selected['name']} — GHS ${_totalFare.toStringAsFixed(2)}',
          onTap: _calculatingDistance || _isCreating ? null : _confirmDelivery,
        ),
      );

  Future<void> _confirmDelivery() async {
    if (_isCreating) return;                     // re-entry guard
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    HapticFeedback.mediumImpact();               // instant tactile feedback
    setState(() => _isCreating = true);          // immediate loading state

    // ── Step 1: Hold funds ────────────────────────────────────────────────
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
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pushNamed('/wallet'),
          ),
        ));
      }
      return;
    }
    final escrowId = escrowResult.escrowId!;
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
        paymentMethod: 'wallet',
      );

      final repo = ref.read(deliveryRepositoryProvider);
      final deliveryId = await repo.createDelivery(request);

      // ── Step 2: Attach escrow ─────────────────────────────────────────────
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
      if (escrowId.isNotEmpty) {
        try {
          final fns = FirebaseFunctions.instanceFor(region: 'europe-west2');
          await fns.httpsCallable('refundEscrowOnError').call({
            'escrowId': escrowId,
            'reason': 'order_creation_failed',
          });
        } catch (_) {}
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString()),
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
  final double fare;
  final VoidCallback onTap;

  const _VehicleCard({
    required this.vehicle,
    required this.isSelected,
    required this.fare,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.06)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: isSelected ? 1.5 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(vehicle['icon'],
                  color:
                      isSelected ? AppColors.primary : AppColors.textSecondary,
                  size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(vehicle['name'], style: AppTextStyles.labelLarge),
                  Text(vehicle['desc'], style: AppTextStyles.caption),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: vehicle['etaColor'],
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text('${vehicle['eta']} away',
                          style: AppTextStyles.caption.copyWith(
                            color: vehicle['etaColor'],
                            fontWeight: FontWeight.w600,
                          )),
                      const SizedBox(width: 8),
                      Text('· ${vehicle['capacity']}',
                          style: AppTextStyles.caption),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'GHS ${fare.toStringAsFixed(0)}',
                  style: AppTextStyles.amountSmall.copyWith(fontSize: 15),
                ),
                const Text('est. fare', style: AppTextStyles.caption),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Small shared widgets ─────────────────────────────────────────────────────
class _RouteRow extends StatelessWidget {
  final Color dot;
  final String label;
  const _RouteRow({required this.dot, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(
            child: Text(label,
                style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textPrimary, fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis)),
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
        Icon(icon, size: 12, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(label, style: AppTextStyles.caption),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  const _Chip({required this.label, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: AppTextStyles.caption
                  .copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _DarkRow extends StatelessWidget {
  final String label;
  final String value;
  const _DarkRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: AppTextStyles.bodySmall
                .copyWith(color: AppColors.textOnDarkMuted)),
        Text(value,
            style: AppTextStyles.labelMedium
                .copyWith(color: AppColors.background)),
      ],
    );
  }
}
