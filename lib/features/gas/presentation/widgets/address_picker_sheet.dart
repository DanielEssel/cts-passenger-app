// lib/features/gas/presentation/widgets/address_picker_sheet.dart
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../ride/models/place_result.dart';
import '../../../ride/repositories/google_places_repository.dart';

// ── Brand tokens ──────────────────────────────────────────────────────────────
const _kPrimary     = AppColors.primary;
const _kPrimaryDim  = AppColors.primaryDim;
const _kBg          = AppColors.background;
const _kSurface     = AppColors.surface;
const _kBorder      = AppColors.border;
const _kTextPrimary = AppColors.textPrimary;
const _kTextSecond  = AppColors.textSecondary;
const _kTextTert    = AppColors.textTertiary;
const _kError       = AppColors.error;
const _kErrorLight  = AppColors.errorLight;

/// Returns `{'address': String, 'location': GeoPoint}` or null if dismissed.
class AddressPickerSheet extends ConsumerStatefulWidget {
  final String? title;
  final String? subtitle;

  const AddressPickerSheet({
    super.key,
    this.title,
    this.subtitle,
  });

  @override
  ConsumerState<AddressPickerSheet> createState() =>
      _AddressPickerSheetState();
}

class _AddressPickerSheetState extends ConsumerState<AddressPickerSheet> {
  final _searchCtrl  = TextEditingController();
  final _focusNode   = FocusNode();
  final _scrollCtrl  = ScrollController();

  // ── State ─────────────────────────────────────────────────────────────────
  List<PlaceResult> _suggestions  = [];
  bool              _isSearching  = false;
  bool              _isLocating   = false;
  String?           _locatedAddr;
  GeoPoint?         _locatedGeo;
  String?           _error;
  Timer?            _debounce;

  static const _savedPlaces = [
    (
      label:    'Home',
      address:  'East Legon, Accra',
      icon:     Icons.home_rounded,
      geo:      GeoPoint(5.6365, -0.1542),
    ),
    (
      label:    'Work',
      address:  'Airport City, Accra',
      icon:     Icons.work_rounded,
      geo:      GeoPoint(5.6037, -0.1870),
    ),
  ];

