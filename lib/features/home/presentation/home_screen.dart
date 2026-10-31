import 'dart:async';

import '../../../core/services/marker_service.dart';
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
import '../../ride/models/book_ride_args.dart';
import '../../ride/models/service_type.dart';
import '../../ride/services/last_vehicle_store.dart';
import '../services/driver_availability_service.dart';
import '../widgets/home_promo_card.dart';
import '../widgets/service_tile.dart';

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
      .orderBy('createdAt', descending: false)
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

  // True while a service screen is open, so rapid taps can't push twice.
  bool _openingService = false;
  String _locationLabel = 'Locating...';

  static const LatLng _accra = LatLng(5.6037, -0.1870);

  /// A confirmed pickup is required before booking can start.
  bool get _hasPickup => _userLocation != null && !_isLocating;

  /// A real GPS fix (not the Accra fallback used to centre the map). Only
  /// this is ever passed to a service as the pickup: a fallback point would
  /// send a driver somewhere the customer never chose.
  bool get _hasRealLocation => _hasPickup && !_usingFallbackLocation;

  /// Services open once the location lookup has finished, even if it
  /// failed: Gas and Delivery ask for their own address, and Ride retries
  /// GPS itself.
  bool get _servicesReady => !_isLocating;

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
      // Centre of the 5 km driver-marker search (driversNearbyProvider).
      ref.read(rideRequestProvider.notifier).setOrigin(
            _locationLabel,
            GeoPoint(ll.latitude, ll.longitude),
          );

      if (_isMapReady) {
        _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(CameraPosition(target: ll, zoom: 15)),
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
      final ms = MarkerService.instance;
      for (final d in drivers) {
        _markers.add(Marker(
          markerId: MarkerId('driver_${d.id}'),
          position: d.location,
          icon: ms.vehicle(d.serviceType),
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
      builder: (dialogCtx) => AlertDialog(
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
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Dismiss'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
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
  //
  // Ride bookings (no service, or Taxi / Okada / Pragyia) open BookRideScreen
  // with BookRideArgs; Delivery and Gas open their own screens as before.
  // [args] fills in what this entry knows; Home adds the current location.
  void _openBooking({
    ServiceType? service,
    BookRideArgs args = const BookRideArgs(),
  }) {
    if (_openingService) return;
    if (!_servicesReady) {
      _snack('Finding your location — one moment…');
      return;
    }
    HapticFeedback.lightImpact();

    final isRide = service == null || BookRideArgs.rideServices.contains(service);
    final route = isRide ? AppRoutes.bookRide : service.route;
    final current = _hasRealLocation ? _userLocation : null;

    _openingService = true;
    Navigator.pushNamed(
      context,
      route,
      arguments: isRide
          ? BookRideArgs(
              service: service,
              currentLocation: args.hasPickup ? null : current,
              pickupAddress: args.pickupAddress,
              pickupLocation: args.pickupLocation,
              destinationAddress: args.destinationAddress,
              destinationLocation: args.destinationLocation,
              openSearch: args.openSearch,
            ).toMap()
          : {
              'service': service,
              if (current != null) 'pickup': current,
            },
    ).whenComplete(() => _openingService = false);
  }

  /// Search bar: straight to destination entry, no vehicle chosen.
  void _openSearch() => _openBooking(args: homeSearchArgs);

  /// A vehicle tile: Taxi / Okada / Pragyia go straight to destination entry
  /// with that vehicle chosen (and remembered); Delivery and Gas open their
  /// own screens.
  void _onServiceTap(ServiceType service) {
    if (BookRideArgs.rideServices.contains(service)) {
      if (_servicesReady) ref.read(lastVehicleStoreProvider).save(service);
      _openBooking(service: service, args: vehicleTileArgs(service));
    } else {
      _openBooking(service: service);
    }
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
  // BUILD — header, search, services, map, promo, recent trips
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
                SliverToBoxAdapter(child: _buildSearchCard()),
                SliverToBoxAdapter(child: _buildServices()),
                SliverToBoxAdapter(child: _buildMapCard()),
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
  // HEADER — greeting + name, wallet, bell, avatar
  // ─────────────────────────────────────────────

  Widget _buildHeader() {
    final user = ref.watch(currentUserProvider).value;
    final firstName = user?.displayName?.split(' ').first ?? 'there';
    final photoUrl = user?.photoURL;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_greeting,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CtsText.bodySmall
                        .copyWith(fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Semantics(
                  header: true,
                  child: Text(firstName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CtsText.title1.copyWith(fontSize: 24)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _buildWalletChip(),
          const SizedBox(width: 8),
          Consumer(
            builder: (_, ref, __) {
              final count = ref.watch(unreadNotifCountProvider).value ?? 0;
              return _TopIconButton(
                icon: Icons.notifications_outlined,
                semanticLabel: count > 0
                    ? 'Notifications, $count unread'
                    : 'Notifications',
                badge: count > 0,
                badgeCount: count,
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.notifications),
              );
            },
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            label: 'Profile',
            child: GestureDetector(
              onTap: () => Navigator.pushNamed(context, AppRoutes.profile),
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: HomeTheme.border),
                ),
                padding: const EdgeInsets.all(2),
                child: ClipOval(
                  child: photoUrl != null && photoUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: photoUrl,
                          fit: BoxFit.cover,
                          memCacheWidth: 128,
                          placeholder: (_, __) =>
                              Container(color: HomeTheme.surfaceAlt),
                          errorWidget: (_, __, ___) =>
                              _avatarFallback(firstName),
                        )
                      : _avatarFallback(firstName),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWalletChip() {
    final balanceAsync = ref.watch(walletBalanceProvider);
    final label = switch (balanceAsync) {
      AsyncData(:final value) => 'GHS ${value.toStringAsFixed(2)}',
      AsyncLoading() => 'GHS —',
      _ => 'GHS 0.00',
    };
    return Semantics(
      button: true,
      label: 'Wallet balance $label',
      excludeSemantics: true,
      onTap: widget.onWalletTap,
      child: GestureDetector(
        onTap: widget.onWalletTap,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: HomeTheme.primaryTint,
            borderRadius: BorderRadius.circular(21),
            border: Border.all(color: HomeTheme.mintBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.account_balance_wallet_rounded,
                  color: HomeTheme.primaryDeep, size: 16),
              const SizedBox(width: 6),
              Text(label,
                  style: CtsText.label.copyWith(
                    color: HomeTheme.primaryDeep,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _avatarFallback(String name) => Container(
        color: HomeTheme.appleSoft,
        alignment: Alignment.center,
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : 'U',
          style: const TextStyle(
            color: HomeTheme.primaryDeep,
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
      );

  Widget _sectionTitle(String title,
          {String? action, VoidCallback? onAction}) =>
      Row(
        children: [
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CtsText.section.copyWith(fontSize: 17)),
          ),
          if (action != null)
            InkWell(
              onTap: onAction,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                child: Text(action,
                    style: CtsText.label.copyWith(
                      color: HomeTheme.primary,
                      fontSize: 14,
                    )),
              ),
            ),
        ],
      );

  // ── SEARCH: "Where to?" + pickup + saved places — the primary action ─────
  Widget _buildSearchCard() {
    final placesAsync = ref.watch(savedPlacesProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: HomeTheme.surface,
          borderRadius: BorderRadius.circular(HomeTheme.radiusXl),
          border: Border.all(color: HomeTheme.borderLight),
          boxShadow: HomeTheme.cardShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildWhereToField(),
            _buildPickupRow(),
            SizedBox(
              height: 40,
              child: placesAsync.when(
                data: (places) => _placesList(_placeChipsFor(places)),
                loading: () => _placesList(_defaultPlaces),
                error: (_, __) => _placesList(_defaultPlaces),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWhereToField() => Semantics(
        button: true,
        enabled: _servicesReady,
        label: _servicesReady
            ? 'Where to? Search your destination'
            : 'Getting your location',
        excludeSemantics: true,
        onTap: _servicesReady ? _openSearch : null,
        child: Material(
          color: HomeTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _servicesReady ? _openSearch : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  const Icon(Icons.search_rounded,
                      color: HomeTheme.textPrimary, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _servicesReady
                              ? 'Where to?'
                              : 'Finding your location…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CtsText.title3,
                        ),
                        const SizedBox(height: 1),
                        Text(
                          _servicesReady
                              ? 'Search your destination'
                              : 'This takes a few seconds',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CtsText.bodySmall.copyWith(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: _servicesReady ? 1 : 0.4,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: HomeTheme.apple,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.arrow_forward_rounded,
                          color: HomeTheme.textPrimary, size: 22),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  // Tapping the pickup line recentres the map on it; when there is no real
  // GPS fix it retries the location lookup instead.
  void _onPickupRowTap() =>
      _hasRealLocation || _isLocating ? _recenterMap() : _initLocation();

  Widget _buildPickupRow() => Semantics(
        button: true,
        label: _hasRealLocation || _isLocating
            ? 'Pickup, $_locationLabel. Recentre map'
            : 'Pickup, $_locationLabel. Try again',
        excludeSemantics: true,
        onTap: _onPickupRowTap,
        child: InkWell(
          onTap: _onPickupRowTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 12, 6, 10),
            child: Row(
              children: [
                _PulsingDot(color: HomeTheme.primary),
                const SizedBox(width: 10),
                const Text('Pickup', style: CtsText.caption),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _locationLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CtsText.label,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                    _hasRealLocation || _isLocating
                        ? Icons.my_location_rounded
                        : Icons.refresh_rounded,
                    color: HomeTheme.textSecondary,
                    size: 16),
              ],
            ),
          ),
        ),
      );

  // ── Services: image-led tiles ─────────────────────────────────────────────
  Widget _buildServices() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _sectionTitle('What do you need today?'),
            ),
            const SizedBox(height: 10),
            HomeServicesSection(onSelect: _onServiceTap),
          ],
        ),
      );

  // ── Live drivers map — a launcher, not a canvas ───────────────────────────
  Widget _buildMapCard() {
    final mapHeight =
        (MediaQuery.sizeOf(context).height * 0.2).clamp(150.0, 210.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: _sectionTitle('Drivers around you'),
          ),
          const SizedBox(height: 10),
          Container(
            height: mapHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: HomeTheme.border),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(19),
              child: Stack(
                children: [
                  Positioned.fill(child: _buildMap()),
                  // subtle top gradient for the pill legibility
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
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
                  // tap → opens booking; below the pill and recentre button
                  Positioned.fill(
                    child: Material(
                      color: Colors.transparent,
                      // Opens booking as before: no vehicle chosen (the
                      // booking screen never used this tap's Taxi hint).
                      child: InkWell(
                        onTap: _servicesReady ? () => _openBooking() : null,
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDriversPill() {
    // Count the live driver markers currently rendered.
    final count =
        _markers.where((m) => m.markerId.value.startsWith('driver_')).length;
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
        // Load the vehicle icons, then redraw any drivers already received.
        await MarkerService.instance.warmUp(context);
        if (!mounted) return;
        ref.read(driversNearbyProvider).whenData(_updateDriverMarkers);
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

  // ── Saved places (chips inside the search card) ───────────────────────────
  // Placeholders until the passenger saves a Home / Work: their text is a
  // prompt, not an address (configured: false).
  static const List<_SavedPlace> _defaultPlaces = [
    _SavedPlace(
        id: 'home',
        label: 'Home',
        address: 'Set home address',
        icon: Icons.home_rounded,
        configured: false),
    _SavedPlace(
        id: 'work',
        label: 'Work',
        address: 'Set work address',
        icon: Icons.work_rounded,
        configured: false),
  ];

  List<_SavedPlace> _placeChipsFor(List<_SavedPlace> places) {
    final saved = places.take(4).toList(); // home strip shows ≤4
    return [
      ..._defaultPlaces.where((d) =>
          !saved.any((p) => p.label.toLowerCase() == d.label.toLowerCase())),
      ...saved,
      _SavedPlace(
          id: 'add',
          label: saved.isEmpty ? 'Add place' : 'All places',
          address: '',
          icon: saved.isEmpty ? Icons.add_rounded : Icons.bookmarks_rounded,
          configured: false),
    ];
  }

  Widget _placesList(List<_SavedPlace> places) => ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        itemCount: places.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => _PlaceChip(
          place: places[i],
          onTap: () => _onSavedPlaceTap(places[i]),
        ),
      );

  /// A saved place is the destination, with its saved coordinates when it
  /// has them, and the passenger's last vehicle (if any) chosen. A Home or
  /// Work placeholder opens Saved Places to set it up instead.
  Future<void> _onSavedPlaceTap(_SavedPlace place) async {
    if (savedPlaceArgs(configured: place.configured, address: place.address) ==
        null) {
      Navigator.pushNamed(context, AppRoutes.savedPlaces);
      return;
    }
    if (_openingService) return;
    final vehicle = await ref.read(lastVehicleStoreProvider).read();
    if (!mounted) return;
    final args = savedPlaceArgs(
      configured: place.configured,
      address: place.address,
      lat: place.lat,
      lng: place.lng,
      lastVehicle: vehicle,
    )!;
    _openBooking(service: args.service, args: args);
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
              padding: const EdgeInsets.fromLTRB(20, 24, 16, 6),
              child: _sectionTitle(
                'Recent trips',
                action: 'See all',
                onAction: widget.onHistoryTap ??
                    () => Navigator.pushNamed(context, AppRoutes.tripHistory),
              ),
            ),
            ...docs.map((doc) {
              final d = doc.data() as Map<String, dynamic>;
              final ts = d['createdAt'] as Timestamp?;
              final date =
                  ts != null ? DateFormat('MMM d').format(ts.toDate()) : '';
              final rebook = rebookArgsFromTrip(d);
              return _RecentTripTile(
                from: d['pickupAddress'] as String? ?? '—',
                to: d['dropoffAddress'] as String? ?? '—',
                fare: (d['actualFare'] as num?)?.toDouble() ?? 0,
                date: date,
                // Rebook: the trip's own pickup, destination and vehicle.
                onRebook: () =>
                    _openBooking(service: rebook.service, args: rebook),
              );
            }),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
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
  // An active admin promotion (Firestore) wins; otherwise an editorial card for
  // an existing service. The fallback states no discount or reward.
  Widget _buildPromoBanner() {
    final promoAsync = ref.watch(promoBannerProvider);
    final Widget card = switch (promoAsync) {
      AsyncLoading() when !promoAsync.hasValue => const SizedBox.shrink(),
      AsyncData(:final value?) => _promoCardFor(value),
      _ => _buildDefaultPromo(),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: card,
    );
  }

  Widget _promoCardFor(_PromoBanner promo) => HomePromoCard(
        title: promo.title,
        subtitle: promo.subtitle,
        background:
            _parseHexColor(promo.backgroundColor, HomeTheme.primaryDeep),
        trailing: promo.imageUrl.isEmpty
            ? null
            : ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: CachedNetworkImage(
                  imageUrl: promo.imageUrl,
                  width: 84,
                  height: 84,
                  fit: BoxFit.cover,
                  memCacheWidth: 256,
                  placeholder: (_, __) => const SizedBox(width: 84, height: 84),
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
      );

  Widget _buildDefaultPromo() => HomePromoCard(
        eyebrow: 'CTSGo Gas',
        title: 'Cooking gas, delivered',
        subtitle: 'Order a refill and track it to your door.',
        ctaLabel: 'Order gas',
        onTap: () => _openBooking(service: ServiceType.gas),
        trailing: SizedBox(
          width: 100,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child:
                const ServiceImage(service: ServiceType.gas, aspectRatio: 0.85),
          ),
        ),
      );
}

// ═══════════════════════════════════════════════
// SHARED WIDGETS
// ═══════════════════════════════════════════════

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
  final String semanticLabel;
  final bool badge;
  final int badgeCount;
  final VoidCallback onTap;

  const _TopIconButton({
    required this.icon,
    required this.semanticLabel,
    this.badge = false,
    this.badgeCount = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: semanticLabel,
        excludeSemantics: true,
        onTap: onTap,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: HomeTheme.surface,
              shape: BoxShape.circle,
              border: Border.all(color: HomeTheme.border),
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
                        border:
                            Border.all(color: HomeTheme.surface, width: 1.5),
                      ),
                      constraints:
                          const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text(
                        badgeCount > 9 ? '9+' : '$badgeCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
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
        ),
      );
}

class _PlaceChip extends StatelessWidget {
  final _SavedPlace place;
  final VoidCallback onTap;
  const _PlaceChip({required this.place, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: HomeTheme.surface,
        shape: const StadiumBorder(side: BorderSide(color: HomeTheme.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(place.icon, color: HomeTheme.primaryDeep, size: 16),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(place.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        color: HomeTheme.textPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      )),
                ),
              ],
            ),
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
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
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
                            fontSize: 12,
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
                  Text('GHS ${fare.toStringAsFixed(2)}',
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
                          fontSize: 12,
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

// Parse a hex string ('#RRGGBB' or 'RRGGBB', 6 or 8 digits) to a Color,
// falling back to [fallback] if it's malformed.
Color _parseHexColor(String hex, Color fallback) {
  try {
    final cleaned = hex.replaceAll('#', '').trim();
    final value = cleaned.length == 6 ? 'FF$cleaned' : cleaned;
    return Color(int.parse(value, radix: 16));
  } catch (_) {
    return fallback;
  }
}

// ─────────────────────────────────────────────────
// DATA MODELS
// ─────────────────────────────────────────────────

// Map saved-place icon keys (from Firestore) to IconData.
IconData _homeIconFor(String key) =>
    const {
      'home': Icons.home_rounded,
      'work': Icons.business_rounded,
      'gym': Icons.fitness_center_rounded,
      'hospital': Icons.local_hospital_rounded,
      'school': Icons.school_rounded,
      'food': Icons.restaurant_rounded,
      'place': Icons.place_rounded,
    }[key] ??
    Icons.place_rounded;

class _SavedPlace {
  final String id;
  final String label;
  final String address;
  final IconData icon;
  final double? lat;
  final double? lng;
  final String? placeId;

  /// False for the Home / Work placeholders and the "Add place" chip.
  final bool configured;

  const _SavedPlace({
    required this.id,
    required this.label,
    required this.address,
    this.icon = Icons.place_rounded,
    this.lat,
    this.lng,
    this.placeId,
    this.configured = true,
  });

  factory _SavedPlace.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return _SavedPlace(
      id: doc.id,
      label: d['label'] as String? ?? 'Place',
      address: d['address'] as String? ?? '',
      icon: _homeIconFor(d['iconKey'] as String? ?? 'place'),
      lat: (d['lat'] as num?)?.toDouble(),
      lng: (d['lng'] as num?)?.toDouble(),
      placeId: d['placeId'] as String?,
    );
  }
}

class _PromoBanner {
  final String title;
  final String subtitle;
  final String backgroundColor;
  final String imageUrl;

  const _PromoBanner({
    required this.title,
    required this.subtitle,
    required this.backgroundColor,
    required this.imageUrl,
  });

  factory _PromoBanner.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return _PromoBanner(
      title: d['title'] as String? ?? '',
      subtitle: d['subtitle'] as String? ?? '',
      backgroundColor: d['backgroundColor'] as String? ?? '#16A34A',
      imageUrl: d['imageUrl'] as String? ?? '',
    );
  }
}
