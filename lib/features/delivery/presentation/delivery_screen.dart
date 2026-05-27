// lib/features/delivery/presentation/delivery_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';
import '../../ride/models/place_result.dart';
import '../../ride/repositories/google_places_repository.dart';
import 'delivery_vehicle_screen.dart';

// ── Delivery screen ───────────────────────────────────────────────────────────
class DeliveryScreen extends ConsumerStatefulWidget {
  const DeliveryScreen({super.key});

  @override
  ConsumerState<DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends ConsumerState<DeliveryScreen> {
  // ── Controllers ───────────────────────────────────────────────────────────
  final _dropoffCtrl      = TextEditingController();
  final _receiverPhoneCtrl = TextEditingController();
  final _receiverNameCtrl  = TextEditingController();
  final _noteCtrl          = TextEditingController();

  // ── Pickup state ──────────────────────────────────────────────────────────
  String?   _pickupAddress;
  GeoPoint? _pickupGeo;
  bool      _loadingPickup = false;

  // ── Dropoff state (Places API) ────────────────────────────────────────────
  String?             _dropoffAddress;
  GeoPoint?           _dropoffGeo;
  bool                _searchingDropoff = false;
  List<PlaceResult>   _suggestions      = [];
  Timer?              _debounce;
  bool                _showSuggestions  = false;

  // ── Form state ─────────────────────────────────────────────────────────────
  int    _selectedParcel = 0;
  int    _selectedWeight = -1;
  bool   _isFragile       = false;
  bool   _requiresHelpers = false;
  File?  _photoFile;
  String? _photoUrl;
  bool   _uploadingPhoto  = false;

  static const _parcelTypes = [
    (icon: Icons.description_rounded,  label: 'Documents'),
    (icon: Icons.inventory_2_rounded,  label: 'Package'),
    (icon: Icons.fastfood_rounded,     label: 'Food'),
    (icon: Icons.devices_rounded,      label: 'Electronics'),
    (icon: Icons.chair_rounded,        label: 'Furniture'),
    (icon: Icons.construction_rounded, label: 'Materials'),
  ];

  static const _weightTiers = [
    (
      label:    'Small',
      range:    '0–5 kg',
      example:  'Documents, food, small parcels',
      vehicles: ['Okada'],
      icon:     Icons.two_wheeler_rounded,
    ),
    (
      label:    'Medium',
      range:    '5–20 kg',
      example:  'Groceries, boxes, electronics',
      vehicles: ['Okada', 'Aboboya'],
      icon:     Icons.inventory_2_rounded,
    ),
    (
      label:    'Large',
      range:    '20–100 kg',
      example:  'Market goods, appliances',
      vehicles: ['Aboboya'],
      icon:     Icons.shopping_cart_rounded,
    ),
    (
      label:    'Bulk',
      range:    '100 kg+',
      example:  'Furniture, construction materials',
      vehicles: ['Mini Truck'],
      icon:     Icons.local_shipping_rounded,
    ),
  ];

  bool get _canProceed =>
      _pickupGeo   != null &&
      _dropoffGeo  != null &&
      _selectedWeight >= 0 &&
      !_uploadingPhoto;

  String get _validationHint {
    if (_pickupGeo   == null) return 'Detecting your pickup location…';
    if (_dropoffGeo  == null) return 'Search and select a drop-off address';
    if (_selectedWeight < 0) return 'Select a weight tier to continue';
    return '';
  }

  @override
  void initState() {
    super.initState();
    _detectPickup();
  }

  @override
  void dispose() {
    _dropoffCtrl.dispose();
    _receiverPhoneCtrl.dispose();
    _receiverNameCtrl.dispose();
    _noteCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // ── GPS pickup ─────────────────────────────────────────────────────────────
  Future<void> _detectPickup() async {
    if (!mounted) return;
    setState(() => _loadingPickup = true);
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever ||
          perm == LocationPermission.denied) {
        throw Exception('Permission denied');
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy:  LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      final marks = await placemarkFromCoordinates(
          pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() {
        _pickupAddress = marks.isNotEmpty
            ? _formatPlacemark(marks.first)
            : 'Current location';
        _pickupGeo = GeoPoint(pos.latitude, pos.longitude);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pickupAddress = 'Current location';
        _pickupGeo     = const GeoPoint(5.6037, -0.1870);
      });
    } finally {
      if (mounted) setState(() => _loadingPickup = false);
    }
  }

  // ── Places API dropoff search ─────────────────────────────────────────────
  void _onDropoffChanged(String value) {
    _debounce?.cancel();
    setState(() {
      _dropoffGeo     = null;
      _dropoffAddress = null;
      _showSuggestions = value.trim().isNotEmpty;
    });

    if (value.trim().isEmpty) {
      setState(() { _suggestions = []; _searchingDropoff = false; });
      return;
    }

    setState(() => _searchingDropoff = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final results = await ref
            .read(placeRepositoryProvider)
            .search(value);
        if (mounted) {
          setState(() {
            _suggestions      = results;
            _searchingDropoff = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _searchingDropoff = false);
      }
    });
  }

  void _selectDropoff(PlaceResult place) {
    setState(() {
      _dropoffAddress  = place.address;
      _dropoffGeo      = place.location;
      _showSuggestions = false;
      _suggestions     = [];
    });
    _dropoffCtrl.text = place.name;
    FocusScope.of(context).unfocus();
  }

  String _formatPlacemark(Placemark p) {
    return [
      if (p.name?.isNotEmpty == true && p.name != p.thoroughfare) p.name,
      if (p.thoroughfare?.isNotEmpty == true) p.thoroughfare,
      if (p.subLocality?.isNotEmpty == true) p.subLocality,
      if (p.locality?.isNotEmpty == true) p.locality,
    ].whereType<String>().take(3).join(', ');
  }

  // ── Photo upload ──────────────────────────────────────────────────────────
  Future<void> _pickPhoto() async {
    final picked = await ImagePicker().pickImage(
      source:       ImageSource.gallery,
      maxWidth:     1024,
      maxHeight:    1024,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    setState(() {
      _photoFile     = File(picked.path);
      _uploadingPhoto = true;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw Exception('Not logged in');

      final ref = FirebaseStorage.instance
          .ref('delivery_photos/$uid/${DateTime.now().millisecondsSinceEpoch}.jpg');

      await ref.putFile(_photoFile!);
      final url = await ref.getDownloadURL();

      if (!mounted) return;
      setState(() { _photoUrl = url; _uploadingPhoto = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _photoFile = null; _photoUrl = null; _uploadingPhoto = false; });
      _snack('Photo upload failed. Try again.');
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:         Text(msg),
      backgroundColor: AppColors.error,
      behavior:        SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin:          const EdgeInsets.all(16),
    ));
  }

  // ── Navigate ──────────────────────────────────────────────────────────────
  void _goToVehicles() {
    HapticFeedback.mediumImpact();
    final tier = _weightTiers[_selectedWeight];
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DeliveryVehicleScreen(
          pickup:           _pickupAddress!,
          pickupGeoPoint:   _pickupGeo!,
          dropoff:          _dropoffAddress!,
          dropoffGeoPoint:  _dropoffGeo!,
          weightTier:       tier.label,
          weightRange:      tier.range,
          eligibleVehicles: tier.vehicles,
          parcelType:       _parcelTypes[_selectedParcel].label,
          isFragile:        _isFragile,
          requiresHelpers:  _requiresHelpers,
          hasPhoto:         _photoUrl != null,
          photoUrl:         _photoUrl,
          receiverPhone:    _receiverPhoneCtrl.text.trim(),
          receiverName:     _receiverNameCtrl.text.trim(),
          notes:            _noteCtrl.text.trim(),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        FocusScope.of(context).unfocus();
        setState(() => _showSuggestions = false);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar:          const CTSRideAppBar(title: 'Send a Parcel'),
        body: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          keyboardDismissBehavior:
              ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildRouteCard(),
              const SizedBox(height: 14),
              _buildSection(
                step:  3,
                title: 'What are you sending?',
                child: _buildParcelTypes(),
              ),
              const SizedBox(height: 14),
              _buildSection(
                step:     4,
                title:    'Approximate weight',
                subtitle: 'Determines which vehicles can carry your delivery',
                child:    _buildWeightTiers(),
              ),
              const SizedBox(height: 14),
              _buildSection(
                step:     5,
                title:    'Photo of items',
                subtitle: 'Helps drivers prepare and verify at pickup',
                child:    _buildPhotoUpload(),
              ),
              const SizedBox(height: 14),
              _buildSection(
                step:  6,
                title: "Receiver's contact",
                child: _buildReceiverFields(),
              ),
              const SizedBox(height: 14),
              _buildSection(
                step:  7,
                title: 'Extra options',
                child: _buildExtraOptions(),
              ),
              const SizedBox(height: 14),
              _buildSection(
                step:  8,
                title: 'Delivery notes',
                child: _inputField(
                  controller: _noteCtrl,
                  hint:       'Any special instructions for the rider…',
                  icon:       Icons.notes_rounded,
                  maxLines:   3,
                ),
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                label: _canProceed
                    ? 'See available vehicles →'
                    : 'Complete required fields',
                onTap:  _canProceed ? _goToVehicles : null,
                color:  _canProceed ? null : AppColors.textTertiary,
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
      ),
    );
  }

  // ── Route card ────────────────────────────────────────────────────────────
  Widget _buildRouteCard() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:        AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border:       Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Pickup
            _buildLocationRow(
              step:    '1',
              label:   'Pickup location',
              child:   GestureDetector(
                onTap: _detectPickup,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color:        AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                    border:       Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      _loadingPickup
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.primary))
                          : const Icon(Icons.my_location_rounded,
                              color: AppColors.success, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _pickupAddress ?? 'Detecting location…',
                          style: TextStyle(
                            fontSize: 13,
                            color:    _pickupAddress != null
                                ? AppColors.textPrimary
                                : AppColors.textTertiary,
                          ),
                        ),
                      ),
                      Text('Change',
                          style: TextStyle(
                            fontSize:   11,
                            fontWeight: FontWeight.w700,
                            color:      AppColors.primary,
                          )),
                    ],
                  ),
                ),
              ),
            ),

            // Connector line
            Padding(
              padding: const EdgeInsets.only(left: 13, top: 6, bottom: 6),
              child:   Container(
                  width: 2, height: 20, color: AppColors.borderLight),
            ),

            // Dropoff with Places API
            _buildLocationRow(
              step:  '2',
              label: 'Drop-off address',
              child: Column(
                children: [
                  // Search input
                  Container(
                    decoration: BoxDecoration(
                      color:        AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border:       Border.all(
                        color: _dropoffGeo != null
                            ? AppColors.primary
                            : AppColors.border,
                        width: _dropoffGeo != null ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: Icon(
                            _dropoffGeo != null
                                ? Icons.check_circle_rounded
                                : Icons.search_rounded,
                            color: _dropoffGeo != null
                                ? AppColors.primary
                                : AppColors.textTertiary,
                            size: 16,
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _dropoffCtrl,
                            onChanged:  _onDropoffChanged,
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.textPrimary),
                            decoration: InputDecoration(
                              hintText:       'Search drop-off address…',
                              hintStyle:      TextStyle(
                                fontSize:     13,
                                color:        AppColors.textTertiary,
                                fontStyle:    FontStyle.italic,
                              ),
                              border:         InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 12),
                            ),
                          ),
                        ),
                        if (_searchingDropoff)
                          const Padding(
                            padding: EdgeInsets.only(right: 10),
                            child:   SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color:       AppColors.primary,
                              ),
                            ),
                          )
                        else if (_dropoffCtrl.text.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              _dropoffCtrl.clear();
                              setState(() {
                                _dropoffGeo     = null;
                                _dropoffAddress = null;
                                _suggestions    = [];
                                _showSuggestions = false;
                              });
                            },
                            child: const Padding(
                              padding: EdgeInsets.only(right: 10),
                              child:   Icon(Icons.clear_rounded,
                                  color: AppColors.textTertiary, size: 16),
                            ),
                          ),
                      ],
                    ),
                  ),

                  // Suggestions dropdown
                  if (_showSuggestions && _suggestions.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      decoration: BoxDecoration(
                        color:        AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border:       Border.all(color: AppColors.border),
                        boxShadow: [
                          BoxShadow(
                            color:      Colors.black.withValues(alpha: 0.06),
                            blurRadius: 8,
                            offset:     const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        children: _suggestions.take(5).map((p) {
                          final isLast = p == _suggestions.take(5).last;
                          return Column(
                            children: [
                              InkWell(
                                onTap:        () => _selectDropoff(p),
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 10),
                                  child: Row(
                                    children: [
                                      Container(
                                        width:  28, height: 28,
                                        decoration: BoxDecoration(
                                          color: AppColors.primaryDim,
                                          borderRadius:
                                              BorderRadius.circular(7),
                                        ),
                                        child: Icon(p.icon,
                                            size:  14,
                                            color: AppColors.primary),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(p.name,
                                                style: const TextStyle(
                                                  fontSize:   12,
                                                  fontWeight: FontWeight.w600,
                                                  color:      AppColors.textPrimary,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis),
                                            Text(p.address,
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color:    AppColors.textTertiary,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (!isLast)
                                const Divider(
                                    height: 0.5,
                                    indent: 50,
                                    color: AppColors.border),
                            ],
                          );
                        }).toList(),
                      ),
                    ),

                  // Confirmed address
                  if (_dropoffAddress != null && _dropoffGeo != null) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.check_circle_rounded,
                          color: AppColors.success, size: 13),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_dropoffAddress!,
                            style: const TextStyle(
                              fontSize:   11,
                              fontWeight: FontWeight.w600,
                              color:      AppColors.success,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  Widget _buildLocationRow({
    required String step,
    required String label,
    required Widget child,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepCircle(step),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTextStyles.labelLarge),
                const SizedBox(height: 8),
                child,
              ],
            ),
          ),
        ],
      );

  // ── Section wrapper ───────────────────────────────────────────────────────
  Widget _buildSection({
    required int    step,
    required String title,
    String?         subtitle,
    required Widget child,
  }) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:        AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border:       Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StepCircle('$step'),
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

  // ── Parcel types ──────────────────────────────────────────────────────────
  Widget _buildParcelTypes() => Wrap(
        spacing: 8, runSpacing: 8,
        children: List.generate(_parcelTypes.length, (i) {
          final p          = _parcelTypes[i];
          final isSelected = _selectedParcel == i;
          return GestureDetector(
            onTap: () => setState(() => _selectedParcel = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primary.withValues(alpha: 0.1)
                    : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? AppColors.primary : AppColors.border,
                  width: isSelected ? 1.5 : 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(p.icon,
                      size:  15,
                      color: isSelected
                          ? AppColors.primary
                          : AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Text(p.label,
                      style: TextStyle(
                        fontFamily:  'Inter',
                        fontSize:    12,
                        fontWeight:  isSelected
                            ? FontWeight.w700 : FontWeight.w400,
                        color: isSelected
                            ? AppColors.primary : AppColors.textSecondary,
                      )),
                ],
              ),
            ),
          );
        }),
      );

  // ── Weight tiers ──────────────────────────────────────────────────────────
  Widget _buildWeightTiers() => Column(
        children: List.generate(_weightTiers.length, (i) {
          final t          = _weightTiers[i];
          final isSelected = _selectedWeight == i;
          return GestureDetector(
            onTap: () => setState(() => _selectedWeight = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin:  const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primary.withValues(alpha: 0.07)
                    : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected
                      ? AppColors.primary : AppColors.border,
                  width: isSelected ? 1.5 : 0.5,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width:  38, height: 38,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary.withValues(alpha: 0.12)
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(t.icon,
                        color: isSelected
                            ? AppColors.primary : AppColors.textSecondary,
                        size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Text(t.label,
                              style: TextStyle(
                                fontFamily:  'Inter',
                                fontSize:    13,
                                fontWeight:  FontWeight.w700,
                                color: isSelected
                                    ? AppColors.primary : AppColors.textPrimary,
                              )),
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
                            child: Text(t.range,
                                style: TextStyle(
                                  fontFamily:  'Inter',
                                  fontSize:    10,
                                  fontWeight:  FontWeight.w700,
                                  color: isSelected
                                      ? AppColors.primary : AppColors.textSecondary,
                                )),
                          ),
                        ]),
                        const SizedBox(height: 2),
                        Text(t.example,
                            style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: t.vehicles.map((v) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(v,
                          style: TextStyle(
                            fontSize: 10,
                            color:    isSelected
                                ? AppColors.primary : AppColors.textTertiary,
                          )),
                    )).toList(),
                  ),
                ],
              ),
            ),
          );
        }),
      );

  // ── Photo upload ──────────────────────────────────────────────────────────
  Widget _buildPhotoUpload() => GestureDetector(
        onTap: _uploadingPhoto ? null : _pickPhoto,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width:  double.infinity,
          height: 100,
          decoration: BoxDecoration(
            color: _photoUrl != null
                ? AppColors.primary.withValues(alpha: 0.06)
                : AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _photoUrl != null
                  ? AppColors.primary : AppColors.border,
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
                        style: TextStyle(
                          fontSize: 12,
                          color:    AppColors.textSecondary,
                        )),
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
                              color: Colors.black.withValues(alpha: 0.35)),
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
                        const Text('Add photo of items',
                            style: TextStyle(
                              fontSize:   13,
                              fontWeight: FontWeight.w600,
                              color:      AppColors.textSecondary,
                            )),
                        const SizedBox(height: 2),
                        Text('Optional — helps driver verify at pickup',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppColors.textTertiary)),
                      ],
                    ),
        ),
      );

  // ── Receiver fields ───────────────────────────────────────────────────────
  Widget _buildReceiverFields() => Column(
        children: [
          _inputField(
            controller:   _receiverPhoneCtrl,
            hint:         '+233 — Receiver phone number',
            icon:         Icons.phone_rounded,
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 10),
          _inputField(
            controller: _receiverNameCtrl,
            hint:       "Receiver's name (optional)",
            icon:       Icons.person_rounded,
          ),
        ],
      );

  // ── Extra options ─────────────────────────────────────────────────────────
  Widget _buildExtraOptions() => Column(
        children: [
          _ToggleRow(
            icon:      Icons.broken_image_rounded,
            label:     'Fragile item',
            subtitle:  '+GHS 5.00 handling fee',
            value:     _isFragile,
            onChanged: (v) => setState(() => _isFragile = v),
          ),
          const SizedBox(height: 10),
          _ToggleRow(
            icon:      Icons.people_rounded,
            label:     'Requires loading helpers',
            subtitle:  '+GHS 10.00 (Aboboya / Mini Truck only)',
            value:     _requiresHelpers,
            onChanged: (v) => setState(() => _requiresHelpers = v),
          ),
        ],
      );

  Widget _inputField({
    TextEditingController? controller,
    required String        hint,
    required IconData      icon,
    TextInputType?         keyboardType,
    int                    maxLines = 1,
    ValueChanged<String>?  onChanged,
  }) =>
      Container(
        decoration: BoxDecoration(
          color:        AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border:       Border.all(color: AppColors.border),
        ),
        child: TextField(
          controller:   controller,
          keyboardType: keyboardType,
          maxLines:     maxLines,
          onChanged:    onChanged,
          style: const TextStyle(
              fontSize: 13, color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText:  hint,
            hintStyle: const TextStyle(
              fontSize:  13,
              color:     AppColors.textTertiary,
              fontStyle: FontStyle.italic,
            ),
            prefixIcon: Icon(icon,
                color: AppColors.textSecondary, size: 18),
            border:         InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 12),
          ),
        ),
      );
}

// ── Step circle ───────────────────────────────────────────────────────────────
class _StepCircle extends StatelessWidget {
  final String number;
  const _StepCircle(this.number);

  @override
  Widget build(BuildContext context) => Container(
        width:  26, height: 26,
        decoration: const BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Text(number,
              style: const TextStyle(
                fontFamily:  'Inter',
                fontSize:    11,
                fontWeight:  FontWeight.w800,
                color:       Colors.white,
              )),
        ),
      );
}

// ── Toggle row ────────────────────────────────────────────────────────────────
class _ToggleRow extends StatelessWidget {
  final IconData       icon;
  final String         label;
  final String         subtitle;
  final bool           value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
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
                size:  18,
                color: value ? AppColors.primary : AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                        fontFamily:  'Inter',
                        fontSize:    13,
                        fontWeight:  FontWeight.w600,
                        color: value
                            ? AppColors.primary : AppColors.textPrimary,
                      )),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary)),
                ],
              ),
            ),
            Switch.adaptive(
              value:       value,
              onChanged:   onChanged,
              activeColor: AppColors.primary,
            ),
          ],
        ),
      );
}
