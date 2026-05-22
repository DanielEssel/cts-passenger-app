// lib/features/delivery/presentation/delivery_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';
import 'delivery_vehicle_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:io';

class DeliveryScreen extends StatefulWidget {
  const DeliveryScreen({super.key});

  @override
  State<DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends State<DeliveryScreen> {
  final _dropoffController = TextEditingController();
  final _receiverPhoneCtrl = TextEditingController();
  final _receiverNameCtrl = TextEditingController();
  final _noteController = TextEditingController();

  // Pickup state
  String? _pickupAddress;
  GeoPoint? _pickupGeoPoint;
  bool _loadingPickup = false;

  // Dropoff state
  String? _dropoffAddress;
  GeoPoint? _dropoffGeoPoint;
  bool _loadingDropoff = false;

  int _selectedParcelType = 0;
  int _selectedWeightTier = -1;
  bool _isFragile = false;
  bool _requiresHelpers = false;
  File? _photoFile;
  String? _photoUrl; // Firebase Storage download URL
  bool _uploadingPhoto = false;

  final List<Map<String, dynamic>> _parcelTypes = [
    {'icon': Icons.description_rounded, 'label': 'Documents'},
    {'icon': Icons.inventory_2_rounded, 'label': 'Package'},
    {'icon': Icons.fastfood_rounded, 'label': 'Food'},
    {'icon': Icons.devices_rounded, 'label': 'Electronics'},
    {'icon': Icons.chair_rounded, 'label': 'Furniture'},
    {'icon': Icons.construction_rounded, 'label': 'Materials'},
  ];

  final List<Map<String, dynamic>> _weightTiers = [
    {
      'label': 'Small',
      'range': '0–5 kg',
      'example': 'Documents, food, small parcels',
      'vehicles': ['Okada'],
      'icon': Icons.two_wheeler_rounded,
    },
    {
      'label': 'Medium',
      'range': '5–20 kg',
      'example': 'Groceries, boxes, electronics',
      'vehicles': ['Okada', 'Aboboya'],
      'icon': Icons.inventory_2_rounded,
    },
    {
      'label': 'Large',
      'range': '20–100 kg',
      'example': 'Market goods, appliances',
      'vehicles': ['Aboboya'],
      'icon': Icons.shopping_cart_rounded,
    },
    {
      'label': 'Bulk',
      'range': '100 kg+',
      'example': 'Furniture, construction materials',
      'vehicles': ['Mini Truck'],
      'icon': Icons.local_shipping_rounded,
    },
  ];

  bool get _canProceed =>
    _pickupAddress   != null &&
    _pickupGeoPoint  != null &&
    _dropoffAddress  != null &&
    _dropoffGeoPoint != null &&
    _selectedWeightTier >= 0 &&
    !_uploadingPhoto; // ← block while uploading

  @override
  void initState() {
    super.initState();
    _detectPickupLocation();
  }

  @override
  void dispose() {
    _dropoffController.dispose();
    _receiverPhoneCtrl.dispose();
    _receiverNameCtrl.dispose();
    _noteController.dispose();
    super.dispose();
  }

  // ── GPS pickup ────────────────────────────────────────────────────────────

  Future<void> _detectPickupLocation() async {
    if (!mounted) return;
    setState(() => _loadingPickup = true);

    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever ||
          perm == LocationPermission.denied) {
        throw Exception('Location permission denied.');
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      final placemarks =
          await placemarkFromCoordinates(pos.latitude, pos.longitude);

      if (!mounted) return;
      if (placemarks.isNotEmpty) {
        setState(() {
          _pickupAddress = _formatPlacemark(placemarks.first);
          _pickupGeoPoint = GeoPoint(pos.latitude, pos.longitude);
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pickupAddress = 'Current location';
        _pickupGeoPoint = const GeoPoint(5.6037, -0.1870); // Accra fallback
      });
    } finally {
      if (mounted) setState(() => _loadingPickup = false);
    }
  }

  Future<void> _geocodeDropoff(String text) async {
    if (text.trim().isEmpty) return;
    if (!mounted) return;
    setState(() => _loadingDropoff = true);

    try {
      final locations = await locationFromAddress('$text, Ghana');
      if (locations.isEmpty) throw Exception('Address not found.');

      final loc = locations.first;
      final placemarks =
          await placemarkFromCoordinates(loc.latitude, loc.longitude);
      final address =
          placemarks.isNotEmpty ? _formatPlacemark(placemarks.first) : text;

      if (!mounted) return;
      setState(() {
        _dropoffAddress = address;
        _dropoffGeoPoint = GeoPoint(loc.latitude, loc.longitude);
      });
    } catch (_) {
      if (!mounted) return;
      // keep whatever was typed as address, GeoPoint stays null
      setState(() => _dropoffAddress = null);
    } finally {
      if (mounted) setState(() => _loadingDropoff = false);
    }
  }

  String _formatPlacemark(Placemark p) {
    final parts = <String>[
      if (p.name != null && p.name!.isNotEmpty && p.name != p.thoroughfare)
        p.name!,
      if (p.thoroughfare != null && p.thoroughfare!.isNotEmpty) p.thoroughfare!,
      if (p.subLocality != null && p.subLocality!.isNotEmpty) p.subLocality!,
      if (p.locality != null && p.locality!.isNotEmpty) p.locality!,
    ];
    return parts.take(3).join(', ');
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _goToVehicleScreen() {
  HapticFeedback.mediumImpact();
  final tier = _weightTiers[_selectedWeightTier];
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => DeliveryVehicleScreen(
        pickup:           _pickupAddress!,
        pickupGeoPoint:   _pickupGeoPoint!,
        dropoff:          _dropoffAddress!,
        dropoffGeoPoint:  _dropoffGeoPoint!,
        weightTier:       tier['label'],
        weightRange:      tier['range'],
        eligibleVehicles: tier['vehicles'],
        parcelType:       _parcelTypes[_selectedParcelType]['label'],
        isFragile:        _isFragile,
        requiresHelpers:  _requiresHelpers,
        hasPhoto:         _photoUrl != null,    // ← real check
        photoUrl:         _photoUrl,            // ← NEW
        receiverPhone:    _receiverPhoneCtrl.text,
        receiverName:     _receiverNameCtrl.text,
        notes:            _noteController.text,
      ),
    ),
  );
}

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const CTSRideAppBar(title: 'Send a Parcel'),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildRouteCard(),
            const SizedBox(height: 14),
            _buildSectionCard(
                step: 3,
                title: 'What are you sending?',
                child: _buildParcelTypes()),
            const SizedBox(height: 14),
            _buildSectionCard(
              step: 4,
              title: 'Approximate weight',
              subtitle: 'Determines which vehicles can carry your delivery',
              child: _buildWeightTiers(),
            ),
            const SizedBox(height: 14),
            _buildSectionCard(
              step: 5,
              title: 'Photo of items',
              subtitle: 'Helps drivers prepare and verify at pickup',
              child: _buildPhotoUpload(),
            ),
            const SizedBox(height: 14),
            _buildSectionCard(
                step: 6,
                title: "Receiver's contact",
                child: _buildReceiverFields()),
            const SizedBox(height: 14),
            _buildSectionCard(
                step: 7, title: 'Extra options', child: _buildExtraOptions()),
            const SizedBox(height: 14),
            _buildSectionCard(
              step: 8,
              title: 'Delivery notes',
              child: _inputField(
                controller: _noteController,
                hint: 'Any special instructions for the rider…',
                icon: Icons.notes_rounded,
                maxLines: 3,
              ),
            ),
            const SizedBox(height: 24),
            PrimaryButton(
              label: _canProceed
                  ? 'See available vehicles →'
                  : 'Complete required fields',
              onTap: _canProceed ? _goToVehicleScreen : null,
              color: _canProceed ? null : AppColors.textTertiary,
            ),
            if (!_canProceed) ...[
              const SizedBox(height: 8),
              Center(
                child: Text(
                  _validationHint,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  String get _validationHint {
    if (_pickupGeoPoint == null) return 'Detecting your pickup location…';
    if (_dropoffGeoPoint == null) return 'Enter and search a drop-off address';
    if (_selectedWeightTier < 0) return 'Select a weight tier to continue';
    return '';
  }

  // ── Route card ────────────────────────────────────────────────────────────

  Widget _buildRouteCard() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Step 1 — pickup
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _StepNumber(number: '1'),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Pickup location',
                          style: AppTextStyles.labelLarge),
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: _detectPickupLocation,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Row(
                            children: [
                              _loadingPickup
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Icon(Icons.my_location_rounded,
                                      color: AppColors.success, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _pickupAddress ?? 'Detecting location…',
                                  style: AppTextStyles.bodySmall.copyWith(
                                    color: _pickupAddress != null
                                        ? AppColors.textPrimary
                                        : AppColors.textTertiary,
                                  ),
                                ),
                              ),
                              Text('Change',
                                  style: AppTextStyles.caption.copyWith(
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // Connector
            Padding(
              padding: const EdgeInsets.only(left: 13, top: 6, bottom: 6),
              child:
                  Container(width: 2, height: 20, color: AppColors.borderLight),
            ),

            // Step 2 — drop-off
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _StepNumber(number: '2'),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Drop-off address',
                          style: AppTextStyles.labelLarge),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _inputField(
                              controller: _dropoffController,
                              hint: 'Search destination…',
                              icon: Icons.location_on_rounded,
                              onChanged: (_) {
                                // Clear geocoded point when user types
                                if (_dropoffGeoPoint != null) {
                                  setState(() {
                                    _dropoffGeoPoint = null;
                                    _dropoffAddress = null;
                                  });
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () =>
                                _geocodeDropoff(_dropoffController.text),
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: _loadingDropoff
                                    ? AppColors.surfaceAlt
                                    : AppColors.primary,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: _loadingDropoff
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: AppColors.primary),
                                    )
                                  : const Icon(Icons.search_rounded,
                                      color: Colors.white, size: 18),
                            ),
                          ),
                        ],
                      ),
                      // Geocoded address confirmation
                      if (_dropoffAddress != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(Icons.check_circle_rounded,
                                color: AppColors.success, size: 14),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(_dropoffAddress!,
                                  style: AppTextStyles.caption.copyWith(
                                      color: AppColors.success,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  // ── Section builders (unchanged from original) ────────────────────────────

  Widget _buildParcelTypes() => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: List.generate(_parcelTypes.length, (i) {
          final p = _parcelTypes[i];
          final isSelected = _selectedParcelType == i;
          return GestureDetector(
            onTap: () => setState(() => _selectedParcelType = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primary.withValues(alpha: 0.1)
                    : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.border,
                  width: isSelected ? 1.5 : 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(p['icon'],
                      size: 15,
                      color: isSelected
                          ? AppColors.primary
                          : AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Text(p['label'],
                      style: AppTextStyles.labelMedium.copyWith(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.textSecondary,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.w400,
                      )),
                ],
              ),
            ),
          );
        }),
      );

  Widget _buildWeightTiers() => Column(
        children: List.generate(_weightTiers.length, (i) {
          final t = _weightTiers[i];
          final isSelected = _selectedWeightTier == i;
          return GestureDetector(
            onTap: () => setState(() => _selectedWeightTier = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primary.withValues(alpha: 0.07)
                    : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.border,
                  width: isSelected ? 1.5 : 0.5,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary.withValues(alpha: 0.12)
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(t['icon'],
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.textSecondary,
                        size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(t['label'],
                                style: AppTextStyles.labelLarge.copyWith(
                                    color: isSelected
                                        ? AppColors.primary
                                        : AppColors.textPrimary)),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppColors.primary.withValues(alpha: 0.1)
                                    : AppColors.border,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(t['range'],
                                  style: AppTextStyles.caption.copyWith(
                                      color: isSelected
                                          ? AppColors.primary
                                          : AppColors.textSecondary,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(t['example'], style: AppTextStyles.caption),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: (t['vehicles'] as List<String>)
                        .map((v) => Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(v,
                                  style: AppTextStyles.caption.copyWith(
                                      color: isSelected
                                          ? AppColors.primary
                                          : AppColors.textTertiary,
                                      fontSize: 10)),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
          );
        }),
      );

  Widget _buildPhotoUpload() => GestureDetector(
      onTap: _uploadingPhoto ? null : _pickPhoto,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        height: 100,
        decoration: BoxDecoration(
          color: _photoUrl != null
              ? AppColors.primary.withValues(alpha: 0.06)
              : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _photoUrl != null ? AppColors.primary : AppColors.border,
            width: _photoUrl != null ? 1.5 : 0.5,
          ),
        ),
        child: _uploadingPhoto
            ? const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 24, height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primary),
                  ),
                  SizedBox(height: 8),
                  Text('Uploading photo…',
                      style: AppTextStyles.caption),
                ],
              )
            : _photoFile != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(_photoFile!, fit: BoxFit.cover),
                        Container(
                          color: Colors.black.withValues(alpha: 0.35),
                        ),
                        const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_rounded,
                                color: Colors.white, size: 28),
                            SizedBox(height: 4),
                            Text('Photo added — tap to change',
                                style: TextStyle(
                                  color:      Colors.white,
                                  fontSize:   12,
                                  fontWeight: FontWeight.w600,
                                )),
                          ],
                        ),
                      ],
                    ),
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.add_a_photo_rounded,
                          color: AppColors.textTertiary, size: 26),
                      const SizedBox(height: 6),
                      Text('Add photo of items',
                          style: AppTextStyles.labelMedium
                              .copyWith(color: AppColors.textSecondary)),
                      const SizedBox(height: 2),
                      const Text('Tap to choose from gallery',
                          style: AppTextStyles.caption),
                    ],
                  ),
      ),
    );

  Widget _buildReceiverFields() => Column(
        children: [
          _inputField(
            controller: _receiverPhoneCtrl,
            hint: '+233 — Receiver phone number',
            icon: Icons.phone_rounded,
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 10),
          _inputField(
            controller: _receiverNameCtrl,
            hint: "Receiver's name (optional)",
            icon: Icons.person_rounded,
          ),
        ],
      );

  Widget _buildExtraOptions() => Column(
        children: [
          _ToggleRow(
            icon: Icons.broken_image_rounded,
            label: 'Fragile item',
            subtitle: '+GHS 5.00 handling fee',
            value: _isFragile,
            onChanged: (v) => setState(() => _isFragile = v),
          ),
          const SizedBox(height: 10),
          _ToggleRow(
            icon: Icons.people_rounded,
            label: 'Requires loading helpers',
            subtitle: '+GHS 10.00 (Aboboya / Mini Truck only)',
            value: _requiresHelpers,
            onChanged: (v) => setState(() => _requiresHelpers = v),
          ),
        ],
      );

  Widget _buildSectionCard({
    required int step,
    required String title,
    String? subtitle,
    required Widget child,
  }) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StepNumber(number: '$step'),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.labelLarge),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle, style: AppTextStyles.caption),
                  ],
                  const SizedBox(height: 10),
                  child,
                ],
              ),
            ),
          ],
        ),
      );

  Widget _inputField({
    TextEditingController? controller,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) =>
      Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: TextField(
          controller: controller,
          keyboardType: keyboardType,
          maxLines: maxLines,
          onChanged: onChanged,
          style: AppTextStyles.bodyMedium,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textTertiary, fontStyle: FontStyle.italic),
            prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 18),
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
      );

  Future<void> _pickPhoto() async {
  final picker = ImagePicker();
  final picked = await picker.pickImage(
    source:     ImageSource.gallery,
    maxWidth:   1024,
    maxHeight:  1024,
    imageQuality: 85,
  );
  if (picked == null || !mounted) return;

  setState(() {
    _photoFile      = File(picked.path);
    _uploadingPhoto = true;
  });

  try {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception('Not logged in');

    final ref = FirebaseStorage.instance
        .ref()
        .child('delivery_photos')
        .child(uid)
        .child('${DateTime.now().millisecondsSinceEpoch}.jpg');

    await ref.putFile(_photoFile!);
    final url = await ref.getDownloadURL();

    if (!mounted) return;
    setState(() {
      _photoUrl       = url;
      _uploadingPhoto = false;
    });
  } catch (e) {
    if (!mounted) return;
    setState(() {
      _photoFile      = null;
      _photoUrl       = null;
      _uploadingPhoto = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:         Text('Photo upload failed: $e'),
      backgroundColor: AppColors.error,
    ));
  }
}
}

// ── Shared small widgets ───────────────────────────────────────────────────────

class _StepNumber extends StatelessWidget {
  final String number;
  const _StepNumber({required this.number});

  @override
  Widget build(BuildContext context) => Container(
        width: 26,
        height: 26,
        decoration: const BoxDecoration(
            color: AppColors.primary, shape: BoxShape.circle),
        child: Center(
          child: Text(number,
              style: AppTextStyles.caption.copyWith(
                  color: AppColors.background, fontWeight: FontWeight.w700)),
        ),
      );
}

class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String label, subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
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
                      style: AppTextStyles.labelMedium.copyWith(
                          color: value
                              ? AppColors.primary
                              : AppColors.textPrimary)),
                  Text(subtitle, style: AppTextStyles.caption),
                ],
              ),
            ),
            Switch.adaptive(
                value: value,
                onChanged: onChanged,
                activeColor: AppColors.primary),
          ],
        ),
      );
}
