// lib/features/ride/presentation/screens/book_ride_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cts_transport_app/features/payment/models/payment_method.dart';
import '../../ride/services/route_service.dart';

import '../../../core/services/pricing_service.dart';
import '../../../core/services/escrow_service.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/constants/app_colors.dart';
import '../../bookings/service_request_manager.dart';
import '../constants/ride_constants.dart';
import '../providers/ride_request_provider.dart';
import '../providers/wallet_provider.dart';
import '../widgets/active_request_banner.dart';
import '../widgets/map_section.dart';
import '../widgets/route_summary.dart';
import '../widgets/ride_options_list.dart';
import '../widgets/confirm_ride_bar.dart';
import '../widgets/empty_destination_state.dart';
import 'driver_matching_screen.dart';
import 'destination_search_screen.dart';
import '../widgets/payment_method_sheet.dart';

class BookRideScreen extends ConsumerStatefulWidget {
  final ScrollController? scrollController;
  const BookRideScreen({super.key, this.scrollController});

  @override
  ConsumerState<BookRideScreen> createState() => _BookRideScreenState();
}

class _BookRideScreenState extends ConsumerState<BookRideScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fabController;
  late final Animation<double> _fabAnim;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarBrightness: Brightness.dark,
      statusBarIconBrightness: Brightness.light,
    ));

    _fabController = AnimationController(
      vsync: this,
      duration: RideConstants.fabAnimationDuration,
    );
    _fabAnim = CurvedAnimation(
      parent: _fabController,
      curve: Curves.easeOutBack,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Route args from Home (service / pickup / destinationAddress).
      final args =
          ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

      // Fresh booking session.
      ref.read(rideRequestProvider.notifier).reset();
      await PricingService.instance.fetch(force: true);
      if (!mounted) return;

      // Pickup: use the one Home already resolved; only re-acquire if absent.
      if (args != null && args['pickup'] is LatLng) {
        await _applyPickupFromArgs(args['pickup'] as LatLng);
      } else {
        await _initUserLocation();
      }
      if (!mounted) return;

      // Destination: a saved place / rebook passes an address → geocode it so
      // the options list appears immediately (skips the empty state).
      final destAddress = args?['destinationAddress'] as String?;
      if (destAddress != null && destAddress.trim().isNotEmpty) {
        await _applyDestinationFromArgs(destAddress);
      }
      if (!mounted) return;

      // // Service hint from Home (rebook / launcher). Pre-selecting the matching
      // // RideOption needs the provider's select API — wire once confirmed:
      //   final svc = args?['service'] as ServiceType?;
      //   if (svc != null) ref.read(rideRequestProvider.notifier).preselectService(svc);

      ref.listenManual(
        rideRequestProvider.select((s) => s.isDestinationSet),
        (_, isSet) =>
            isSet ? _fabController.forward() : _fabController.reverse(),
      );
    });
  }

  // ── Pickup straight from Home (no second GPS prompt) ──────────────────────
  Future<void> _applyPickupFromArgs(LatLng pickup) async {
    String address = 'Current location';
    try {
      final pm =
          await placemarkFromCoordinates(pickup.latitude, pickup.longitude);
      final p = pm.first;
      address = p.street ?? p.subLocality ?? p.locality ?? address;
    } catch (_) {/* keep generic label */}
    if (!mounted) return;
    ref.read(rideRequestProvider.notifier).setOrigin(
          address,
          GeoPoint(pickup.latitude, pickup.longitude),
        );
  }

  // ── Destination from a passed address (saved place / rebook) ──────────────
  Future<void> _applyDestinationFromArgs(String destAddress) async {
    try {
      final locs = await locationFromAddress(destAddress);
      if (locs.isEmpty || !mounted) return;
      final loc = locs.first;
      final origin = ref.read(rideRequestProvider).pickupLocation;
      final km = origin == null
          ? RideConstants.defaultDistanceKm
          : Geolocator.distanceBetween(
                origin.latitude,
                origin.longitude,
                loc.latitude,
                loc.longitude,
              ) /
              1000.0;
      final mins = (km / 30.0 * 60).ceil(); // rough ETA; refined by options
      ref.read(rideRequestProvider.notifier).setDestination(
            destAddress,
            GeoPoint(loc.latitude, loc.longitude),
            km,
            mins,
          );
    } catch (_) {
      // Geocode failed — leave destination empty; user searches manually.
    }
  }

  Future<void> _initUserLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final placemarks =
          await placemarkFromCoordinates(position.latitude, position.longitude);
      final place = placemarks.first;
      final address = place.street ??
          place.subLocality ??
          place.locality ??
          'Current location';
      if (mounted) {
        ref.read(rideRequestProvider.notifier).setOrigin(
              address,
              GeoPoint(position.latitude, position.longitude),
            );
      }
    } catch (_) {
      if (mounted) {
        ref.read(rideRequestProvider.notifier).setOrigin(
              RideConstants.defaultOrigin,
              GeoPoint(
                RideConstants.defaultPickupCoordinates.latitude,
                RideConstants.defaultPickupCoordinates.longitude,
              ),
            );
      }
    }
  }

  @override
  void dispose() {
    _fabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rideState = ref.watch(rideRequestProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: ref.watch(activeServiceRequestProvider).when(
            loading: () => _buildBody(rideState),
            error: (_, __) => _buildBody(rideState),
            data: (active) => _buildBody(rideState, activeRequest: active),
          ),
    );
  }

  Widget _buildBody(
    RideRequestState state, {
    ServiceRequestWrapper? activeRequest,
  }) {
    return Stack(
      children: [
        // ── Map fills the screen ──
        Positioned.fill(
          child: MapSection(state: state, onMapTap: _openDestinationSearch),
        ),

        // ── Active request banner (top overlay) ──
        if (activeRequest != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: ActiveRequestBanner(
                request: activeRequest,
                onTap: () => _navigateToTracking(activeRequest),
              ),
            ),
          ),

        // ── Draggable content sheet over the map ──
        DraggableScrollableSheet(
          initialChildSize: 0.45,
          minChildSize: 0.22,
          maxChildSize: 0.88,
          snap: true,
          snapSizes: const [0.22, 0.45, 0.88],
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 20,
                      offset: Offset(0, -4)),
                ],
              ),
              child: CustomScrollView(
                controller: scrollController,
                slivers: [
                  SliverToBoxAdapter(child: _buildDragHandle()),
                  SliverToBoxAdapter(
                    child: RouteSummary(
                      state: state,
                      onDestinationTap: _openDestinationSearch,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: state.isDestinationSet
                        ? RideOptionsList(
                            state: state,
                            onShowPaymentSheet: _showPaymentSheet,
                          )
                        : EmptyDestinationState(
                            onSearchTap: _openDestinationSearch),
                  ),
                  // clearance so last item isn't hidden behind the confirm bar
                  const SliverToBoxAdapter(child: SizedBox(height: 110)),
                ],
              ),
            );
          },
        ),

        // ── Confirm bar pinned at the bottom ──
        if (state.isDestinationSet)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: ConfirmRideBar(
              state: state,
              animation: _fabAnim,
              onConfirm: () => _confirmRide(state),
            ),
          ),
      ],
    );
  }

  Widget _buildDragHandle() => Center(
        child: Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: Colors.grey[300],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  // ---------------------------------------------------------------------------
  // Navigation & Actions
  // ---------------------------------------------------------------------------

  Future<void> _openDestinationSearch() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => DestinationSearchScreen(
          origin: ref.read(rideRequestProvider).origin ?? 'Current Location',
        ),
        fullscreenDialog: true,
      ),
    );

    if (!mounted || result is! Map<String, dynamic>) return;

    final destLoc = result['location'] as GeoPoint;
    final origin = ref.read(rideRequestProvider).pickupLocation;

    // Compute REAL road distance via Directions (like delivery A5).
    double km = (result['distance'] as double?) ?? 0;
    int mins = (result['duration'] as int?) ?? 0;

    if (origin != null) {
      try {
        final route = await ref.read(routeServiceProvider).getRoute(
              LatLng(origin.latitude, origin.longitude),
              LatLng(destLoc.latitude, destLoc.longitude),
            );
        if (route != null) {
          km = route.distanceKm;
          mins = route.durationMin;
        }
      } catch (_) {/* fall through to straight-line */}

      // Honest straight-line fallback if Directions failed.
      if (km <= 0) {
        km = Geolocator.distanceBetween(
              origin.latitude,
              origin.longitude,
              destLoc.latitude,
              destLoc.longitude,
            ) /
            1000.0;
        mins = (km / 30.0 * 60).ceil();
      }
    }

    if (km <= 0) km = RideConstants.defaultDistanceKm; // last resort

    if (!mounted) return;
    ref.read(rideRequestProvider.notifier).setDestination(
          result['address'] as String,
          destLoc,
          km,
          mins,
        );
  }

  Future<void> _confirmRide(RideRequestState state) async {
    // ✅ Double-tap guard (read fresh, not the captured snapshot).
    if (ref.read(rideRequestProvider).isLoading) return;

    // ✅ No second concurrent trip.
    if (ref.read(activeServiceRequestProvider).value != null) {
      _showErrorSnack('You already have an active trip in progress.');
      return;
    }

    if (!state.hasValidLocations) {
      _showErrorSnack(RideConstants.errorMissingLocations);
      return;
    }
    if (state.selectedRide == null) {
      _showErrorSnack('Please select a ride option');
      return;
    }

    HapticFeedback.heavyImpact();
    ref.read(rideRequestProvider.notifier).setLoading(true);

    String escrowId = '';
    // ✅ Only wallet payments hold escrow. Cash is collected by the driver.
    final usesEscrow = state.paymentMethod == PaymentType.wallet;

    try {
      final selectedRide = state.selectedRide!;
      final fare = state.calculatedFare;

      // ── Step 1: hold funds (wallet only) ─────────────────────────────────
      if (usesEscrow) {
        final escrowResult = await EscrowService.instance.holdBalance(
          amount: fare,
          serviceType: selectedRide.serviceType.name,
          referenceType: 'trip',
        );

        if (!escrowResult.success) {
          if (mounted) {
            final shortfall = escrowResult.shortfall;
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                title: const Text('Insufficient Balance',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                content: Text(
                  shortfall != null
                      ? 'You need GH\u20b5${shortfall.toStringAsFixed(2)} more. Please top up your wallet.'
                      : escrowResult.error ?? 'Payment hold failed.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      Navigator.of(context, rootNavigator: true)
                          .pushNamed('/wallet');
                    },
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A)),
                    child: const Text('Top Up Wallet'),
                  ),
                ],
              ),
            );
          }
          return; // finally sets loading=false; no escrow held
        }

        escrowId = escrowResult.escrowId!;
      }

      // ── Step 2: create the trip WITH the escrowId baked in ───────────────
      //    (no post-create update — the package-2 rules forbid touching
      //     escrowId after creation, and this avoids the crash window.)
      final tripId =
          await ref.read(tripRequestCreatorProvider.notifier).createTripRequest(
                serviceType: selectedRide.serviceType,
                pickupAddress: state.origin ?? RideConstants.defaultOrigin,
                dropoffAddress: state.destination!,
                pickupLocation: state.pickupLocation!,
                dropoffLocation: state.dropoffLocation!,
                estimatedDistance:
                    state.estimatedDistance ?? RideConstants.defaultDistanceKm,
                estimatedDuration:
                    state.estimatedDuration ?? RideConstants.defaultDurationMin,
                estimatedFare: state.calculatedFare,
                paymentMethod: state.paymentMethod,
                escrowId: escrowId.isEmpty ? null : escrowId, // ← new param
              );

      // ── Step 3: link escrow → trip (wallet only) ─────────────────────────
      if (usesEscrow) {
        await EscrowService.instance.attachToOrder(
          escrowId: escrowId,
          referenceId: tripId,
          referenceType: 'trip',
        );
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DriverMatchingScreen(
            rideType: selectedRide.serviceType.displayName,
            destination: state.destination!,
            fare: 'GHS ${state.calculatedFare.toStringAsFixed(0)}',
            tripId: tripId,
          ),
        ),
      );
    } catch (e, stack) {
      debugPrint('Trip creation failed: $e\n$stack');

      // Rollback: refund escrow if it was held and trip creation failed.
      try {
        await FirebaseFunctions.instanceFor(region: 'europe-west2')
            .httpsCallable('refundEscrowOnError')
            .call({'escrowId': escrowId, 'reason': 'trip_creation_failed'});
      } catch (refundErr) {
        debugPrint('⚠️ Escrow refund failed: $refundErr');
        // Stuck escrow auto-released after 2h by releaseStuckEscrows.
      }

      if (mounted) _showErrorSnack(RideConstants.errorCreateTrip);
    } finally {
      if (mounted) {
        ref.read(rideRequestProvider.notifier).setLoading(false);
      }
    }
  }

  void _showPaymentSheet() {
    final currentType = ref.read(rideRequestProvider).paymentMethod;
    final walletAsync = ref.read(walletBalanceProvider);
    final walletBalance = switch (walletAsync) {
      AsyncData(:final value) => value,
      _ => 0.0,
    };

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PaymentMethodSheet(
        selectedType: currentType,
        walletBalance: walletBalance,
        onMethodSelected: (method) {
          ref
              .read(rideRequestProvider.notifier)
              .selectPaymentMethod(method.type);
        },
      ),
    );
  }

  void _navigateToTracking(ServiceRequestWrapper request) {
    switch (request) {
      case TripRequestWrapper(): // or whatever the first case is
        Navigator.of(context, rootNavigator: true).pushNamed(
            AppRoutes.rideTracking,
            arguments: {'rideId': request.id});
      case DeliveryRequestWrapper():
        Navigator.of(context, rootNavigator: true).pushNamed(
            AppRoutes.deliveryTracking,
            arguments: {'deliveryId': request.id});
      case GasRefillRequestWrapper():
        Navigator.of(context, rootNavigator: true).pushNamed(
            AppRoutes.gasTracking,
            arguments: {'orderId': request.id});
    }
  }

  void _showErrorSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF2A1A1A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
      ),
    );
  }
}
