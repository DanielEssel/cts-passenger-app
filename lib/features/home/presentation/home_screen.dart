// lib/features/home/presentation/home_screen.dart

import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

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

final nearbyDriversProvider =
    StreamProvider.autoDispose.family<int, ServiceType>((ref, service) {
  final svc = ref.watch(driverAvailabilityServiceProvider);
  return svc.watchNearbyDriversCount(service);
});

final savedPlacesProvider =
    StreamProvider.autoDispose<List<_SavedPlace>>((ref) {
  final uid = ref.watch(userIdProvider);
  if (uid == null) return const Stream.empty();
  // ✅ Use 'users' collection not 'passengers'
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
// HOME SCREEN
// ─────────────────────────────────────────────────

class HomeScreen extends ConsumerStatefulWidget {
  final VoidCallback? onWalletTap;
  const HomeScreen({super.key, this.onWalletTap});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {

  GoogleMapController?          _mapController;
  LatLng?                       _userLocation;
  final Set<Marker>             _markers = {};
  bool                          _isMapReady    = false;
  Timer?                        _debounceTimer;
  StreamSubscription<Position>? _locationSub;
  bool                          _locationInitialized = false; // ✅ prevent duplicate init

  ServiceType _selectedService = ServiceType.taxi;
  bool        _isLocating      = true;
  String      _locationLabel   = 'Locating...';

  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  late AnimationController _chipAnimController;

  static const LatLng _accra = LatLng(5.6037, -0.1870);

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
    _chipAnimController = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 350),
    )..forward();
    _initLocation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ✅ Only re-check on resume, don't restart full init
    if (state == AppLifecycleState.resumed) {
      _checkLocationOnResume();
    }
  }

  Future<void> _checkLocationOnResume() async {
    if (_userLocation != null) return; // ✅ Already has location
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) {
      _initLocation();
    }
  }

  Future<void> _initLocation() async {
    if (_locationInitialized && _userLocation != null) return; // ✅ Guard
    setState(() => _isLocating = true);

    try {
      // ✅ Check permission first without showing dialog for every error
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _isLocating    = false;
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
            _isLocating    = false;
            _locationLabel = 'Location access denied';
          });
          // ✅ Only show dialog for actual permission denial
          if (permission == LocationPermission.deniedForever) {
            _showLocationErrorDialog(
                'Location permission is permanently denied. Please enable it in Settings.');
          }
        }
        return;
      }

      final pos = await LocationService.instance
          .getCurrentLocation()
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      final ll = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _userLocation        = ll;
        _isLocating          = false;
        _locationInitialized = true;
      });

      if (_isMapReady) {
        _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(
              CameraPosition(target: ll, zoom: 15)),
        );
      }
      _updateUserMarker(ll);
      _startLocationUpdates(); // ✅ No await — runs in background
      _updateLocationLabel(ll);
    } catch (e) {
      if (!mounted) return;
      // ✅ Don't show dialog for timeouts/network errors
      setState(() {
        _isLocating    = false;
        _locationLabel = 'Location unavailable';
        _userLocation  = _accra; // ✅ Fall back to Accra
      });
      debugPrint('Location error: $e');
    }
  }

  void _startLocationUpdates() {
    // ✅ Cancel existing subscription before creating new one
    _locationSub?.cancel();
    _locationSub = null;

    LocationService.instance.startListening(
      onSignificantMove: (d) {
        if (mounted && d > 50) _recenterMap();
      },
    ).then((_) {
      _locationSub = LocationService.instance.positionStream.listen((pos) {
        if (!mounted) return;
        final ll = LatLng(pos.latitude, pos.longitude);
        setState(() => _userLocation = ll);
        _updateUserMarker(ll);
      });
    });
  }

  Future<void> _updateLocationLabel(LatLng ll) async {
    try {
      final label = await LocationService.instance.reverseGeocode(ll);
      if (mounted) setState(() => _locationLabel = label);
    } catch (_) {
      // Silently fail — label stays as fallback
    }
  }

  void _updateUserMarker(LatLng pos) {
    if (!mounted) return;
    setState(() {
      _markers
        ..removeWhere((m) => m.markerId.value == 'user')
        ..add(Marker(
          markerId:  const MarkerId('user'),
          position:  pos,
          icon:      BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueGreen),
          infoWindow: const InfoWindow(title: 'You'),
        ));
    });
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
      barrierDismissible: true, // ✅ Allow dismissal
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
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

  Future<void> _selectService(ServiceType service) async {
    HapticFeedback.selectionClick();
    setState(() => _selectedService = service);
    _chipAnimController..reset()..forward();
    await _goToSearch();
  }

  Future<void> _goToSearch() async {
    HapticFeedback.lightImpact();
    if (!mounted) return;
    Navigator.pushNamed(
      context,
      _selectedService.route,
      arguments: {'service': _selectedService},
    );
  }

  Future<void> _refreshData() async {
    await Future.wait([
      ref.refresh(nearbyDriversProvider(_selectedService).future),
      ref.refresh(savedPlacesProvider.future),
      ref.refresh(promoBannerProvider.future),
    ]);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _chipAnimController.dispose();
    _sheetController.dispose();
    _mapController?.dispose();
    _locationSub?.cancel();
    LocationService.instance.stopListening();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: HomeTheme.background,
        body: Stack(
          children: [
            _buildMap(),
            _buildTopFade(),
            Positioned(
              top:   topPad + 10,
              left:  16,
              right: 16,
              child: _buildTopBar(),
            ),
            Positioned(
              right:  16,
              bottom: MediaQuery.of(context).size.height * 0.44 + 16,
              child:  _buildRecenterFab(),
            ),
            _buildBottomSheet(),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // MAP
  // ─────────────────────────────────────────────

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
      style:                  _mapStyle,
      initialCameraPosition:  CameraPosition(target: target, zoom: 14.5),
      onMapCreated: (c) async {
        _mapController = c;
        setState(() => _isMapReady = true);
        if (_userLocation != null) {
          await c.animateCamera(CameraUpdate.newCameraPosition(
            CameraPosition(target: _userLocation!, zoom: 15),
          ));
        }
      },
      markers:                _markers,
      myLocationEnabled:      true,
      myLocationButtonEnabled: false,
      zoomControlsEnabled:    false,
      mapToolbarEnabled:      false,
      compassEnabled:         false,
      buildingsEnabled:       true,
    );
  }

  Widget _buildTopFade() => Positioned(
        top: 0, left: 0, right: 0,
        child: IgnorePointer(
          child: Container(
            height: 180,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end:   Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.55),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      );

  // ─────────────────────────────────────────────
  // TOP BAR
  // ─────────────────────────────────────────────

  Widget _buildTopBar() {
    final user      = ref.watch(currentUserProvider).value;
    final firstName = user?.displayName?.split(' ').first ?? 'there';
    final photoUrl  = user?.photoURL;

    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _recenterMap,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color:        Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(50),
                boxShadow: [
                  BoxShadow(
                    color:      Colors.black.withValues(alpha: 0.12),
                    blurRadius: 16,
                    offset:     const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  _PulsingDot(color: HomeTheme.primary),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      _locationLabel,
                      style: const TextStyle(
                        color:       Color(0xFF0D1F14),
                        fontSize:    12.5,
                        fontWeight:  FontWeight.w600,
                        letterSpacing: 0.1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(Icons.expand_more_rounded,
                      color: HomeTheme.textSecondary, size: 18),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),

        // Notifications
        Consumer(
          builder: (_, ref, __) {
            final count = ref.watch(unreadNotifCountProvider).value ?? 0;
            return _TopIconButton(
              icon:       Icons.notifications_outlined,
              badge:      count > 0,
              badgeCount: count,
              onTap: () =>
                  Navigator.pushNamed(context, AppRoutes.notifications),
            );
          },
        ),
        const SizedBox(width: 10),

        // Avatar
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, AppRoutes.profile),
          child: Container(
            width:  42,
            height: 42,
            decoration: BoxDecoration(
              shape:  BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: [
                BoxShadow(
                  color:      Colors.black.withValues(alpha: 0.2),
                  blurRadius: 12,
                ),
              ],
            ),
            child: ClipOval(
              child: photoUrl != null && photoUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl:     photoUrl,
                      fit:          BoxFit.cover,
                      placeholder:  (_, __) =>
                          Container(color: Colors.grey[200]),
                      errorWidget:  (_, __, ___) =>
                          _avatarFallback(firstName),
                    )
                  : _avatarFallback(firstName),
            ),
          ),
        ),
      ],
    );
  }

  Widget _avatarFallback(String name) => Container(
        color: HomeTheme.primary.withValues(alpha: 0.15),
        alignment: Alignment.center,
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : 'U',
          style: TextStyle(
            color:      HomeTheme.primary,
            fontWeight: FontWeight.w800,
            fontSize:   17,
          ),
        ),
      );

  Widget _buildRecenterFab() => GestureDetector(
        onTap: _recenterMap,
        child: Container(
          width:  46,
          height: 46,
          decoration: BoxDecoration(
            color:     HomeTheme.surface,
            shape:     BoxShape.circle,
            boxShadow: HomeTheme.cardShadow,
          ),
          child: Icon(Icons.my_location_rounded,
              color: HomeTheme.primary, size: 22),
        ),
      );

  // ─────────────────────────────────────────────
  // BOTTOM SHEET
  // ─────────────────────────────────────────────

  Widget _buildBottomSheet() {
    final user      = ref.watch(currentUserProvider).value;
    final firstName = user?.displayName?.split(' ').first ?? 'there';

    return DraggableScrollableSheet(
      controller:       _sheetController,
      initialChildSize: 0.44,
      minChildSize:     0.16,
      maxChildSize:     0.92,
      snap:             true,
      snapSizes:        const [0.16, 0.44, 0.92],
      builder: (ctx, sc) => Container(
        decoration: BoxDecoration(
          color:        HomeTheme.surface,
          borderRadius: const BorderRadius.vertical(
              top: Radius.circular(28)),
          boxShadow: HomeTheme.sheetShadow,
        ),
        child: RefreshIndicator(
          onRefresh:       _refreshData,
          color:           HomeTheme.primary,
          backgroundColor: HomeTheme.surface,
          child: CustomScrollView(
            controller: sc,
            physics:    const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics()),
            slivers: [
              SliverToBoxAdapter(child: _buildDragHandle()),
              SliverToBoxAdapter(
                  child: _buildSheetHeader(firstName)),
              SliverToBoxAdapter(child: _buildServiceGrid()),
              SliverToBoxAdapter(child: _buildSearchBar()),
              SliverToBoxAdapter(child: _buildNearbyBadge()),
              SliverToBoxAdapter(child: _buildSavedPlaces()),
              SliverToBoxAdapter(child: _buildRecentTrips()),
              SliverToBoxAdapter(child: _buildPromoBanner()),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.of(context).padding.bottom + 32,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDragHandle() => Center(
        child: Container(
          width:  36,
          height: 4,
          margin: const EdgeInsets.only(top: 14, bottom: 6),
          decoration: BoxDecoration(
            color:        HomeTheme.border,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _buildSheetHeader(String firstName) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_greeting,
                    style: TextStyle(
                      color:      HomeTheme.textSecondary,
                      fontSize:   13,
                      fontWeight: FontWeight.w500,
                    )),
                const SizedBox(height: 2),
                Text(firstName,
                    style: const TextStyle(
                      fontFamily:    'Inter',
                      color:         HomeTheme.textPrimary,
                      fontSize:      24,
                      fontWeight:    FontWeight.w800,
                      letterSpacing: -0.5,
                    )),
              ],
            ),
            GestureDetector(
              onTap: widget.onWalletTap,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color:        HomeTheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(30),
                  border:       Border.all(
                    color: HomeTheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.account_balance_wallet_rounded,
                        color: HomeTheme.primary, size: 16),
                    const SizedBox(width: 7),
                    Text('Wallet',
                        style: TextStyle(
                          fontFamily:  'Inter',
                          color:       HomeTheme.primary,
                          fontSize:    13,
                          fontWeight:  FontWeight.w700,
                        )),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  Widget _buildServiceGrid() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Row(
          children: ServiceType.values.map((svc) {
            final selected = svc == _selectedService;
            return Expanded(
              child: GestureDetector(
                onTap: () => _selectService(svc),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve:    Curves.easeOutCubic,
                  margin:   const EdgeInsets.symmetric(horizontal: 4),
                  padding:  const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: selected
                        ? HomeTheme.primary.withValues(alpha: 0.08)
                        : HomeTheme.surfaceAlt,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: selected
                          ? HomeTheme.primary.withValues(alpha: 0.5)
                          : HomeTheme.border,
                      width: selected ? 1.5 : 1,
                    ),
                    boxShadow: selected ? HomeTheme.primaryGlow : null,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width:  44,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: selected
                              ? HomeTheme.primaryGradient
                              : null,
                          color: selected
                              ? null
                              : HomeTheme.border.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          svc.icon,
                          color: selected
                              ? Colors.white
                              : HomeTheme.textSecondary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        svc.displayName,
                        style: TextStyle(
                          fontFamily:  'Inter',
                          color:       selected
                              ? HomeTheme.primary
                              : HomeTheme.textSecondary,
                          fontSize:    11,
                          fontWeight:  selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      );

  Widget _buildSearchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: GestureDetector(
          onTap: _goToSearch,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color:        HomeTheme.surfaceAlt,
              borderRadius: BorderRadius.circular(18),
              border:       Border.all(color: HomeTheme.border),
              boxShadow:    HomeTheme.cardShadow,
            ),
            child: Row(
              children: [
                Container(
                  width:  42,
                  height: 42,
                  decoration: BoxDecoration(
                    gradient:     HomeTheme.primaryGradient,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(Icons.search_rounded,
                      color: Colors.white, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_selectedService.searchHint,
                          style: const TextStyle(
                            fontFamily:    'Inter',
                            color:         HomeTheme.textPrimary,
                            fontSize:      15,
                            fontWeight:    FontWeight.w700,
                            letterSpacing: -0.2,
                          )),
                      const SizedBox(height: 2),
                      Text('Tap to enter destination',
                          style: TextStyle(
                            color:   HomeTheme.textTertiary,
                            fontSize: 11.5,
                          )),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color:        HomeTheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border:       Border.all(
                      color: HomeTheme.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_selectedService.icon,
                          color: HomeTheme.primary, size: 13),
                      const SizedBox(width: 4),
                      Text(_selectedService.displayName,
                          style: TextStyle(
                            fontFamily:  'Inter',
                            color:       HomeTheme.primary,
                            fontSize:    11,
                            fontWeight:  FontWeight.w700,
                          )),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _buildNearbyBadge() {
    final async = ref.watch(nearbyDriversProvider(_selectedService));
    return async.when(
      data: (n) {
        if (n == 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Row(
            children: [
              _PulsingDot(color: HomeTheme.primary, size: 7),
              const SizedBox(width: 8),
              Text(
                '$n ${_selectedService.displayName}${n == 1 ? '' : 's'} available near you',
                style: TextStyle(
                  color:      HomeTheme.textSecondary,
                  fontSize:   12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color:        HomeTheme.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border:       Border.all(
                    color: HomeTheme.success.withValues(alpha: 0.25),
                  ),
                ),
                child: Text('LIVE',
                    style: TextStyle(
                      color:         HomeTheme.success,
                      fontSize:      9,
                      fontWeight:    FontWeight.w800,
                      letterSpacing: 0.8,
                    )),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error:   (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildSavedPlaces() {
    final placesAsync = ref.watch(savedPlacesProvider);
    final defaults    = [
      _SavedPlace(
          id:      'home',
          label:   'Home',
          address: 'Set home address',
          icon:    Icons.home_rounded),
      _SavedPlace(
          id:      'work',
          label:   'Work',
          address: 'Set work address',
          icon:    Icons.work_rounded),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Quick destinations',
                  style: TextStyle(
                    fontFamily:    'Inter',
                    color:         HomeTheme.textPrimary,
                    fontSize:      15,
                    fontWeight:    FontWeight.w700,
                    letterSpacing: -0.2,
                  )),
              GestureDetector(
                onTap: () => Navigator.pushNamed(
                    context, AppRoutes.savedPlaces),
                child: Text('Edit',
                    style: TextStyle(
                      color:      HomeTheme.primary,
                      fontSize:   13,
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
                ...defaults.where(
                    (d) => !places.any((p) => p.id == d.id)),
                ...places,
                _SavedPlace(
                    id:      'add',
                    label:   'Add',
                    address: '',
                    icon:    Icons.add_rounded),
              ];
              return _placesList(all);
            },
            loading: () => _placesList(defaults),
            error:   (_, __) => _placesList(defaults),
          ),
        ),
      ],
    );
  }

  Widget _placesList(List<_SavedPlace> places) => ListView.separated(
        scrollDirection: Axis.horizontal,
        padding:         const EdgeInsets.symmetric(horizontal: 20),
        itemCount:       places.length,
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
    Navigator.pushNamed(context, _selectedService.route, arguments: {
      'service':            _selectedService,
      'destinationLabel':   place.label,
      'destinationAddress': place.address,
    });
  }

  Widget _buildRecentTrips() {
    final uid = ref.watch(userIdProvider);
    if (uid == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .where('passengerId', isEqualTo: uid)
          .where('status',      isEqualTo: 'completed')
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
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Recent trips',
                      style: TextStyle(
                        fontFamily:    'Inter',
                        color:         HomeTheme.textPrimary,
                        fontSize:      15,
                        fontWeight:    FontWeight.w700,
                        letterSpacing: -0.2,
                      )),
                  GestureDetector(
                    onTap: () => Navigator.pushNamed(
                        context, AppRoutes.tripHistory),
                    child: Text('See all',
                        style: TextStyle(
                          color:      HomeTheme.primary,
                          fontSize:   13,
                          fontWeight: FontWeight.w600,
                        )),
                  ),
                ],
              ),
            ),
            ...docs.map((doc) {
              final d    = doc.data() as Map<String, dynamic>;
              final ts   = d['createdAt'] as Timestamp?;
              final date = ts != null
                  ? DateFormat('MMM d').format(ts.toDate())
                  : '';
              return _RecentTripTile(
                from: d['pickupAddress']  as String? ?? '—',
                to:   d['dropoffAddress'] as String? ?? '—',
                fare: (d['actualFare']    as num?)?.toDouble() ?? 0,
                date: date,
                onRebook: () => Navigator.pushNamed(
                  context,
                  _selectedService.route,
                  arguments: {
                    'pickupAddress':  d['pickupAddress'],
                    'dropoffAddress': d['dropoffAddress'],
                  },
                ),
              );
            }),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color:        HomeTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(18),
            border:       Border.all(color: HomeTheme.border),
          ),
          child: Row(
            children: [
              Container(
                width:  48,
                height: 48,
                decoration: BoxDecoration(
                  color:        HomeTheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.route_rounded,
                    color: HomeTheme.primary.withValues(alpha: 0.5),
                    size:  24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('No trips yet',
                        style: TextStyle(
                          fontFamily:  'Inter',
                          color:       HomeTheme.textPrimary,
                          fontSize:    14,
                          fontWeight:  FontWeight.w600,
                        )),
                    const SizedBox(height: 3),
                    Text('Your completed trips will appear here',
                        style: TextStyle(
                          color:   HomeTheme.textTertiary,
                          fontSize: 12,
                        )),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _buildPromoBanner() {
    final promoAsync = ref.watch(promoBannerProvider);
    return promoAsync.when(
      data:    (p) => p == null ? _buildDefaultPromo() : _PromoCard(promo: p),
      loading: () => const SizedBox.shrink(),
      error:   (_, __) => _buildDefaultPromo(),
    );
  }

  Widget _buildDefaultPromo() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient:     HomeTheme.primaryGradient,
            borderRadius: BorderRadius.circular(24),
            boxShadow:    HomeTheme.primaryGlow,
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
                        color:        Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text('FIRST RIDE',
                          style: TextStyle(
                            color:         Colors.white,
                            fontSize:      9,
                            fontWeight:    FontWeight.w800,
                            letterSpacing: 1.5,
                          )),
                    ),
                    const SizedBox(height: 10),
                    const Text('50% off\nyour first ride',
                        style: TextStyle(
                          fontFamily:    'Inter',
                          color:         Colors.white,
                          fontSize:      22,
                          fontWeight:    FontWeight.w800,
                          height:        1.15,
                          letterSpacing: -0.5,
                        )),
                    const SizedBox(height: 14),
                    GestureDetector(
                      onTap: () => Navigator.pushNamed(
                          context, AppRoutes.promotions),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 9),
                        decoration: BoxDecoration(
                          color:        Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('Use code CTS50',
                            style: TextStyle(
                              fontFamily:  'Inter',
                              color:       HomeTheme.primary,
                              fontSize:    13,
                              fontWeight:  FontWeight.w800,
                            )),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.local_offer_rounded,
                  color: Colors.white.withValues(alpha: 0.15),
                  size:  90),
            ],
          ),
        ),
      );
}

// ═══════════════════════════════════════════════
// SHARED WIDGETS
// ═══════════════════════════════════════════════

class _PulsingDot extends StatefulWidget {
  final Color  color;
  final double size;
  const _PulsingDot({required this.color, this.size = 8});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync:    this,
    duration: const Duration(seconds: 1),
  )..repeat(reverse: true);

  late final Animation<double> _a =
      Tween<double>(begin: 0.4, end: 1.0).animate(_c);

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _a,
        child: Container(
          width:  widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color:  widget.color,
            shape:  BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color:      widget.color.withValues(alpha: 0.5),
                blurRadius: 6,
              ),
            ],
          ),
        ),
      );
}

class _TopIconButton extends StatelessWidget {
  final IconData     icon;
  final bool         badge;
  final int          badgeCount;
  final VoidCallback onTap;

  const _TopIconButton({
    required this.icon,
    this.badge      = false,
    this.badgeCount = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width:  42,
          height: 42,
          decoration: BoxDecoration(
            color:  Colors.white.withValues(alpha: 0.92),
            shape:  BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color:      Colors.black.withValues(alpha: 0.12),
                blurRadius: 12,
                offset:     const Offset(0, 3),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, color: const Color(0xFF0D1F14), size: 22),
              if (badge)
                Positioned(
                  right: 8, top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 3, vertical: 1),
                    decoration: BoxDecoration(
                      color:        AppColors.error,
                      borderRadius: BorderRadius.circular(10),
                      border:       Border.all(
                          color: Colors.white, width: 1.5),
                    ),
                    constraints: const BoxConstraints(
                        minWidth: 14, minHeight: 14),
                    child: Text(
                      badgeCount > 9 ? '9+' : '$badgeCount',
                      style: const TextStyle(
                        color:      Colors.white,
                        fontSize:   8,
                        fontWeight: FontWeight.w700,
                        height:     1,
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
  final _SavedPlace  place;
  final VoidCallback onTap;
  const _PlaceChip({required this.place, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width:   100,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color:        HomeTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(16),
            border:       Border.all(color: HomeTheme.border),
            boxShadow:    HomeTheme.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment:  MainAxisAlignment.center,
            children: [
              Container(
                width:  30,
                height: 30,
                decoration: BoxDecoration(
                  color:        HomeTheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(place.icon,
                    color: HomeTheme.primary, size: 16),
              ),
              const SizedBox(height: 7),
              Text(place.label,
                  style: const TextStyle(
                    fontFamily:  'Inter',
                    color:       HomeTheme.textPrimary,
                    fontSize:    12,
                    fontWeight:  FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      );
}

class _RecentTripTile extends StatelessWidget {
  final String       from, to, date;
  final double       fare;
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
        margin:  const EdgeInsets.fromLTRB(20, 0, 20, 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color:        HomeTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border:       Border.all(color: HomeTheme.border),
          boxShadow:    HomeTheme.cardShadow,
        ),
        child: Row(
          children: [
            Column(
              children: [
                Container(
                  width:  9,
                  height: 9,
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: HomeTheme.primary, width: 2),
                    shape: BoxShape.circle,
                  ),
                ),
                Container(
                    width: 1.5, height: 22,
                    color: HomeTheme.border),
                Container(
                  width:  9,
                  height: 9,
                  decoration: BoxDecoration(
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
                        fontFamily:  'Inter',
                        color:       HomeTheme.textPrimary,
                        fontSize:    13,
                        fontWeight:  FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Expanded(
                        child: Text(to,
                            style: TextStyle(
                              color:   HomeTheme.textTertiary,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                      Text(date,
                          style: TextStyle(
                            color:   HomeTheme.textTertiary,
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
                        fontFamily:  'Inter',
                        color:       HomeTheme.textPrimary,
                        fontSize:    13,
                        fontWeight:  FontWeight.w700,
                      )),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: onRebook,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color:        HomeTheme.primary
                          .withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: HomeTheme.primary
                            .withValues(alpha: 0.2),
                      ),
                    ),
                    child: Text('Rebook',
                        style: TextStyle(
                          fontFamily:  'Inter',
                          color:       HomeTheme.primary,
                          fontSize:    11,
                          fontWeight:  FontWeight.w700,
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

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color(int.parse(
                    promo.colorStart.replaceFirst('#', '0xFF'))),
                Color(int.parse(
                    promo.colorEnd.replaceFirst('#', '0xFF'))),
              ],
              begin: Alignment.topLeft,
              end:   Alignment.bottomRight,
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
                          color:         Colors.white70,
                          fontSize:      9,
                          letterSpacing: 1.5,
                          fontWeight:    FontWeight.w700,
                        )),
                    const SizedBox(height: 6),
                    Text(promo.title,
                        style: const TextStyle(
                          fontFamily:    'Inter',
                          color:         Colors.white,
                          fontSize:      20,
                          fontWeight:    FontWeight.w800,
                          height:        1.2,
                          letterSpacing: -0.4,
                        )),
                    if (promo.code != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color:        Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('Code: ${promo.code}',
                            style: TextStyle(
                              fontFamily:  'Inter',
                              color:       Color(int.parse(
                                  promo.colorStart
                                      .replaceFirst('#', '0xFF'))),
                              fontSize:    12,
                              fontWeight:  FontWeight.w800,
                            )),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.local_offer_rounded,
                  color: Colors.white.withValues(alpha: 0.15),
                  size:  80),
            ],
          ),
        ),
      );
}

// ─────────────────────────────────────────────────
// DATA MODELS
// ─────────────────────────────────────────────────

class _SavedPlace {
  final String   id;
  final String   label;
  final String   address;
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
      id:      doc.id,
      label:   d['label']   as String? ?? 'Place',
      address: d['address'] as String? ?? '',
    );
  }
}

class _PromoBanner {
  final String  title;
  final String  tag;
  final String? code;
  final String  colorStart;
  final String  colorEnd;

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
      title:      d['title']      as String? ?? '',
      tag:        d['tag']        as String? ?? 'OFFER',
      code:       d['code']       as String?,
      colorStart: d['colorStart'] as String? ?? '#16A34A',
      colorEnd:   d['colorEnd']   as String? ?? '#15803D',
    );
  }
}