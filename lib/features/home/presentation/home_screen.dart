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

import '../../../core/routes/app_routes.dart';
import '../../../features/auth/providers/auth_providers.dart';
import '../../home/services/location_services.dart';
import '../services/driver_availability_service.dart';
import '../widgets/location_permission_dialog.dart';
import '../../home/extensions/service_type_extensions.dart';
import '../../home/theme/home_theme.dart';
import '../../ride/models/service_type.dart';

// ─────────────────────────────────────────────────
// PROVIDERS (unchanged)
// ─────────────────────────────────────────────────

final locationService = LocationService.instance;

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
  return FirebaseFirestore.instance
      .collection('passengers')
      .doc(uid)
      .collection('savedPlaces')
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
  // ── Map ────────────────────────────────────────
  GoogleMapController? _mapController;
  LatLng? _userLocation;
  final Set<Marker> _markers = {};
  bool _isMapReady = false;
  Timer? _debounceTimer;
  StreamSubscription<Position>? _locationSub;

  // ── State ──────────────────────────────────────
  ServiceType _selectedService = ServiceType.taxi;
  bool _isLocating = true;
  String _locationLabel = 'Locating...';

  // ── Sheet ──────────────────────────────────────
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  // ── Animation ─────────────────────────────────
  late AnimationController _chipAnimController;
  late AnimationController _sheetAnimController;

  static const LatLng _accra = LatLng(5.6037, -0.1870);

  // ── Greeting ───────────────────────────────────
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
      vsync: this,
      duration: const Duration(milliseconds: 350),
    )..forward();
    _sheetAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _initLocation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkLocationOnResume();
  }

  Future<void> _checkLocationOnResume() async {
    final ok = await _checkLocationPermission();
    if (ok && _userLocation == null) _initLocation();
  }

  Future<bool> _checkLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    final p = await Geolocator.checkPermission();
    return p == LocationPermission.always || p == LocationPermission.whileInUse;
  }

  // ── Location ───────────────────────────────────

  Future<void> _initLocation() async {
    setState(() => _isLocating = true);
    try {
      final pos = await LocationService.instance.getCurrentLocation();
      if (!mounted) return;
      final ll = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _userLocation = ll;
        _isLocating = false;
      });
      if (_isMapReady) {
        _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(CameraPosition(target: ll, zoom: 15)),
        );
      }
      _updateUserMarker(ll);
      await _startLocationUpdates();
      await _updateLocationLabel(ll);
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLocating = false;
          _locationLabel = 'Location unavailable';
        });
        _showLocationErrorDialog();
      }
    }
  }

  Future<void> _startLocationUpdates() async {
    await LocationService.instance.startListening(
      onSignificantMove: (d) {
        if (mounted && d > 50) _recenterMap();
      },
    );
    _locationSub?.cancel();
    _locationSub = LocationService.instance.positionStream.listen((pos) {
      if (!mounted) return;
      final ll = LatLng(pos.latitude, pos.longitude);
      setState(() => _userLocation = ll);
      _updateUserMarker(ll);
    });
  }

  Future<void> _updateLocationLabel(LatLng ll) async {
    final label = await LocationService.instance.reverseGeocode(ll);
    if (mounted) setState(() => _locationLabel = label);
  }

  void _updateUserMarker(LatLng pos) {
    setState(() {
      _markers
        ..removeWhere((m) => m.markerId.value == 'user')
        ..add(Marker(
          markerId: const MarkerId('user'),
          position: pos,
          icon:
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
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

  void _showLocationErrorDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => LocationPermissionDialog(
        message: 'Location access is required to find nearby drivers.',
        onRetry: _initLocation,
      ),
    );
  }

  // ── Service selection ──────────────────────────

  Future<void> _selectService(ServiceType service) async {
    HapticFeedback.selectionClick();
    setState(() => _selectedService = service);
    _chipAnimController
      ..reset()
      ..forward();
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
    _sheetAnimController.dispose();
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
            // 1 ── Full-screen map
            _buildMap(),

            // 2 ── Top fade gradient
            _buildTopFade(),

            // 3 ── Top bar
            Positioned(
              top: topPad + 8,
              left: 16,
              right: 16,
              child: _buildTopBar(),
            ),

            // 4 ── Recenter FAB
            Positioned(
              right: 16,
              bottom: _sheetMinHeight(context) + 16,
              child: _buildRecenterFab(),
            ),

            // 5 ── Bottom sheet (the star)
            _buildBottomSheet(),
          ],
        ),
      ),
    );
  }

  double _sheetMinHeight(BuildContext context) =>
      MediaQuery.of(context).size.height * 0.42;

  // ─────────────────────────────────────────────
  // MAP
  // ─────────────────────────────────────────────

  static const String _mapStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#16213e"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#8ec3b9"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#1a3646"}]},
  {"featureType":"administrative.country","elementType":"geometry.stroke","stylers":[{"color":"#4b6878"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#304a7d"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#2c6675"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#98a5be"}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#1a3a4a"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0d1b2a"}]},
  {"featureType":"poi","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#1a2e1a"}]}
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
      onCameraMove: (_) {},
    );
  }

  // ─────────────────────────────────────────────
  // TOP FADE & TOP BAR
  // ─────────────────────────────────────────────

  Widget _buildTopFade() => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          height: 160,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.72),
                Colors.transparent,
              ],
            ),
          ),
        ),
      );

  Widget _buildTopBar() {
    final user = ref.watch(currentUserProvider).value;
    final firstName = user?.displayName?.split(' ').first ?? 'there';
    final photoUrl = user?.photoURL;

    return Row(
      children: [
        // ── Location pill ──
        Expanded(
          child: GestureDetector(
            onTap: _recenterMap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(50),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4))
                ],
              ),
              child: Row(
                children: [
                  _PulsingDot(color: HomeTheme.primary),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      _isLocating ? 'Locating...' : _locationLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.expand_more_rounded,
                      color: Colors.white60, size: 18),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),

        // ── Notifications ──
        _TopIconButton(
          icon: Icons.notifications_outlined,
          badge: true,
          onTap: () => Navigator.pushNamed(context, AppRoutes.notifications),
        ),
        const SizedBox(width: 10),

        // ── Avatar ──
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, AppRoutes.profile),
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: HomeTheme.primary, width: 2),
              boxShadow: [
                BoxShadow(
                    color: HomeTheme.primary.withValues(alpha: 0.35),
                    blurRadius: 10,
                    spreadRadius: 1)
              ],
            ),
            child: ClipOval(
              child: photoUrl != null
                  ? CachedNetworkImage(
                      imageUrl: photoUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          Container(color: HomeTheme.surfaceAlt),
                      errorWidget: (_, __, ___) => _avatarFallback(firstName),
                    )
                  : _avatarFallback(firstName),
            ),
          ),
        ),
      ],
    );
  }

  Widget _avatarFallback(String name) => Container(
        color: HomeTheme.surface,
        alignment: Alignment.center,
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : 'U',
          style: const TextStyle(
              color: HomeTheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: 17),
        ),
      );

  // ─────────────────────────────────────────────
  // RECENTER FAB
  // ─────────────────────────────────────────────

  Widget _buildRecenterFab() => GestureDetector(
        onTap: _recenterMap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: HomeTheme.surface,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 16,
                  offset: const Offset(0, 6))
            ],
          ),
          child: const Icon(Icons.my_location_rounded,
              color: HomeTheme.primary, size: 22),
        ),
      );

  // ─────────────────────────────────────────────
  // BOTTOM SHEET
  // ─────────────────────────────────────────────

  Widget _buildBottomSheet() {
    final user = ref.watch(currentUserProvider).value;
    final firstName = user?.displayName?.split(' ').first ?? 'there';

    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: 0.44,
      minChildSize: 0.16,
      maxChildSize: 0.92,
      snap: true,
      snapSizes: const [0.16, 0.44, 0.92],
      builder: (ctx, sc) => Container(
        decoration: const BoxDecoration(
          color: HomeTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: RefreshIndicator(
          onRefresh: _refreshData,
          color: HomeTheme.primary,
          child: CustomScrollView(
            controller: sc,
            physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics()),
            slivers: [
              SliverToBoxAdapter(child: _buildDragHandle()),
              SliverToBoxAdapter(child: _buildSheetHeader(firstName)),
              SliverToBoxAdapter(child: _buildServiceGrid()),
              SliverToBoxAdapter(child: _buildSearchBar()),
              SliverToBoxAdapter(child: _buildNearbyBadge()),
              SliverToBoxAdapter(child: _buildSavedPlaces()),
              SliverToBoxAdapter(child: _buildRecentTrips()),
              SliverToBoxAdapter(child: _buildPromoBanner()),
              SliverToBoxAdapter(
                child: SizedBox(
                    height: MediaQuery.of(context).padding.bottom + 24),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Drag handle ────────────────────────────────

  Widget _buildDragHandle() => Center(
        child: Container(
          width: 38,
          height: 4,
          margin: const EdgeInsets.only(top: 12, bottom: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  // ── Sheet header ───────────────────────────────

  Widget _buildSheetHeader(String firstName) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _greeting,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  firstName,
                  style: const TextStyle(
                    color: HomeTheme.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
            // Wallet / balance chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: HomeTheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                    color: HomeTheme.primary.withValues(alpha: 0.25), width: 1),
              ),
              child: Row(
                children: [
                  const Icon(Icons.account_balance_wallet_rounded,
                      color: HomeTheme.primary, size: 16),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: widget.onWalletTap,
                    child: const Text(
                      'Wallet',
                      style: TextStyle(
                        color: HomeTheme.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  // ── Service grid ───────────────────────────────

  Widget _buildServiceGrid() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      child: Row(
        children: ServiceType.values.map((svc) {
          final selected = svc == _selectedService;
          return Expanded(
            child: GestureDetector(
              onTap: () => _selectService(svc),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: selected
                      ? HomeTheme.primary.withValues(alpha: 0.15)
                      : HomeTheme.surfaceAlt,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: selected
                        ? HomeTheme.primary.withValues(alpha: 0.6)
                        : Colors.white.withValues(alpha: 0.06),
                    width: selected ? 1.5 : 1,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: HomeTheme.primary.withValues(alpha: 0.25),
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          )
                        ]
                      : null,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 280),
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: selected ? HomeTheme.primaryGradient : null,
                        color: selected ? null : HomeTheme.background,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        svc.icon,
                        color: selected
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.6),
                        size: 20,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      svc.displayName,
                      style: TextStyle(
                        color: selected
                            ? HomeTheme.primary
                            : Colors.white.withValues(alpha: 0.55),
                        fontSize: 11,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        letterSpacing: 0.1,
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
  }

  // ── Search bar ─────────────────────────────────

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: GestureDetector(
        onTap: _goToSearch,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          decoration: BoxDecoration(
            color: HomeTheme.background,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: HomeTheme.primary.withValues(alpha: 0.25),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: HomeTheme.primary.withValues(alpha: 0.08),
                blurRadius: 20,
                offset: const Offset(0, 4),
              )
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: HomeTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.search_rounded,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _selectedService.searchHint,
                      style: const TextStyle(
                        color: HomeTheme.textPrimary,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Enter your destination',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: HomeTheme.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_selectedService.icon,
                        color: HomeTheme.primary, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      _selectedService.displayName,
                      style: const TextStyle(
                        color: HomeTheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Nearby drivers badge ───────────────────────

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
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'LIVE',
                  style: TextStyle(
                    color: Colors.green[400],
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  // ── Saved places ───────────────────────────────

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
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Quick destinations',
                  style: TextStyle(
                    color: HomeTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  )),
              GestureDetector(
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.savedPlaces),
                child: Text('Edit',
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
            error: (_, __) => const SizedBox.shrink(),
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
    Navigator.pushNamed(context, _selectedService.route, arguments: {
      'service': _selectedService,
      'destinationLabel': place.label,
      'destinationAddress': place.address,
    });
  }

  // ── Recent trips ───────────────────────────────

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
        if (!snap.hasData || snap.data!.docs.isEmpty) {
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
                  const Text('Recent trips',
                      style: TextStyle(
                        color: HomeTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      )),
                  GestureDetector(
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.tripHistory),
                    child: Text('See all',
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
              return _RecentTripTile(
                from: d['pickupAddress'] as String? ?? '—',
                to: d['dropoffAddress'] as String? ?? '—',
                fare: (d['actualFare'] as num?)?.toDouble() ?? 0,
                date: date,
                onRebook: () => Navigator.pushNamed(
                  context,
                  _selectedService.route,
                  arguments: {
                    'pickupAddress': d['pickupAddress'],
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
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: HomeTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: HomeTheme.background,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.route_rounded,
                    color: Colors.white.withValues(alpha: 0.3), size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('No trips yet',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        )),
                    const SizedBox(height: 3),
                    Text('Your completed trips will appear here',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 12,
                        )),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  // ── Promo banner ───────────────────────────────

  Widget _buildPromoBanner() {
    final promoAsync = ref.watch(promoBannerProvider);
    return promoAsync.when(
      data: (promo) =>
          promo == null ? _buildDefaultPromo() : _PromoCard(promo: promo),
      loading: () => const SizedBox.shrink(),
      error: (_, __) => _buildDefaultPromo(),
    );
  }

  Widget _buildDefaultPromo() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: HomeTheme.primaryGradient,
            borderRadius: BorderRadius.circular(22),
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
                        color: Colors.white.withValues(alpha: 0.2),
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
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                          letterSpacing: -0.4,
                        )),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () =>
                          Navigator.pushNamed(context, AppRoutes.promotions),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('Use code CTS50',
                            style: TextStyle(
                              color: HomeTheme.primary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                            )),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.local_offer_rounded,
                  color: Colors.white.withValues(alpha: 0.2), size: 80),
            ],
          ),
        ),
      );
}

// ═══════════════════════════════════════════════
// SUPPORTING WIDGETS
// ═══════════════════════════════════════════════

/// Pulsing green dot (used for location + live badge).
class _PulsingDot extends StatefulWidget {
  final Color color;
  final double size;
  const _PulsingDot({required this.color, this.size = 8});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..repeat(reverse: true);
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
                  color: widget.color.withValues(alpha: 0.6), blurRadius: 6)
            ],
          ),
        ),
      );
}

/// Icon button used in the top bar.
class _TopIconButton extends StatelessWidget {
  final IconData icon;
  final bool badge;
  final VoidCallback onTap;

  const _TopIconButton(
      {required this.icon, this.badge = false, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              if (badge)
                Positioned(
                  right: 9,
                  top: 9,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: HomeTheme.danger,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

/// Quick destination chip.
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
            color: HomeTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: HomeTheme.background,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(place.icon, color: HomeTheme.primary, size: 16),
              ),
              const SizedBox(height: 7),
              Text(
                place.label,
                style: const TextStyle(
                  color: HomeTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
}

/// Recent trip list tile.
class _RecentTripTile extends StatelessWidget {
  final String from;
  final String to;
  final double fare;
  final String date;
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
          color: HomeTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            // Route dots
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
            // Addresses
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(from,
                      style: const TextStyle(
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
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        date,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.3),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Fare + rebook
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  fare > 0 ? '₵${fare.toStringAsFixed(2)}' : '',
                  style: const TextStyle(
                    color: HomeTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: onRebook,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: HomeTheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: HomeTheme.primary.withValues(alpha: 0.3)),
                    ),
                    child: const Text(
                      'Rebook',
                      style: TextStyle(
                        color: HomeTheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

/// Dynamic promo card from Firestore.
class _PromoCard extends StatelessWidget {
  final _PromoBanner promo;
  const _PromoCard({required this.promo});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color(int.parse(promo.colorStart.replaceFirst('#', '0xFF'))),
                Color(int.parse(promo.colorEnd.replaceFirst('#', '0xFF'))),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(22),
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
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                          letterSpacing: -0.3,
                        )),
                    if (promo.code != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('Code: ${promo.code}',
                            style: TextStyle(
                              color: Color(int.parse(
                                  promo.colorStart.replaceFirst('#', '0xFF'))),
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            )),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.local_offer_rounded,
                  color: Colors.white.withValues(alpha: 0.2), size: 72),
            ],
          ),
        ),
      );
}

// ─────────────────────────────────────────────────
// DATA MODELS (private, same file)
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
      colorStart: d['colorStart'] as String? ?? '#00C566',
      colorEnd: d['colorEnd'] as String? ?? '#00A855',
    );
  }
}
