import 'dart:async';

import '../../../core/utils/vehicle_icons.dart';
import '../../ride/providers/drivers_nearby_provider.dart';
import '../../ride/providers/wallet_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import '../../ride/providers/ride_request_provider.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/routes/app_routes.dart';
import '../../../features/auth/providers/auth_providers.dart';
import '../../../features/notification/providers/notification_providers.dart';
import '../../home/extensions/service_type_extensions.dart';
import '../../home/services/location_services.dart';
import '../../home/theme/home_theme.dart';
import '../../ride/models/service_type.dart';
import '../services/driver_availability_service.dart';

// ─────────────────────────────────────────────────
// PROVIDERS
// ─────────────────────────────────────────────────

final driverAvailabilityServiceProvider =
    Provider((ref) => DriverAvailabilityService());

/// Remembers the last service the user launched into. The booking/options
/// screen is the real source of truth for the committed service; this just
/// seeds it.

final nearbyDriversProvider =
    StreamProvider.autoDispose.family<int, ServiceType>((ref, service) {
  final svc = ref.watch(driverAvailabilityServiceProvider);
  return svc.watchNearbyDriversCount(service);
});

final savedPlacesProvider =
    StreamProvider.autoDispose<List<_SavedPlace>>((ref) {
  final uid = ref.watch(userIdProvider);
  if (uid == null) return const Stream.empty();
  return FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .collection('saved_places')
      .orderBy('order')
      .snapshots()
      .map((s) => s.docs.map(_SavedPlace.fromFirestore).toList());
});

final promoBannerProvider = StreamProvider.autoDispose<_PromoBanner?>((ref) {
  return FirebaseFirestore.instance
      .collection('promotions')
      .where('active', isEqualTo: true)
      .where('targetAudience', whereIn: ['all', 'passengers'])
      .orderBy('priority', descending: true)
      .limit(1)
      .snapshots()
      .map((s) =>
          s.docs.isNotEmpty ? _PromoBanner.fromFirestore(s.docs.first) : null);
});

// ─────────────────────────────────────────────────
// PER-SERVICE ACCENT (premium, image-ready)
// Each service card uses its own accent gradient. To swap in artwork later,
// replace the gradient tile in _ServiceCard with an Image.asset — one widget.
// ─────────────────────────────────────────────────

class _ServiceAccent {
  final Color start;
  final Color end;
  const _ServiceAccent(this.start, this.end);
}

const Map<ServiceType, _ServiceAccent> _serviceAccents = {
  ServiceType.taxi:     _ServiceAccent(Color(0xFF00A86B), Color(0xFF00C97E)), // emerald
  ServiceType.okada:    _ServiceAccent(Color(0xFF0EA5A5), Color(0xFF14C2B8)), // teal
  ServiceType.delivery: _ServiceAccent(Color(0xFF2563EB), Color(0xFF3B82F6)), // blue
  ServiceType.gas:      _ServiceAccent(Color(0xFFF59E0B), Color(0xFFF97316)), // warm amber
};

_ServiceAccent _accentFor(ServiceType s) =>
    _serviceAccents[s] ?? const _ServiceAccent(Color(0xFF00A86B), Color(0xFF00C97E));

// ─────────────────────────────────────────────────
// HOME SCREEN
// ─────────────────────────────────────────────────

class HomeScreen extends ConsumerStatefulWidget {
  final VoidCallback? onWalletTap;
  final VoidCallback? onHistoryTap;
  const HomeScreen({super.key, this.onWalletTap, this.onHistoryTap});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  GoogleMapController? _mapController;
  LatLng? _userLocation;
  final Set<Marker> _markers = {};
  bool _isMapReady = false;
  Timer? _debounceTimer;
  StreamSubscription<Position>? _locationSub;
  bool _locationInitialized = false;
  bool _usingFallbackLocation = false; // allow retry

  bool _isLocating = true;
  String _locationLabel = 'Locating...';

  static const LatLng _accra = LatLng(5.6037, -0.1870);

