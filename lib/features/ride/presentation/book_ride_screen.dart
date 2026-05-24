import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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

    // ✅ SystemChrome configured once here, NOT inside build()
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

    // ✅ Animation driven by a listener on the provider, NOT a build() if-check
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initUserLocation(); // handles both success and fallback internally

      if (!mounted) return; // guard after the await

      ref.listenManual(
        rideRequestProvider.select((s) => s.isDestinationSet),
        (_, isSet) {
          if (isSet) {
            _fabController.forward();
          } else {
            _fabController.reverse();
          }
        },
      );
    });
  }

  Future<void> _initUserLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      // Reverse geocode to get a human-readable address
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
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
      // Location denied or unavailable — fall back to default
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
    // ✅ Single watch — child widgets use select() for granular rebuilds
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
    return Column(
      children: [
        if (activeRequest != null)
          ActiveRequestBanner(
            request: activeRequest,
            onTap: () => _navigateToTracking(activeRequest),
          ),
        MapSection(
          state: state,
          onMapTap: _openDestinationSearch,
        ),
        RouteSummary(
          state: state,
          onDestinationTap: _openDestinationSearch,
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: RideConstants.pageTransitionDuration,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.04),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: state.isDestinationSet
                ? RideOptionsList(
                    state: state,
                    onShowPaymentSheet: _showPaymentSheet,
                  )
                : EmptyDestinationState(
                    onSearchTap: _openDestinationSearch,
                  ),
          ),
        ),
        if (state.isDestinationSet)
          ConfirmRideBar(
            state: state,
            animation: _fabAnim,
            onConfirm: () => _confirmRide(state),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Navigation & Actions — intentionally kept in the screen (coordinator role)
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
    debugPrint('🎯 Destination result: $result');
    if (!mounted || result is! Map<String, dynamic>) return;

    ref.read(rideRequestProvider.notifier).setDestination(
          result['address'] as String,
          result['location'] as GeoPoint,
          result['distance'] as double? ?? RideConstants.defaultDistanceKm,
          result['duration'] as int? ?? RideConstants.defaultDurationMin,
        );
  }

  Future<void> _confirmRide(RideRequestState state) async {
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

    try {
      final selectedRide = state.selectedRide!;

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
              );

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
      debugPrint('Trip creation failed: $e');
      debugPrint(stack.toString());

      if (mounted) {
        _showErrorSnack(
          RideConstants.errorCreateTrip,
        );
      }
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
    if (request is TripRequestWrapper) {
      Navigator.pushNamed(
        context,
        AppRoutes.rideTracking,
        arguments: {'rideId': request.id},
      );
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
