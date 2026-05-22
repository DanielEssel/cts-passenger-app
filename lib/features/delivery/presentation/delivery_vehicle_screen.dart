import 'package:flutter/material.dart';
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

  // All possible vehicles — filtered by eligibleVehicles
  final List<Map<String, dynamic>> _allVehicles = [
    {
      'key': 'Okada',
      'icon': Icons.two_wheeler_rounded,
      'name': 'Okada',
      'desc': 'Fast · small parcels only',
      'capacity': '0–5 kg',
      'eta': '2 min',
      'etaColor': AppColors.success,
      'baseFare': 5.0,
      'perKm': 2.5,
      'canSurcharge': false,
    },
    {
      'key': 'Aboboya',
      'icon': Icons.electric_rickshaw_rounded,
      'name': 'Aboboya',
      'desc': 'Tricycle · medium loads',
      'capacity': '5–100 kg',
      'eta': '5 min',
      'etaColor': AppColors.success,
      'baseFare': 15.0,
      'perKm': 4.0,
      'canSurcharge': true,
    },
    {
      'key': 'Mini Truck',
      'icon': Icons.local_shipping_rounded,
      'name': 'Mini Truck',
      'desc': 'Bulk goods · furniture · materials',
      'capacity': '100 kg+',
      'eta': '8 min',
      'etaColor': AppColors.warning,
      'baseFare': 40.0,
      'perKm': 7.0,
      'canSurcharge': true,
    },
  ];

  @override
  void initState() {
    super.initState();
    _calculateDistance();
  }

  Future<void> _calculateDistance() async {
    try {
      final metres = Geolocator.distanceBetween(
        widget.pickupGeoPoint.latitude,
        widget.pickupGeoPoint.longitude,
        widget.dropoffGeoPoint.latitude,
        widget.dropoffGeoPoint.longitude,
      );
      if (!mounted) return;
      setState(() {
        _distanceKm = metres / 1000;
        _calculatingDistance = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _distanceKm = 5.0; // safe fallback
        _calculatingDistance = false;
      });
    }
  }

  // Mock distance
  double _distanceKm = 0.0;
  bool _calculatingDistance = true;

  // Driver surcharges (Aboboya / Mini Truck only)
  final List<Map<String, dynamic>> _surchargeOptions = [
    {'label': 'None', 'amount': 0.0},
    {'label': 'Requires helpers', 'amount': 10.0},
    {'label': 'Oversized load', 'amount': 15.0},
    {'label': 'Difficult access', 'amount': 8.0},
  ];
  int _selectedSurcharge = 0;

  List<Map<String, dynamic>> get _vehicles => _allVehicles
      .where((v) => widget.eligibleVehicles.contains(v['key']))
      .toList();

  Map<String, dynamic> get _selected => _vehicles[_selectedVehicleIndex];

  double get _baseFare {
    final v = _selected;
    return (v['baseFare'] as double) + (v['perKm'] as double) * _distanceKm;
  }

  double get _surchargeAmount =>
      _surchargeOptions[_selectedSurcharge]['amount'] as double;

  double get _fragileAddon => widget.isFragile ? 5.0 : 0.0;
  double get _helpersAddon => widget.requiresHelpers ? 10.0 : 0.0;

  double get _totalFare =>
      _baseFare + _surchargeAmount + _fragileAddon + _helpersAddon;

  String get fareRange {
    final low = _baseFare + _fragileAddon + _helpersAddon;
    final high = low + 15; // max possible surcharge
    return 'GHS ${low.toStringAsFixed(0)}–${high.toStringAsFixed(0)}';
  }

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
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _VehicleCard(
                        vehicle: e.value,
                        isSelected: _selectedVehicleIndex == e.key,
                        distanceKm: _distanceKm,
                        fragileAddon: _fragileAddon,
                        helpersAddon: _helpersAddon,
                        onTap: () => setState(() {
                          _selectedVehicleIndex = e.key;
                          _selectedSurcharge = 0;
                        }),
                      ),
                    );
                  }),

                  // Surcharge selector (Aboboya / Mini Truck)
                  if (_selected['canSurcharge'] == true) ...[
                    const SizedBox(height: 4),
                    _buildSurchargeSelector(),
                  ],

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
                    label: '${_distanceKm.toStringAsFixed(1)} km'),
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
          const _Chip(
              label: 'Fragile +GHS 5',
              icon: Icons.broken_image_rounded,
              color: AppColors.warning),
        if (widget.requiresHelpers)
          const _Chip(
              label: 'Helpers +GHS 10',
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

  Widget _buildSurchargeSelector() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 15, color: AppColors.textSecondary),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Driver loading surcharge (optional)',
                  style: AppTextStyles.labelLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'The driver may request one of these after seeing your photo. You approve it before they depart.',
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: 12),
          ...List.generate(_surchargeOptions.length, (i) {
            final opt = _surchargeOptions[i];
            final isSelected = _selectedSurcharge == i;
            final amount = opt['amount'] as double;
            return GestureDetector(
              onTap: () => setState(() => _selectedSurcharge = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.primary.withValues(alpha: 0.07)
                      : AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected ? AppColors.primary : AppColors.border,
                    width: isSelected ? 1.5 : 0.5,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isSelected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      color: isSelected
                          ? AppColors.primary
                          : AppColors.textTertiary,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(opt['label'],
                          style: AppTextStyles.bodySmall.copyWith(
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.w400)),
                    ),
                    Text(
                      amount == 0
                          ? 'No charge'
                          : '+GHS ${amount.toStringAsFixed(0)}',
                      style: AppTextStyles.labelMedium.copyWith(
                        color: amount == 0
                            ? AppColors.textTertiary
                            : AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildFareBreakdown() {
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
              value: 'GHS ${_baseFare.toStringAsFixed(2)}'),
          if (widget.isFragile) ...[
            const SizedBox(height: 8),
            const _DarkRow(label: 'Fragile handling', value: '+GHS 5.00'),
          ],
          if (widget.requiresHelpers) ...[
            const SizedBox(height: 8),
            const _DarkRow(label: 'Loading helpers', value: '+GHS 10.00'),
          ],
          if (_surchargeAmount > 0) ...[
            const SizedBox(height: 8),
            _DarkRow(
                label: _surchargeOptions[_selectedSurcharge]['label'],
                value: '+GHS ${_surchargeAmount.toStringAsFixed(0)}'),
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
              Text(
                'GHS ${_totalFare.toStringAsFixed(2)}',
                style: AppTextStyles.heading3
                    .copyWith(color: AppColors.background),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Final fare may vary slightly based on actual distance.',
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
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    setState(() => _isCreating = true);

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
  final double distanceKm;
  final double fragileAddon;
  final double helpersAddon;
  final VoidCallback onTap;

  const _VehicleCard({
    required this.vehicle,
    required this.isSelected,
    required this.distanceKm,
    required this.fragileAddon,
    required this.helpersAddon,
    required this.onTap,
  });

  double get _fare =>
      (vehicle['baseFare'] as double) +
      (vehicle['perKm'] as double) * distanceKm +
      fragileAddon +
      helpersAddon;

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
                  'GHS ${_fare.toStringAsFixed(0)}',
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
