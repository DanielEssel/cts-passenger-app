// lib/features/gas/presentation/widgets/address_picker_sheet.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:cts_transport_app/core/theme/app_theme.dart';
import 'package:cts_transport_app/widgets/common/glass_card.dart';

/// Returns: `{'address': String, 'location': GeoPoint}` or `null` if dismissed.
class AddressPickerSheet extends StatefulWidget {
  const AddressPickerSheet({super.key});

  @override
  State<AddressPickerSheet> createState() => _AddressPickerSheetState();
}

class _AddressPickerSheetState extends State<AddressPickerSheet> {
  final TextEditingController _manualController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _isLoadingLocation = false;
  String? _detectedAddress;
  GeoPoint? _detectedGeoPoint;
  String? _errorMessage;

  // Recent addresses (in a real app, load from local storage / Firestore)
  final List<_SavedAddress> _recentAddresses = [
    _SavedAddress(
      label: 'Home',
      address: 'East Legon, Accra',
      icon: Icons.home_rounded,
      geoPoint: const GeoPoint(5.6365, -0.1542),
    ),
    _SavedAddress(
      label: 'Work',
      address: 'Airport City, Accra',
      icon: Icons.work_rounded,
      geoPoint: const GeoPoint(5.6037, -0.1870),
    ),
  ];

  @override
  void dispose() {
    _manualController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // GPS detection
  // ─────────────────────────────────────────────

  Future<void> _detectCurrentLocation() async {
    setState(() {
      _isLoadingLocation = true;
      _errorMessage = null;
    });

    try {
      // 1. Check / request permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        throw Exception('Location permission denied. Please enable it in Settings.');
      }

      // 2. Check if location services are on
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are disabled. Please turn on GPS.');
      }

      // 3. Get position
     final position = await Geolocator.getCurrentPosition(
  locationSettings: const LocationSettings(
    accuracy: LocationAccuracy.high,
    timeLimit: Duration(seconds: 15),
  ),
);

      // 4. Reverse geocode
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isEmpty) throw Exception('Unable to determine address.');

      final place = placemarks.first;
      final address = _formatPlacemark(place);

      setState(() {
        _detectedAddress = address;
        _detectedGeoPoint = GeoPoint(position.latitude, position.longitude);
        _isLoadingLocation = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _isLoadingLocation = false;
      });
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

  // ─────────────────────────────────────────────
  // Geocode manually typed address
  // ─────────────────────────────────────────────

  Future<void> _geocodeManualAddress() async {
    final text = _manualController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _isLoadingLocation = true;
      _errorMessage = null;
    });

    try {
      final locations = await locationFromAddress('$text, Ghana');
      if (locations.isEmpty) throw Exception('Address not found. Try being more specific.');

      final loc = locations.first;
      final placemarks = await placemarkFromCoordinates(loc.latitude, loc.longitude);
      final address = placemarks.isNotEmpty
          ? _formatPlacemark(placemarks.first)
          : text;

      setState(() {
        _detectedAddress = address;
        _detectedGeoPoint = GeoPoint(loc.latitude, loc.longitude);
        _isLoadingLocation = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _isLoadingLocation = false;
      });
    }
  }

  void _confirmAddress(String address, GeoPoint geoPoint) {
    Navigator.pop(context, {'address': address, 'location': geoPoint});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[700],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Select Delivery Address',
                style: AppTheme.titleLarge.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Where should we deliver your gas?',
                style: AppTheme.bodyMedium.copyWith(color: Colors.grey),
              ),
            ),
            const SizedBox(height: 20),

            // ── GPS button ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: GlassCard(
                padding: EdgeInsets.zero,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _isLoadingLocation ? null : _detectCurrentLocation,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: const BoxDecoration(
                              gradient: AppTheme.primaryGradient,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.my_location_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Use Current Location',
                                  style: AppTheme.bodyMedium.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  _isLoadingLocation
                                      ? 'Detecting your location...'
                                      : 'Tap to detect via GPS',
                                  style: AppTheme.labelSmall
                                      .copyWith(color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                          if (_isLoadingLocation)
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            const Icon(Icons.chevron_right, color: Colors.grey),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Detected address confirm card ──
            if (_detectedAddress != null && _detectedGeoPoint != null) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: GlassCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.check_circle,
                              color: Colors.green, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Location Detected',
                            style: AppTheme.labelSmall.copyWith(
                              color: Colors.green,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _detectedAddress!,
                        style: AppTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () =>
                              _confirmAddress(_detectedAddress!, _detectedGeoPoint!),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryColor,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('Confirm This Address'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            // ── Error message ──
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: AppTheme.labelSmall.copyWith(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            // ── Divider ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  const Expanded(child: Divider(color: Colors.grey)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'OR TYPE ADDRESS',
                      style: AppTheme.labelSmall.copyWith(color: Colors.grey),
                    ),
                  ),
                  const Expanded(child: Divider(color: Colors.grey)),
                ],
              ),
            ),

            // ── Manual text input ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _manualController,
                      focusNode: _focusNode,
                      style: AppTheme.bodyMedium,
                      decoration: InputDecoration(
                        hintText: 'e.g. East Legon, Accra',
                        hintStyle: AppTheme.bodyMedium.copyWith(color: Colors.grey),
                        filled: true,
                        fillColor: AppTheme.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        prefixIcon:
                            const Icon(Icons.search_rounded, color: Colors.grey),
                      ),
                      onSubmitted: (_) => _geocodeManualAddress(),
                      textInputAction: TextInputAction.search,
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _geocodeManualAddress,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: const BoxDecoration(
                        gradient: AppTheme.primaryGradient,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.arrow_forward_rounded,
                          color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),

            // ── Saved / recent addresses ──
            if (_recentAddresses.isNotEmpty) ...[
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'SAVED ADDRESSES',
                  style: AppTheme.labelSmall.copyWith(
                    color: Colors.grey,
                    letterSpacing: 1,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              ..._recentAddresses.map(
                (saved) => Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: GlassCard(
                    padding: EdgeInsets.zero,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () =>
                            _confirmAddress(saved.address, saved.geoPoint),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryColor.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(saved.icon,
                                    color: AppTheme.primaryColor, size: 20),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      saved.label,
                                      style: AppTheme.bodyMedium.copyWith(
                                          fontWeight: FontWeight.w600),
                                    ),
                                    Text(
                                      saved.address,
                                      style: AppTheme.labelSmall
                                          .copyWith(color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right, color: Colors.grey),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Internal model for saved addresses
// ─────────────────────────────────────────────

class _SavedAddress {
  final String label;
  final String address;
  final IconData icon;
  final GeoPoint geoPoint;

  const _SavedAddress({
    required this.label,
    required this.address,
    required this.icon,
    required this.geoPoint,
  });
}