  /// A confirmed pickup is required before booking can start.
  bool get _hasPickup => _userLocation != null && !_isLocating;

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initLocation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _checkLocationOnResume();
    }
  }

  Future<void> _checkLocationOnResume() async {
    // Retry if we only have the Accra fallback, not a real fix.
    if (_userLocation != null && !_usingFallbackLocation) return;
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) {
      _locationInitialized = false; // allow re-init
      _initLocation();
    }
  }

  Future<void> _initLocation() async {
    if (_locationInitialized &&
        _userLocation != null &&
        !_usingFallbackLocation) {
      return;
    }
    setState(() => _isLocating = true);

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _isLocating = false;
            _locationLabel = 'Location services off';
          });
          _showLocationErrorDialog('Please enable location services.');
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _isLocating = false;
            _locationLabel = 'Location access denied';
          });
          if (permission == LocationPermission.deniedForever) {
            _showLocationErrorDialog(
                'Location permission is permanently denied. Please enable it in Settings.');
          }
        }
        return;
      }

      final pos = await LocationService.instance.getCurrentLocation();

      if (!mounted) return;

      final ll = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _userLocation = ll;
        _isLocating = false;
        _locationInitialized = true;
        _usingFallbackLocation = false; // real fix obtained
      });

      if (_isMapReady) {
        _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(
              CameraPosition(target: ll, zoom: 15)),
        );
      }
      _updateUserMarker(ll);
      _startLocationUpdates();
      _updateLocationLabel(ll);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLocating = false;
        _locationLabel = 'Location unavailable';
        _userLocation = _accra;
        _usingFallbackLocation = true;
      });
      ref.read(rideRequestProvider.notifier).setOrigin(
            'Current location',
            GeoPoint(_accra.latitude, _accra.longitude),
          );
      debugPrint('Location error: $e');
    }
  }

  void _startLocationUpdates() {
    _locationSub?.cancel();
    _locationSub = null;

    LocationService.instance.startListening(
      onSignificantMove: (d) {
        // No auto-recenter — it fights the user panning the map.
      },
    ).then((_) {
      _locationSub = LocationService.instance.positionStream.listen((pos) {
        if (!mounted) return;
        final ll = LatLng(pos.latitude, pos.longitude);
        setState(() {
          _userLocation = ll;
          _usingFallbackLocation = false;
        });
        _updateUserMarker(ll);
        ref.read(rideRequestProvider.notifier).setOrigin(
              _locationLabel,
              GeoPoint(ll.latitude, ll.longitude),
            );
      });
    });
  }

  Future<void> _updateLocationLabel(LatLng ll) async {
    try {
      final label = await LocationService.instance.reverseGeocode(ll);
      if (mounted) setState(() => _locationLabel = label);
    } catch (_) {/* keep fallback label */}
  }

  // ── Live driver markers ──────────────────────────────────────────────────
  void _updateDriverMarkers(List<NearbyDriver> drivers) {
    if (!mounted) return;
    setState(() {
      _markers.removeWhere((m) => m.markerId.value.startsWith('driver_'));
      for (final d in drivers) {
        _markers.add(Marker(
          markerId: MarkerId(
              'driver_${d.location.latitude}_${d.location.longitude}'),
          position: d.location,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            d.serviceType == 'okada'
                ? BitmapDescriptor.hueGreen
                : BitmapDescriptor.hueAzure,
          ),
          infoWindow: InfoWindow(
            title: vehicleLabel(d.serviceType),
            snippet: 'Available nearby',
          ),
          flat: true,
          anchor: const Offset(0.5, 0.5),
        ));
      }
    });
  }

  void _updateUserMarker(LatLng pos) {
    // Rely on myLocationEnabled (blue dot) instead of a duplicate marker.
  }

  void _recenterMap() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      final target = _userLocation ?? _accra;
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
            CameraPosition(target: target, zoom: 15)),
      );
      HapticFeedback.lightImpact();
    });
  }

  void _showLocationErrorDialog(String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.location_off_rounded, color: AppColors.warning),
            SizedBox(width: 8),
            Text('Location Required'),
          ],
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Dismiss'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              Geolocator.openLocationSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // NAVIGATION — the single booking seam
  // ────────────────────────────────────────────
  void _openBooking({
    String? destinationLabel,
    String? destinationAddress,
    ServiceType? service,
  }) {
    if (!_hasPickup) {
      _snack('Getting your location — one moment…');
      return;
    }
    HapticFeedback.lightImpact();

    final ServiceType svc = service ?? ServiceType.taxi;


    Navigator.pushNamed(
      context,
      svc.route,
      arguments: {
        'service': svc,
        'pickup': _userLocation,
        if (destinationLabel != null) 'destinationLabel': destinationLabel,
        if (destinationAddress != null) 'destinationAddress': destinationAddress,
      },
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ));
  }

  Future<void> _refreshData() async {
    ref.invalidate(promoBannerProvider);
    ref.invalidate(walletBalanceProvider);
    if (ref.read(userIdProvider) != null) {
      ref.invalidate(savedPlacesProvider);
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _mapController?.dispose();
    _locationSub?.cancel();
    LocationService.instance.stopListening();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // BUILD — scrollable dashboard (NOT a map+sheet clone of booking)
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Keep driver markers fresh for the compact map card.
    ref.listen<AsyncValue<List<NearbyDriver>>>(
      driversNearbyProvider,
      (_, next) => next.whenData(_updateDriverMarkers),
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: HomeTheme.background,
        body: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _refreshData,
            color: HomeTheme.primary,
            backgroundColor: HomeTheme.surface,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics()),
              slivers: [
                SliverToBoxAdapter(child: _buildHeader()),
                SliverToBoxAdapter(child: _buildWhereTo()),
                SliverToBoxAdapter(child: _buildServiceGrid()),
                SliverToBoxAdapter(child: _buildMapCard()),
                SliverToBoxAdapter(child: _buildSavedPlaces()),
                SliverToBoxAdapter(child: _buildPromoBanner()),
                SliverToBoxAdapter(child: _buildRecentTrips()),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: MediaQuery.of(context).padding.bottom + 28,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // HEADER — greeting + location + wallet balance + bell + avatar
  // ─────────────────────────────────────────────

  Widget _buildHeader() {
    final user = ref.watch(currentUserProvider).value;
    final firstName = user?.displayName?.split(' ').first ?? 'there';
    final photoUrl = user?.photoURL;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_greeting,
                        style: const TextStyle(
                          color: HomeTheme.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        )),
                    const SizedBox(height: 2),
                    Text(firstName,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          color: HomeTheme.textPrimary,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        )),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Consumer(
                builder: (_, ref, __) {
                  final count = ref.watch(unreadNotifCountProvider).value ?? 0;
                  return _TopIconButton(
                    icon: Icons.notifications_outlined,
                    badge: count > 0,
                    badgeCount: count,
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.notifications),
                  );
                },
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: () => Navigator.pushNamed(context, AppRoutes.profile),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: HomeTheme.surface, width: 2),
                    boxShadow: HomeTheme.cardShadow,
                  ),
                  child: ClipOval(
                    child: photoUrl != null && photoUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: photoUrl,
                            fit: BoxFit.cover,
                            placeholder: (_, __) =>
                                Container(color: Colors.grey[200]),
                            errorWidget: (_, __, ___) =>
                                _avatarFallback(firstName),
                          )
                        : _avatarFallback(firstName),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Location + wallet row
          Row(
            children: [
              Expanded(child: _buildLocationPill()),
              const SizedBox(width: 10),
              _buildWalletChip(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLocationPill() => GestureDetector(
        onTap: _recenterMap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: HomeTheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: HomeTheme.border),
            boxShadow: HomeTheme.cardShadow,
          ),
          child: Row(
            children: [
              _PulsingDot(color: HomeTheme.primary),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  _locationLabel,
                  style: const TextStyle(
                    color: HomeTheme.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.my_location_rounded,
                  color: HomeTheme.textSecondary, size: 16),
            ],
          ),
        ),
      );

  Widget _buildWalletChip() {
    final balanceAsync = ref.watch(walletBalanceProvider);
    final label = switch (balanceAsync) {
      AsyncData(:final value) => '₵${value.toStringAsFixed(2)}',
      AsyncLoading() => '₵—',
      _ => '₵0.00',
    };
    return GestureDetector(
      onTap: widget.onWalletTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: HomeTheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: HomeTheme.primary.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            const Icon(Icons.account_balance_wallet_rounded,
                color: HomeTheme.primary, size: 16),
            const SizedBox(width: 7),
            Text(label,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  color: HomeTheme.primary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                )),
          ],
        ),
      ),
    );
  }

  Widget _avatarFallback(String name) => Container(
        color: HomeTheme.primary.withValues(alpha: 0.15),
        alignment: Alignment.center,
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : 'U',
          style: const TextStyle(
            color: HomeTheme.primary,
            fontWeight: FontWeight.w800,
            fontSize: 17,
          ),
        ),
      );

  // ── HERO: "Where to?" — strongest CTA ─────────────────────────────────────
  Widget _buildWhereTo() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        child: GestureDetector(
          onTap: _hasPickup ? () => _openBooking(service: ServiceType.taxi) : null,
          child: Opacity(
            opacity: _hasPickup ? 1 : 0.6,
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: HomeTheme.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: HomeTheme.border),
                boxShadow: HomeTheme.cardShadow,
              ),
              child: Row(
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      gradient: HomeTheme.primaryGradient,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: HomeTheme.primaryGlow,
                    ),
                    child: const Icon(Icons.search_rounded,
                        color: Colors.white, size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _hasPickup ? 'Where to?' : 'Getting your location…',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            color: HomeTheme.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _hasPickup
                              ? 'Set your destination to see options'
                              : 'We need your pickup first',
                          style: const TextStyle(
                            color: HomeTheme.textTertiary,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: HomeTheme.surfaceAlt,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(Icons.arrow_forward_rounded,
                        color: HomeTheme.textSecondary, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  // ── Service launcher grid (2×2) ───────────────────────────────────────────
  Widget _buildServiceGrid() {
    final services = ServiceType.values;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: services.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.55,
        ),
        itemBuilder: (_, i) {
          final svc = services[i];
          return _ServiceCard(
            service: svc,
            accent: _accentFor(svc),
            onTap: () => _openBooking(service: svc),
          );
        },
      ),
    );
  }

  // ── Compact live-drivers map card (~190px) ────────────────────────────────
  Widget _buildMapCard() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: SizedBox(
          height: 190,
          child: Stack(
            children: [
              Positioned.fill(child: _buildMap()),
              // subtle top gradient for the pill legibility
              Positioned(
                top: 0, left: 0, right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 60,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.18),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // "N drivers nearby" pill (real count, no fake ETA)
              Positioned(
                top: 12,
                left: 12,
                child: _buildDriversPill(),
              ),
              // recenter button
              Positioned(
                bottom: 12,
                right: 12,
                child: GestureDetector(
                  onTap: _recenterMap,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: HomeTheme.surface,
                      shape: BoxShape.circle,
                      boxShadow: HomeTheme.cardShadow,
                    ),
                    child: const Icon(Icons.my_location_rounded,
                        color: HomeTheme.primary, size: 20),
                  ),
                ),
              ),
              // tap-to-expand → opens booking (map is a launcher, not a canvas)
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _hasPickup ? () => _openBooking(service: ServiceType.taxi) : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDriversPill() {
    // Count the live driver markers currently rendered.
    final count = _markers.where((m) => m.markerId.value.startsWith('driver_')).length;
    final text = count == 0
        ? 'Looking for drivers…'
        : '$count driver${count == 1 ? '' : 's'} nearby';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: HomeTheme.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(30),
        boxShadow: HomeTheme.cardShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: count == 0 ? HomeTheme.textTertiary : HomeTheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(text,
              style: const TextStyle(
                fontFamily: 'Inter',
                color: HomeTheme.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              )),
        ],
      ),
    );
  }

  static const String _mapStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#f5f5f5"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#f5f5f5"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#eeeeee"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#d8f0e4"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#ffffff"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#e8f5e9"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#b3d9f2"}]}
]
''';

  Widget _buildMap() {
    final target = _userLocation ?? _accra;
    return GoogleMap(
      style: _mapStyle,
      initialCameraPosition: CameraPosition(target: target, zoom: 14.5),
      onMapCreated: (c) async {
        _mapController = c;
        setState(() => _isMapReady = true);
        if (_userLocation != null) {
          await c.animateCamera(CameraUpdate.newCameraPosition(
            CameraPosition(target: _userLocation!, zoom: 15),
          ));
        }
      },
      markers: _markers,
      myLocationEnabled: true,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      mapToolbarEnabled: false,
      compassEnabled: false,
      buildingsEnabled: true,
      // The card scrolls within the page; let the page own vertical gestures
      // so the small map doesn't trap the scroll.
      gestureRecognizers: const {},
    );
  }

  // ── Quick destinations (saved places) ─────────────────────────────────────
  Widget _buildSavedPlaces() {
    final placesAsync = ref.watch(savedPlacesProvider);
    final defaults = [
      _SavedPlace(
          id: 'home',
          label: 'Home',
          address: 'Set home address',
          icon: Icons.home_rounded),
      _SavedPlace(
          id: 'work',
          label: 'Work',
          address: 'Set work address',
          icon: Icons.work_rounded),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 26, 20, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Quick destinations',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    color: HomeTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  )),
              GestureDetector(
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.savedPlaces),
                child: const Text('Edit',
                    style: TextStyle(
                      color: HomeTheme.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    )),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 76,
          child: placesAsync.when(
            data: (places) {
              final all = [
                ...defaults.where((d) => !places.any((p) => p.id == d.id)),
                ...places,
                _SavedPlace(
                    id: 'add',
                    label: 'Add',
                    address: '',
                    icon: Icons.add_rounded),
              ];
              return _placesList(all);
            },
            loading: () => _placesList(defaults),
            error: (_, __) => _placesList(defaults),
          ),
        ),
      ],
    );
  }

  Widget _placesList(List<_SavedPlace> places) => ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: places.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) => _PlaceChip(
          place: places[i],
          onTap: () => _onSavedPlaceTap(places[i]),
        ),
      );

  void _onSavedPlaceTap(_SavedPlace place) {
    if (place.id == 'add' || place.address.isEmpty) {
      Navigator.pushNamed(context, AppRoutes.savedPlaces);
      return;
    }
    _openBooking(
      destinationLabel: place.label,
      destinationAddress: place.address,
    );
  }

  // ── Recent trips ──────────────────────────────────────────────────────────
  Widget _buildRecentTrips() {
    final uid = ref.watch(userIdProvider);
    if (uid == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .where('passengerId', isEqualTo: uid)
          .where('status', isEqualTo: 'completed')
          .orderBy('createdAt', descending: true)
          .limit(3)
          .snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData || (snap.data?.docs.isEmpty ?? true)) {
          return _buildEmptyState();
        }
        final docs = snap.data!.docs;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 26, 20, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Recent trips',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        color: HomeTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      )),
                  GestureDetector(
                onTap: widget.onHistoryTap ??
                    () => Navigator.pushNamed(context, AppRoutes.tripHistory),
                child: const Text('See all',
                    style: TextStyle(
                      color: HomeTheme.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    )),
              ),
                ],
              ),
            ),
            ...docs.map((doc) {
              final d = doc.data() as Map<String, dynamic>;
              final ts = d['createdAt'] as Timestamp?;
              final date =
                  ts != null ? DateFormat('MMM d').format(ts.toDate()) : '';
              final originalService =
                  _serviceFromString(d['serviceType'] as String?);
              return _RecentTripTile(
                from: d['pickupAddress'] as String? ?? '—',
                to: d['dropoffAddress'] as String? ?? '—',
                fare: (d['actualFare'] as num?)?.toDouble() ?? 0,
                date: date,
                onRebook: () => _openBooking(
                  service: originalService,
                  destinationAddress: d['dropoffAddress'] as String?,
                ),
              );
            }),
          ],
        );
      },
    );
  }

  ServiceType _serviceFromString(String? v) =>
      ServiceType.values.firstWhere(
        (e) => e.name == v,
        orElse: () => ServiceType.taxi,
      );

  Widget _buildEmptyState() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 26, 20, 0),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: HomeTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: HomeTheme.border),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: HomeTheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.route_rounded,
                    color: HomeTheme.primary.withValues(alpha: 0.5), size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('No trips yet',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          color: HomeTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        )),
                    const SizedBox(height: 3),
                    const Text('Your completed trips will appear here',
                        style: TextStyle(
                          color: HomeTheme.textTertiary,
                          fontSize: 12,
                        )),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  // ── Promotions ────────────────────────────────────────────────────────────
  Widget _buildPromoBanner() {
    final promoAsync = ref.watch(promoBannerProvider);
    return promoAsync.when(
      data: (p) => p == null ? _buildDefaultPromo() : _PromoCard(promo: p),
      loading: () => const SizedBox.shrink(),
      error: (_, __) => _buildDefaultPromo(),
    );
  }

  Widget _buildDefaultPromo() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: HomeTheme.primaryGradient,
            borderRadius: BorderRadius.circular(24),
            boxShadow: HomeTheme.primaryGlow,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text('FIRST RIDE',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                          )),
                    ),
                    const SizedBox(height: 10),
                    const Text('50% off\nyour first ride',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                          letterSpacing: -0.5,
                        )),
                    const SizedBox(height: 14),
                    GestureDetector(
                      onTap: () =>
                          Navigator.pushNamed(context, AppRoutes.promotions),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 9),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text('Use code CTS50',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              color: HomeTheme.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            )),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.local_offer_rounded,
                  color: Colors.white.withValues(alpha: 0.15), size: 90),
            ],
          ),
        ),
      );
}

// ═══════════════════════════════════════════════
// SHARED WIDGETS
// ═══════════════════════════════════════════════

/// Premium service card with a per-service accent gradient tile.
/// IMAGE UPGRADE LATER: replace the gradient `Container` holding the icon with
///   ClipRRect(borderRadius: ..., child: Image.asset('assets/services/${service.name}.png', ...))
/// keeping the rest of the card identical.
class _ServiceCard extends StatelessWidget {
  final ServiceType service;
  final _ServiceAccent accent;
  final VoidCallback onTap;
  const _ServiceCard({
    required this.service,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: HomeTheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: HomeTheme.border),
          boxShadow: HomeTheme.cardShadow,
        ),
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // Accent tile (swap for Image.asset later)
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [accent.start, accent.end],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: accent.start.withValues(alpha: 0.28),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(service.icon, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(service.displayName,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        color: HomeTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      )),
                  const SizedBox(height: 2),
                  Text(_subtitleFor(service),
                      style: const TextStyle(
                        color: HomeTheme.textTertiary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _subtitleFor(ServiceType s) => switch (s) {
        ServiceType.taxi => 'Comfortable rides',
        ServiceType.okada => 'Beat the traffic',
        ServiceType.delivery => 'Send a package',
        ServiceType.gas => 'Refill at home',
      };
}

class _PulsingDot extends StatefulWidget {
  final Color color;
  final double size;
  const _PulsingDot({required this.color}) : size = 8;
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat(reverse: true);

  late final Animation<double> _a =
      Tween<double>(begin: 0.4, end: 1.0).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _a,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.5),
                blurRadius: 6,
              ),
            ],
          ),
        ),
      );
}

class _TopIconButton extends StatelessWidget {
  final IconData icon;
  final bool badge;
  final int badgeCount;
  final VoidCallback onTap;

  const _TopIconButton({
    required this.icon,
    this.badge = false,
    this.badgeCount = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: HomeTheme.surface,
            shape: BoxShape.circle,
            border: Border.all(color: HomeTheme.border),
            boxShadow: HomeTheme.cardShadow,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, color: HomeTheme.textPrimary, size: 22),
              if (badge)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 3, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppColors.error,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: HomeTheme.surface, width: 1.5),
                    ),
                    constraints:
                        const BoxConstraints(minWidth: 14, minHeight: 14),
                    child: Text(
                      badgeCount > 9 ? '9+' : '$badgeCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

class _PlaceChip extends StatelessWidget {
  final _SavedPlace place;
  final VoidCallback onTap;
  const _PlaceChip({required this.place, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 100,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: HomeTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: HomeTheme.border),
            boxShadow: HomeTheme.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: HomeTheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(place.icon, color: HomeTheme.primary, size: 16),
              ),
              const SizedBox(height: 7),
              Text(place.label,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    color: HomeTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      );
}

class _RecentTripTile extends StatelessWidget {
  final String from, to, date;
  final double fare;
  final VoidCallback onRebook;

  const _RecentTripTile({
    required this.from,
    required this.to,
    required this.fare,
    required this.date,
    required this.onRebook,
  });

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: HomeTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: HomeTheme.border),
          boxShadow: HomeTheme.cardShadow,
        ),
        child: Row(
          children: [
            Column(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    border: Border.all(color: HomeTheme.primary, width: 2),
                    shape: BoxShape.circle,
                  ),
                ),
                Container(width: 1.5, height: 22, color: HomeTheme.border),
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: HomeTheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(from,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        color: HomeTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Expanded(
                        child: Text(to,
                            style: const TextStyle(
                              color: HomeTheme.textTertiary,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                      Text(date,
                          style: const TextStyle(
                            color: HomeTheme.textTertiary,
                            fontSize: 11,
                          )),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (fare > 0)
                  Text('₵${fare.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        color: HomeTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      )),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: onRebook,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: HomeTheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: HomeTheme.primary.withValues(alpha: 0.2),
                      ),
                    ),
                    child: const Text('Rebook',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          color: HomeTheme.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        )),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

class _PromoCard extends StatelessWidget {
  final _PromoBanner promo;
  const _PromoCard({required this.promo});

  Color _parseColor(String hex, Color fallback) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return fallback;
    }
  }

  @override
  Widget build(BuildContext context) {
    final start = _parseColor(promo.colorStart, HomeTheme.primary);
    final end = _parseColor(promo.colorEnd, HomeTheme.primary);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [start, end],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(promo.tag,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 9,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w700,
                      )),
                  const SizedBox(height: 6),
                  Text(promo.title,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                        letterSpacing: -0.4,
                      )),
                  if (promo.code != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('Code: ${promo.code}',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            color: start,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          )),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.local_offer_rounded,
                color: Colors.white.withValues(alpha: 0.15), size: 80),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// DATA MODELS
// ─────────────────────────────────────────────────

class _SavedPlace {
  final String id;
  final String label;
  final String address;
  final IconData icon;

  const _SavedPlace({
    required this.id,
    required this.label,
    required this.address,
    this.icon = Icons.place_rounded,
  });

  factory _SavedPlace.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return _SavedPlace(
      id: doc.id,
      label: d['label'] as String? ?? 'Place',
      address: d['address'] as String? ?? '',
    );
  }
}

class _PromoBanner {
  final String title;
  final String tag;
  final String? code;
  final String colorStart;
  final String colorEnd;

  const _PromoBanner({
    required this.title,
    required this.tag,
    this.code,
    required this.colorStart,
    required this.colorEnd,
  });

  factory _PromoBanner.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return _PromoBanner(
      title: d['title'] as String? ?? '',
      tag: d['tag'] as String? ?? 'OFFER',
      code: d['code'] as String?,
      colorStart: d['colorStart'] as String? ?? '#16A34A',
      colorEnd: d['colorEnd'] as String? ?? '#15803D',
    );
  }
}