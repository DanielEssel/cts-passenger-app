// lib/features/gas/presentation/widgets/address_picker_sheet.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import '../../gas/theme/gas_theme.dart';

class AddressPickerSheet extends StatefulWidget {
  const AddressPickerSheet({super.key});

  @override
  State<AddressPickerSheet> createState() => _AddressPickerSheetState();
}

class _AddressPickerSheetState extends State<AddressPickerSheet> {
  final TextEditingController _manualController = TextEditingController();
  final FocusNode             _focusNode        = FocusNode();

  bool     _isLoadingLocation = false;
  String?  _detectedAddress;
  GeoPoint? _detectedGeoPoint;
  String?  _errorMessage;

  final List<_SavedAddress> _recentAddresses = [
    _SavedAddress(
      label:    'Home',
      address:  'East Legon, Accra',
      icon:     Icons.home_rounded,
      geoPoint: const GeoPoint(5.6365, -0.1542),
    ),
    _SavedAddress(
      label:    'Work',
      address:  'Airport City, Accra',
      icon:     Icons.work_rounded,
      geoPoint: const GeoPoint(5.6037, -0.1870),
    ),
  ];

  @override
  void dispose() {
    _manualController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── GPS ──────────────────────────────────────────────────────────────────

  Future<void> _detectCurrentLocation() async {
    setState(() { _isLoadingLocation = true; _errorMessage = null; });

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        throw Exception(
            'Location permission denied. Please enable it in Settings.');
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are disabled. Please turn on GPS.');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy:  LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      final placemarks = await placemarkFromCoordinates(
          position.latitude, position.longitude);
      if (placemarks.isEmpty) throw Exception('Unable to determine address.');

      setState(() {
        _detectedAddress  = _formatPlacemark(placemarks.first);
        _detectedGeoPoint = GeoPoint(position.latitude, position.longitude);
        _isLoadingLocation = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage      = e.toString().replaceFirst('Exception: ', '');
        _isLoadingLocation = false;
      });
    }
  }

  Future<void> _geocodeManualAddress() async {
    final text = _manualController.text.trim();
    if (text.isEmpty) return;

    setState(() { _isLoadingLocation = true; _errorMessage = null; });

    try {
      final locations = await locationFromAddress('$text, Ghana');
      if (locations.isEmpty) {
        throw Exception('Address not found. Try being more specific.');
      }

      final loc       = locations.first;
      final placemarks = await placemarkFromCoordinates(
          loc.latitude, loc.longitude);
      final address   = placemarks.isNotEmpty
          ? _formatPlacemark(placemarks.first)
          : text;

      setState(() {
        _detectedAddress  = address;
        _detectedGeoPoint = GeoPoint(loc.latitude, loc.longitude);
        _isLoadingLocation = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage      = e.toString().replaceFirst('Exception: ', '');
        _isLoadingLocation = false;
      });
    }
  }

  String _formatPlacemark(Placemark p) {
    final parts = <String>[
      if (p.name        != null && p.name!.isNotEmpty &&
          p.name        != p.thoroughfare) p.name!,
      if (p.thoroughfare != null && p.thoroughfare!.isNotEmpty) p.thoroughfare!,
      if (p.subLocality  != null && p.subLocality!.isNotEmpty)  p.subLocality!,
      if (p.locality     != null && p.locality!.isNotEmpty)     p.locality!,
    ];
    return parts.take(3).join(', ');
  }

  void _confirm(String address, GeoPoint geoPoint) =>
      Navigator.pop(context, {'address': address, 'location': geoPoint});

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: GasTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize:     MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Handle ──
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color:        GasTheme.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // ── Title ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Container(
                      width: 38, height: 38,
                      decoration: BoxDecoration(
                        color:        GasTheme.primaryDim,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(Icons.location_on_rounded,
                          color: GasTheme.primary, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Delivery Address',
                            style: TextStyle(
                              fontFamily:  'Inter',
                              fontSize:    17,
                              fontWeight:  FontWeight.w700,
                              color:       GasTheme.textPrimary,
                            )),
                        Text('Where should we deliver your gas?',
                            style: TextStyle(
                                fontSize: 12,
                                color:    GasTheme.textTertiary)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // ── GPS button ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: GestureDetector(
                  onTap: _isLoadingLocation
                      ? null
                      : _detectCurrentLocation,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color:        GasTheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: GasTheme.border),
                      boxShadow:    GasTheme.cardShadow,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42, height: 42,
                          decoration: BoxDecoration(
                            gradient:     GasTheme.heroGradient,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.my_location_rounded,
                              color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Use Current Location',
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize:   14,
                                    fontWeight: FontWeight.w600,
                                    color:      GasTheme.textPrimary,
                                  )),
                              const SizedBox(height: 2),
                              Text(
                                _isLoadingLocation
                                    ? 'Detecting your location…'
                                    : 'Tap to detect via GPS',
                                style: TextStyle(
                                    fontSize: 12,
                                    color:    GasTheme.textTertiary),
                              ),
                            ],
                          ),
                        ),
                        _isLoadingLocation
                            ? SizedBox(
                                width: 20, height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color:       GasTheme.primary,
                                ),
                              )
                            : const Icon(Icons.chevron_right_rounded,
                                color: GasTheme.textTertiary),
                      ],
                    ),
                  ),
                ),
              ),

              // ── Detected address card ──
              if (_detectedAddress != null &&
                  _detectedGeoPoint != null) ...[
                const SizedBox(height: 12),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color:        GasTheme.primaryDim,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: GasTheme.primary.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.check_circle_rounded,
                                color: GasTheme.success, size: 16),
                            const SizedBox(width: 6),
                            Text('Location Detected',
                                style: TextStyle(
                                  fontSize:   12,
                                  fontWeight: FontWeight.w600,
                                  color:      GasTheme.success,
                                )),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(_detectedAddress!,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize:   14,
                              fontWeight: FontWeight.w500,
                              color:      GasTheme.textPrimary,
                            )),
                        const SizedBox(height: 12),
                        GestureDetector(
                          onTap: () => _confirm(
                              _detectedAddress!, _detectedGeoPoint!),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                vertical: 14),
                            decoration: BoxDecoration(
                              gradient:     GasTheme.heroGradient,
                              borderRadius: BorderRadius.circular(12),
                              boxShadow:    GasTheme.primaryGlow,
                            ),
                            child: const Center(
                              child: Text('Confirm This Address',
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize:   14,
                                    fontWeight: FontWeight.w700,
                                    color:      Colors.white,
                                  )),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              // ── Error ──
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: GasTheme.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: GasTheme.error.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline_rounded,
                            color: GasTheme.error, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_errorMessage!,
                              style: TextStyle(
                                  fontSize: 12,
                                  color:    GasTheme.error)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              // ── Divider ──
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 16),
                child: Row(
                  children: [
                    Expanded(
                        child: Divider(color: GasTheme.border)),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12),
                      child: Text('OR TYPE ADDRESS',
                          style: TextStyle(
                            fontSize:      10,
                            fontWeight:    FontWeight.w600,
                            color:         GasTheme.textTertiary,
                            letterSpacing: 1,
                          )),
                    ),
                    Expanded(
                        child: Divider(color: GasTheme.border)),
                  ],
                ),
              ),

              // ── Manual input ──
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller:      _manualController,
                        focusNode:       _focusNode,
                        textInputAction: TextInputAction.search,
                        onSubmitted:     (_) => _geocodeManualAddress(),
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize:   14,
                          color:      GasTheme.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: 'e.g. East Legon, Accra',
                          hintStyle: TextStyle(
                              fontSize: 14,
                              color:    GasTheme.textTertiary),
                          filled:     true,
                          fillColor:  GasTheme.surfaceAlt,
                          prefixIcon: Icon(Icons.search_rounded,
                              color: GasTheme.textTertiary,
                              size: 18),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide:   BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide:
                                const BorderSide(color: GasTheme.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(
                                color: GasTheme.primary, width: 1.5),
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: _geocodeManualAddress,
                      child: Container(
                        width: 48, height: 48,
                        decoration: BoxDecoration(
                          gradient:     GasTheme.heroGradient,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow:    GasTheme.primaryGlow,
                        ),
                        child: const Icon(
                            Icons.arrow_forward_rounded,
                            color: Colors.white,
                            size: 20),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Saved addresses ──
              if (_recentAddresses.isNotEmpty) ...[
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text('SAVED ADDRESSES',
                      style: TextStyle(
                        fontSize:      10,
                        fontWeight:    FontWeight.w700,
                        color:         GasTheme.textTertiary,
                        letterSpacing: 1.2,
                      )),
                ),
                const SizedBox(height: 10),
                ..._recentAddresses.map(
                  (saved) => Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 4),
                    child: GestureDetector(
                      onTap: () =>
                          _confirm(saved.address, saved.geoPoint),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color:        GasTheme.surface,
                          borderRadius: BorderRadius.circular(14),
                          border:
                              Border.all(color: GasTheme.border),
                          boxShadow: GasTheme.cardShadow,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(
                                color:        GasTheme.primaryDim,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(saved.icon,
                                  color: GasTheme.primary, size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(saved.label,
                                      style: const TextStyle(
                                        fontFamily: 'Inter',
                                        fontSize:   14,
                                        fontWeight: FontWeight.w600,
                                        color:      GasTheme.textPrimary,
                                      )),
                                  const SizedBox(height: 2),
                                  Text(saved.address,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color:
                                              GasTheme.textTertiary)),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded,
                                color: GasTheme.textTertiary,
                                size: 18),
                          ],
                        ),
                      ),
                    ),
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
}

class _SavedAddress {
  final String   label;
  final String   address;
  final IconData icon;
  final GeoPoint geoPoint;

  const _SavedAddress({
    required this.label,
    required this.address,
    required this.icon,
    required this.geoPoint,
  });
}