  @override
  void dispose() {
    _searchCtrl.dispose();
    _focusNode.dispose();
    _scrollCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // ── Search ─────────────────────────────────────────────────────────────────
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() { _suggestions = []; _isSearching = false; });
      return;
    }
    setState(() => _isSearching = true);
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(value));
  }

  Future<void> _search(String query) async {
    try {
      final repo    = ref.read(placeRepositoryProvider);
      final results = await repo.search(query);
      if (mounted) setState(() { _suggestions = results; _isSearching = false; });
    } catch (_) {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  // ── GPS ────────────────────────────────────────────────────────────────────
  Future<void> _detectLocation() async {
    setState(() { _isLocating = true; _error = null; _locatedAddr = null; });
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        throw Exception('Location permission denied. Enable it in Settings.');
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception('Location services are off. Please enable GPS.');
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy:  LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      final marks = await placemarkFromCoordinates(
          pos.latitude, pos.longitude);
      if (marks.isEmpty) throw Exception('Unable to determine address.');

      final p    = marks.first;
      final addr = [
        if (p.name?.isNotEmpty == true && p.name != p.thoroughfare) p.name,
        if (p.thoroughfare?.isNotEmpty == true) p.thoroughfare,
        if (p.subLocality?.isNotEmpty == true) p.subLocality,
        if (p.locality?.isNotEmpty == true) p.locality,
      ].whereType<String>().take(3).join(', ');

      setState(() {
        _locatedAddr = addr;
        _locatedGeo  = GeoPoint(pos.latitude, pos.longitude);
        _isLocating  = false;
      });
    } catch (e) {
      setState(() {
        _error      = e.toString().replaceFirst('Exception: ', '');
        _isLocating = false;
      });
    }
  }

  // ── Confirm ────────────────────────────────────────────────────────────────
  void _confirm(String address, GeoPoint geo) {
    Navigator.pop(context, {'address': address, 'location': geo});
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final bottomPad   = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color:        _kSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Handle ──
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color:        _kBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title ?? 'Select Delivery Address',
                    style: const TextStyle(
                      fontSize:   20,
                      fontWeight: FontWeight.w800,
                      color:      _kTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.subtitle ?? 'Where should we deliver your gas?',
                    style: const TextStyle(
                        fontSize: 13, color: _kTextSecond),
                  ),
                ],
              ),
            ),

            // ── Search bar ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Container(
                decoration: BoxDecoration(
                  color:        _kBg,
                  borderRadius: BorderRadius.circular(14),
                  border:       Border.all(color: _kBorder),
                ),
                child: Row(
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(left: 14),
                      child: Icon(Icons.search_rounded,
                          color: _kTextTert, size: 20),
                    ),
                    Expanded(
                      child: TextField(
                        controller:     _searchCtrl,
                        focusNode:      _focusNode,
                        onChanged:      _onSearchChanged,
                        textInputAction: TextInputAction.search,
                        style: const TextStyle(
                            fontSize: 14, color: _kTextPrimary),
                        decoration: const InputDecoration(
                          hintText:        'Search address or landmark...',
                          hintStyle:       TextStyle(
                              fontSize: 14, color: _kTextTert),
                          border:          InputBorder.none,
                          contentPadding:  EdgeInsets.symmetric(
                              horizontal: 12, vertical: 14),
                        ),
                      ),
                    ),
                    if (_searchCtrl.text.isNotEmpty)
                      IconButton(
                        icon:      const Icon(Icons.clear_rounded,
                            color: _kTextTert, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() {
                            _suggestions = [];
                            _isSearching = false;
                          });
                        },
                      ),
                    if (_isSearching)
                      const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2, color: _kPrimary),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // ── Scrollable content ──
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: ListView(
                controller:  _scrollCtrl,
                shrinkWrap:  true,
                padding:     EdgeInsets.fromLTRB(
                    20, 0, 20, bottomPad + 16),
                children: [
                  // Search results
                  if (_suggestions.isNotEmpty) ...[
                    _SectionLabel('RESULTS'),
                    const SizedBox(height: 8),
                    ..._suggestions.map((p) => _PlaceTile(
                          icon:    p.icon,
                          title:   p.name,
                          subtitle: p.address,
                          onTap:   () => _confirm(p.address, p.location),
                        )),
                    const SizedBox(height: 16),
                  ],

                  // GPS button
                  if (_suggestions.isEmpty) ...[
                    _GpsButton(
                      isLoading: _isLocating,
                      onTap:     _detectLocation,
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Detected location card
                  if (_locatedAddr != null && _locatedGeo != null) ...[
                    _DetectedCard(
                      address: _locatedAddr!,
                      onConfirm: () =>
                          _confirm(_locatedAddr!, _locatedGeo!),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Error
                  if (_error != null) ...[
                    _ErrorCard(message: _error!),
                    const SizedBox(height: 16),
                  ],

                  // Saved places — shown when not searching
                  if (_suggestions.isEmpty && _searchCtrl.text.isEmpty) ...[
                    _SectionLabel('SAVED PLACES'),
                    const SizedBox(height: 8),
                    ..._savedPlaces.map((s) => _PlaceTile(
                          icon:    s.icon,
                          title:   s.label,
                          subtitle: s.address,
                          onTap:   () => _confirm(s.address, s.geo),
                        )),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── GPS button ────────────────────────────────────────────────────────────────
class _GpsButton extends StatelessWidget {
  final bool         isLoading;
  final VoidCallback onTap;
  const _GpsButton({required this.isLoading, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color:        Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap:        isLoading ? null : onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color:        _kPrimaryDim,
              borderRadius: BorderRadius.circular(14),
              border:       Border.all(
                  color: _kPrimary.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Container(
                  width:  40, height: 40,
                  decoration: BoxDecoration(
                    color:  _kPrimary,
                    shape:  BoxShape.circle,
                  ),
                  child: isLoading
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child:   CircularProgressIndicator(
                            strokeWidth: 2,
                            color:       Colors.white,
                          ),
                        )
                      : const Icon(Icons.my_location_rounded,
                          color: Colors.white, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Use Current Location',
                          style: TextStyle(
                            fontSize:   14,
                            fontWeight: FontWeight.w700,
                            color:      _kTextPrimary,
                          )),
                      Text(
                        isLoading
                            ? 'Detecting your location...'
                            : 'Tap to detect via GPS',
                        style: const TextStyle(
                            fontSize: 12, color: _kTextSecond),
                      ),
                    ],
                  ),
                ),
                if (!isLoading)
                  const Icon(Icons.chevron_right_rounded,
                      color: _kTextTert),
              ],
            ),
          ),
        ),
      );
}

// ── Detected address card ─────────────────────────────────────────────────────
class _DetectedCard extends StatelessWidget {
  final String       address;
  final VoidCallback onConfirm;
  const _DetectedCard({required this.address, required this.onConfirm});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color:        _kPrimaryDim,
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(
              color: _kPrimary.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.check_circle_rounded,
                  color: _kPrimary, size: 16),
              const SizedBox(width: 8),
              const Text('Location Detected',
                  style: TextStyle(
                    fontSize:   12,
                    fontWeight: FontWeight.w700,
                    color:      _kPrimary,
                  )),
            ]),
            const SizedBox(height: 8),
            Text(address,
                style: const TextStyle(
                  fontSize: 13, color: _kTextPrimary)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onConfirm,
                style: FilledButton.styleFrom(
                  backgroundColor: _kPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Confirm This Address',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
              ),
            ),
          ],
        ),
      );
}

// ── Error card ────────────────────────────────────────────────────────────────
class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard({required this.message});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color:        _kErrorLight,
          borderRadius: BorderRadius.circular(12),
          border:       Border.all(
              color: _kError.withValues(alpha: 0.3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: _kError, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: const TextStyle(
                      fontSize: 12, color: _kError)),
            ),
          ],
        ),
      );
}

// ── Place tile ────────────────────────────────────────────────────────────────
class _PlaceTile extends StatelessWidget {
  final IconData     icon;
  final String       title;
  final String       subtitle;
  final VoidCallback onTap;
  const _PlaceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
        color:        Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap:        onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Container(
                  width:  38, height: 38,
                  decoration: BoxDecoration(
                    color:        _kPrimaryDim,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: _kPrimary, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                            fontSize:   13,
                            fontWeight: FontWeight.w600,
                            color:      _kTextPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 11, color: _kTextTert),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: _kTextTert, size: 18),
              ],
            ),
          ),
        ),
      );
}

// ── Section label ─────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize:      10,
          fontWeight:    FontWeight.w700,
          color:         _kTextTert,
          letterSpacing: 1,
        ),
      );
}
