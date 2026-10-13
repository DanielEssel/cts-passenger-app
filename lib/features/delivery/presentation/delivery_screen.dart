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
import '../../../core/theme/cts_theme.dart';
import '../../../core/widgets/cts_ui.dart';
import '../../ride/models/place_result.dart';
import '../../ride/repositories/google_places_repository.dart';
import '../domain/delivery_form_validator.dart';
import 'delivery_vehicle_screen.dart';
import 'widgets/extra_options.dart';
import 'widgets/receiver_section.dart';

// ── Delivery screen ───────────────────────────────────────────────────────────
class DeliveryScreen extends ConsumerStatefulWidget {
  const DeliveryScreen({super.key});

  @override
  ConsumerState<DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends ConsumerState<DeliveryScreen> {
  // ── Controllers ───────────────────────────────────────────────────────────
  final _dropoffCtrl = TextEditingController();
  final _receiverPhoneCtrl = TextEditingController();
  final _receiverNameCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  // ── Pickup state ──────────────────────────────────────────────────────────
  String? _pickupAddress;
  GeoPoint? _pickupGeo;
  bool _loadingPickup = false;

  // ── Dropoff state (Places API) ────────────────────────────────────────────
  String? _dropoffAddress;
  GeoPoint? _dropoffGeo;
  bool _searchingDropoff = false;
  List<PlaceResult> _suggestions = [];
  Timer? _debounce;
  bool _showSuggestions = false;

  // ── Form state ─────────────────────────────────────────────────────────────
  int _selectedParcel = 0;
  int _selectedWeight = -1;
  bool _isFragile = false;
  bool _requiresHelpers = false;
  File? _photoFile;
  String? _photoUrl;
  bool _uploadingPhoto = false;

  // True while the vehicle screen is open, so a double tap can't push twice.
  bool _navigating = false;

  // ── Inline validation errors ────────────────────────────────────────────
  String? _phoneError;
  String? _nameError;

  static const _parcelTypes = [
    (icon: Icons.description_rounded, label: 'Documents'),
    (icon: Icons.inventory_2_rounded, label: 'Package'),
    (icon: Icons.fastfood_rounded, label: 'Food'),
    (icon: Icons.devices_rounded, label: 'Electronics'),
    (icon: Icons.chair_rounded, label: 'Furniture'),
    (icon: Icons.construction_rounded, label: 'Materials'),
  ];

  static const _weightTiers = [
    (
      label: 'Small',
      range: '0–5 kg',
      example: 'Documents, food, small parcels',
      vehicles: ['Okada'],
      icon: Icons.two_wheeler_rounded,
    ),
    (
      label: 'Medium',
      range: '5–20 kg',
      example: 'Groceries, boxes, electronics',
      vehicles: ['Okada', 'Aboboya'],
      icon: Icons.inventory_2_rounded,
    ),
    (
      label: 'Large',
      range: '20–100 kg',
      example: 'Market goods, appliances',
      vehicles: ['Aboboya'],
      icon: Icons.shopping_cart_rounded,
    ),
    (
      label: 'Bulk',
      range: '100 kg+',
      example: 'Furniture, construction materials',
      vehicles: ['Mini Truck'],
      icon: Icons.local_shipping_rounded,
    ),
  ];

  /// First blocking problem, or null when the form may proceed. Single
  /// source of truth for both the button's enabled state and its hint.
  String? get _blockingError => DeliveryFormValidator.firstError(
        pickup: _pickupGeo,
        dropoff: _dropoffGeo,
        selectedWeight: _selectedWeight,
        phone: _receiverPhoneCtrl.text,
        name: _receiverNameCtrl.text,
        noteText: _noteCtrl.text,
        uploadingPhoto: _uploadingPhoto,
      );

  bool get _canProceed => _blockingError == null;

  String get _validationHint => _blockingError ?? '';

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
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      final marks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() {
        _pickupAddress = marks.isNotEmpty
            ? _formatPlacemark(marks.first)
            : 'Current location';
        _pickupGeo = GeoPoint(pos.latitude, pos.longitude);
      });
    } catch (_) {
      if (!mounted) return;
      // Never invent a location — a fabricated pickup dispatches a driver to
      // the wrong place. Leave it unset and let the user retry via the row.
      setState(() {
        _pickupAddress = null;
        _pickupGeo = null;
      });
      _snack('Couldn\'t detect your location. Tap pickup to retry.');
    } finally {
      if (mounted) setState(() => _loadingPickup = false);
    }
  }

  // ── Places API dropoff search ─────────────────────────────────────────────
  void _onDropoffChanged(String value) {
    _debounce?.cancel();
    setState(() {
      _dropoffGeo = null;
      _dropoffAddress = null;
      _showSuggestions = value.trim().isNotEmpty;
    });

    if (value.trim().isEmpty) {
      setState(() {
        _suggestions = [];
        _searchingDropoff = false;
      });
      return;
    }

    setState(() => _searchingDropoff = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final results = await ref.read(placeRepositoryProvider).search(value);
        if (mounted) {
          setState(() {
            _suggestions = results;
            _searchingDropoff = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _searchingDropoff = false);
      }
    });
  }

  void _selectDropoff(PlaceResult place) {
    // Reject a destination that's the same place as pickup, at tap time —
    // clearer and earlier than the submit-gate message. `route` still backstops.
    if (DeliveryFormValidator.isSameAsPickup(_pickupGeo, place.location)) {
      setState(() {
        _showSuggestions = false;
        _suggestions = [];
      });
      _dropoffCtrl.clear();
      FocusScope.of(context).unfocus();
      _snack('Choose a destination different from your pickup location.');
      return;
    }

    setState(() {
      _dropoffAddress = place.address;
      _dropoffGeo = place.location;
      _showSuggestions = false;
      _suggestions = [];
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
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    setState(() {
      _photoFile = File(picked.path);
      _uploadingPhoto = true;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw Exception('Not logged in');

      final ref = FirebaseStorage.instance.ref(
          'delivery_photos/$uid/${DateTime.now().millisecondsSinceEpoch}.jpg');

      await ref.putFile(_photoFile!);
      final url = await ref.getDownloadURL();

      if (!mounted) return;
      setState(() {
        _photoUrl = url;
        _uploadingPhoto = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _photoFile = null;
        _photoUrl = null;
        _uploadingPhoto = false;
      });
      _snack('Photo upload failed. Try again.');
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AppColors.error,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  // ── Navigate ──────────────────────────────────────────────────────────────
  void _goToVehicles() {
    if (_navigating) return;
    // Final gate — never trust the button's enabled state alone.
    final err = _blockingError;
    if (err != null) {
      _snack(err);
      return;
    }
    HapticFeedback.mediumImpact();
    // Unfocus the field itself (not just the scope) so returning from the
    // vehicle screen doesn't reopen the keyboard.
    FocusManager.instance.primaryFocus?.unfocus();
    final tier = _weightTiers[_selectedWeight];
    _navigating = true;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DeliveryVehicleScreen(
          pickup: _pickupAddress!,
          pickupGeoPoint: _pickupGeo!,
          dropoff: _dropoffAddress!,
          dropoffGeoPoint: _dropoffGeo!,
          weightTier: tier.label,
          weightRange: tier.range,
          eligibleVehicles: tier.vehicles,
          parcelType: _parcelTypes[_selectedParcel].label,
          isFragile: _isFragile,
          requiresHelpers: _requiresHelpers,
          hasPhoto: _photoUrl != null,
          photoUrl: _photoUrl,
          receiverPhone:
              DeliveryFormValidator.normalizePhone(_receiverPhoneCtrl.text),
          receiverName: _receiverNameCtrl.text.trim(),
          notes: _noteCtrl.text.trim(),
        ),
      ),
    ).whenComplete(() => _navigating = false);
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  // Layout: light service header, one scrolling form grouped as the journey
  // reads (route → parcel → weight → receiver → extras → photo → note), and a
  // fixed bottom bar with the next step. The bar sits above the keyboard.
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: GestureDetector(
        onTap: () {
          FocusScope.of(context).unfocus();
          setState(() => _showSuggestions = false);
        },
        child: Scaffold(
          backgroundColor: CtsTheme.background,
          body: Column(
            children: [
              const CtsServiceHeader(
                title: 'Send a parcel',
                subtitle: 'Picked up and delivered across town',
              ),
              Expanded(
                child: ListView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding:
                      const EdgeInsets.fromLTRB(ctsGutter, 6, ctsGutter, 24),
                  children: [
                    _buildRouteCard(),
                    _gap,
                    const CtsSectionHeader('What are you sending?'),
                    _buildParcelTypes(),
                    _gap,
                    const CtsSectionHeader('How heavy is it?',
                        caption: 'This decides which vehicles can carry it'),
                    _buildWeightTiers(),
                    _gap,
                    const CtsSectionHeader('Receiver'),
                    ReceiverSection(
                      phoneController: _receiverPhoneCtrl,
                      nameController: _receiverNameCtrl,
                      phoneError: _phoneError,
                      nameError: _nameError,
                      onPhoneChanged: (v) => setState(() {
                        _phoneError = v.trim().isEmpty
                            ? null
                            : DeliveryFormValidator.receiverPhone(v);
                      }),
                      onNameChanged: (v) => setState(() {
                        _nameError = DeliveryFormValidator.receiverName(v);
                      }),
                    ),
                    _gap,
                    const CtsSectionHeader('Extras'),
                    ExtraOptions(
                      isFragile: _isFragile,
                      requiresHelpers: _requiresHelpers,
                      onFragileChanged: (v) => setState(() => _isFragile = v),
                      onHelpersChanged: (v) =>
                          setState(() => _requiresHelpers = v),
                      selectedTierVehicles: _selectedWeight >= 0
                          ? _weightTiers[_selectedWeight].vehicles
                          : null,
                    ),
                    _gap,
                    const CtsSectionHeader('Photo of items',
                        caption:
                            'Optional · helps the rider confirm the items'),
                    _buildPhotoUpload(),
                    _gap,
                    CtsTextField(
                      controller: _noteCtrl,
                      label: 'Note for the rider',
                      optional: true,
                      hint: 'Gate code, landmark, handling instructions…',
                      icon: Icons.notes_rounded,
                      maxLines: 3,
                      maxLength: DeliveryFormValidator.notesMaxLength,
                      textCapitalization: TextCapitalization.sentences,
                      errorText: DeliveryFormValidator.notes(_noteCtrl.text),
                      helperText:
                          '${_noteCtrl.text.length}/${DeliveryFormValidator.notesMaxLength}',
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
              ),
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  static const Widget _gap = SizedBox(height: 22);

  // ── Bottom bar: what's missing + next step ────────────────────────────────
  Widget _buildBottomBar() => Container(
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
                if (!_canProceed) ...[
                  Semantics(
                    liveRegion: true,
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded,
                            size: 16, color: CtsTheme.textSecondary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _validationHint,
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
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                CtsPrimaryButton(
                  label: 'See vehicles & prices',
                  icon: Icons.local_shipping_rounded,
                  onPressed: _canProceed ? _goToVehicles : null,
                ),
              ],
            ),
          ),
        ),
      );

  // ── Route card: pickup → drop-off ─────────────────────────────────────────
  Widget _buildRouteCard() {
    final pickupText = _pickupAddress ??
        (_loadingPickup
            ? 'Finding your location…'
            : 'Location unavailable. Tap to try again.');
    final query = _dropoffCtrl.text.trim();
    final noMatches = _showSuggestions &&
        query.isNotEmpty &&
        !_searchingDropoff &&
        _suggestions.isEmpty &&
        _dropoffGeo == null;

    return Container(
      decoration: BoxDecoration(
        color: CtsTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: CtsTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Pickup — GPS. Tapping re-detects the current location.
          Semantics(
            button: true,
            label: 'Pickup, $pickupText. Detect current location again',
            excludeSemantics: true,
            onTap: _loadingPickup ? null : _detectPickup,
            child: InkWell(
              onTap: _loadingPickup ? null : _detectPickup,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child: _RouteDot(filled: false),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Pickup · your current location',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: CtsTheme.textSecondary,
                              )),
                          const SizedBox(height: 2),
                          Text(
                            pickupText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14.5,
                              fontWeight: _pickupAddress != null
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: _pickupAddress != null
                                  ? CtsTheme.textPrimary
                                  : CtsTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: _loadingPickup
                          ? const Padding(
                              padding: EdgeInsets.all(3),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: CtsTheme.primary),
                            )
                          : const Icon(Icons.my_location_rounded,
                              size: 20, color: CtsTheme.primaryDeep),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 38),
            child: Divider(height: 1, color: CtsTheme.border),
          ),

          // Drop-off — Places search
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: _RouteDot(filled: true),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Drop-off',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: CtsTheme.textSecondary,
                          )),
                      TextField(
                        controller: _dropoffCtrl,
                        onChanged: _onDropoffChanged,
                        textInputAction: TextInputAction.search,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: CtsTheme.textPrimary,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Search a street, landmark or area',
                          hintStyle: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w500,
                            color: CtsTheme.textTertiary,
                          ),
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding: EdgeInsets.symmetric(vertical: 6),
                        ),
                      ),
                      if (_dropoffAddress != null && _dropoffGeo != null)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 1),
                              child: Icon(Icons.check_circle_rounded,
                                  color: CtsTheme.primaryDeep, size: 15),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(_dropoffAddress!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: CtsTheme.textSecondary,
                                  )),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 44,
                  height: 44,
                  child: _searchingDropoff
                      ? const Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: CtsTheme.primary),
                          ),
                        )
                      : _dropoffCtrl.text.isNotEmpty
                          ? IconButton(
                              tooltip: 'Clear drop-off',
                              icon: const Icon(Icons.close_rounded,
                                  size: 19, color: CtsTheme.textSecondary),
                              onPressed: () {
                                _dropoffCtrl.clear();
                                setState(() {
                                  _dropoffGeo = null;
                                  _dropoffAddress = null;
                                  _suggestions = [];
                                  _showSuggestions = false;
                                });
                              },
                            )
                          : const Icon(Icons.search_rounded,
                              size: 20, color: CtsTheme.textTertiary),
                ),
              ],
            ),
          ),

          // Suggestions from the Places search
          if (_showSuggestions && _suggestions.isNotEmpty) ...[
            const Divider(height: 1, color: CtsTheme.border),
            for (final p in _suggestions.take(5))
              InkWell(
                onTap: () => _selectDropoff(p),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: CtsTheme.surfaceAlt,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(p.icon,
                              size: 16, color: CtsTheme.textSecondary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: CtsTheme.textPrimary,
                                  )),
                              Text(p.address,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: CtsTheme.textSecondary,
                                  )),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
          if (noMatches) ...[
            const Divider(height: 1, color: CtsTheme.border),
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Icon(Icons.search_off_rounded,
                      size: 18, color: CtsTheme.textSecondary),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No matches. Try a street, landmark or area name.',
                      style: TextStyle(
                          fontSize: 12.5, color: CtsTheme.textSecondary),
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

  // ── Parcel types ──────────────────────────────────────────────────────────
  Widget _buildParcelTypes() => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < _parcelTypes.length; i++)
            CtsChoicePill(
              label: _parcelTypes[i].label,
              icon: _parcelTypes[i].icon,
              selected: _selectedParcel == i,
              onTap: () => setState(() => _selectedParcel = i),
            ),
        ],
      );

  // ── Weight tiers ──────────────────────────────────────────────────────────
  Widget _buildWeightTiers() => Column(
        children: [
          for (var i = 0; i < _weightTiers.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _weightTile(i),
          ],
        ],
      );

  Widget _weightTile(int i) {
    final t = _weightTiers[i];
    final isSelected = _selectedWeight == i;
    return CtsSelectableCard(
      selected: isSelected,
      showCheck: false,
      semanticLabel:
          '${t.label}, ${t.range}. ${t.example}. Vehicles: ${t.vehicles.join(', ')}',
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      onTap: () => setState(() {
        _selectedWeight = i;
        // If this tier can't carry helpers, clear a stale toggle so a
        // helpers fee never rides along on an Okada-only delivery.
        if (!DeliveryFormValidator.helpersAllowedForTier(t.vehicles)) {
          _requiresHelpers = false;
        }
      }),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: isSelected ? CtsTheme.surface : CtsTheme.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(t.icon,
                size: 20,
                color:
                    isSelected ? CtsTheme.primaryDeep : CtsTheme.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(t.label,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: CtsTheme.textPrimary,
                        )),
                    Text(t.range,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: CtsTheme.primaryDeep,
                        )),
                  ],
                ),
                const SizedBox(height: 2),
                Text(t.example,
                    style: const TextStyle(
                        fontSize: 12, color: CtsTheme.textSecondary)),
                const SizedBox(height: 2),
                Text('Vehicles: ${t.vehicles.join(', ')}',
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: CtsTheme.textTertiary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _RadioDot(selected: isSelected),
        ],
      ),
    );
  }

  // ── Photo upload ──────────────────────────────────────────────────────────
  Widget _buildPhotoUpload() {
    final hasPhoto = _photoUrl != null && _photoFile != null;
    final title = _uploadingPhoto
        ? 'Uploading photo…'
        : hasPhoto
            ? 'Photo added'
            : 'Add a photo';
    final subtitle = _uploadingPhoto
        ? 'Please wait before continuing'
        : hasPhoto
            ? 'Tap to choose a different photo'
            : 'From your gallery';
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      onTap: _uploadingPhoto ? null : _pickPhoto,
      child: Material(
        color: hasPhoto ? CtsTheme.primaryTint : CtsTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: hasPhoto ? CtsTheme.primary : CtsTheme.border,
            width: hasPhoto ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _uploadingPhoto ? null : _pickPhoto,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 60,
                    height: 60,
                    child: _uploadingPhoto
                        ? const ColoredBox(
                            color: CtsTheme.surfaceAlt,
                            child: Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: CtsTheme.primary),
                              ),
                            ),
                          )
                        : _photoFile != null
                            ? Image.file(_photoFile!,
                                fit: BoxFit.cover, cacheWidth: 180)
                            : const ColoredBox(
                                color: CtsTheme.surfaceAlt,
                                child: Icon(Icons.add_a_photo_rounded,
                                    size: 22, color: CtsTheme.textSecondary),
                              ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: CtsTheme.textPrimary,
                          )),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 12, color: CtsTheme.textSecondary)),
                    ],
                  ),
                ),
                if (!_uploadingPhoto)
                  Text(hasPhoto ? 'Change' : 'Add',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: CtsTheme.primaryDeep,
                      )),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Small pieces ─────────────────────────────────────────────────────────────
class _RouteDot extends StatelessWidget {
  final bool filled;
  const _RouteDot({required this.filled});

  @override
  Widget build(BuildContext context) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: filled ? CtsTheme.primary : CtsTheme.surface,
          shape: BoxShape.circle,
          border: Border.all(color: CtsTheme.primary, width: 2.5),
        ),
      );
}

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
