// Booking entry points: trip-history rebook, saved-place shortcuts, Home's
// search bar and vehicle tiles open BookRideScreen prefilled from
// BookRideArgs. The Confirm button appears (and is usable) once the booking
// is valid, nothing is booked until it is tapped, and one tap books once.
// No Firebase: the trip creator, routes and driver data are fakes.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/core/routes/app_routes.dart';
import 'package:cts_transport_app/core/services/pricing_service.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/bookings/service_request_manager.dart';
import 'package:cts_transport_app/features/payment/models/payment_method.dart';
import 'package:cts_transport_app/features/ride/models/book_ride_args.dart';
import 'package:cts_transport_app/features/ride/models/place_result.dart';
import 'package:cts_transport_app/features/ride/models/service_type.dart';
import 'package:cts_transport_app/features/ride/presentation/book_ride_screen.dart';
import 'package:cts_transport_app/features/ride/presentation/destination_search_screen.dart';
import 'package:cts_transport_app/features/ride/providers/destination_search_provider.dart';
import 'package:cts_transport_app/features/ride/providers/drivers_nearby_provider.dart';
import 'package:cts_transport_app/features/ride/providers/ride_request_provider.dart';
import 'package:cts_transport_app/features/ride/providers/wallet_provider.dart';
import 'package:cts_transport_app/features/ride/services/last_vehicle_store.dart';
import 'package:cts_transport_app/features/ride/services/route_service.dart';
import 'package:cts_transport_app/features/ride/widgets/confirm_ride_bar.dart';
import 'package:cts_transport_app/features/ride/widgets/ride_option_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoRoute extends RouteService {
  @override
  Future<RouteResult?> getRoute(LatLng origin, LatLng destination) async =>
      null;
}

class _NoActiveRequest extends ActiveServiceRequest {
  @override
  Stream<ServiceRequestWrapper?> build() => Stream.value(null);
}

/// Records booking attempts; each stays in flight until [result] completes.
class _CountingCreator extends TripRequestCreator {
  int calls = 0;
  final result = Completer<String>();

  @override
  Future<String> createTripRequest({
    required ServiceType serviceType,
    required String pickupAddress,
    required String dropoffAddress,
    required GeoPoint pickupLocation,
    required GeoPoint dropoffLocation,
    required double estimatedDistance,
    required int estimatedDuration,
    required double estimatedFare,
    required PaymentType paymentMethod,
    String? promoCode,
    String? escrowId,
  }) {
    calls++;
    return result.future;
  }
}

const _circle = LatLng(5.5713, -0.2131);
const _airport = LatLng(5.6052, -0.1668);
const _here = LatLng(5.6037, -0.1870);

class _Booking {
  final nav = GlobalKey<NavigatorState>();
  final creator = _CountingCreator();
  late final ProviderContainer container;

  RideRequestState get state => container.read(rideRequestProvider);

  Future<void> open(WidgetTester t, BookRideArgs args,
      {Size size = const Size(390, 844)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    container = ProviderContainer(overrides: [
      activeServiceRequestProvider.overrideWith(_NoActiveRequest.new),
      routeServiceProvider.overrideWithValue(_NoRoute()),
      driversNearbyProvider.overrideWith((ref) => Stream.value(const [])),
      walletBalanceProvider.overrideWith((ref) async => 0.0),
      recentPlacesProvider.overrideWith((ref) async => const <PlaceResult>[]),
      tripRequestCreatorProvider.overrideWith(() => creator),
    ]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: Text('Home')),
        onGenerateRoute: (s) => s.name == AppRoutes.bookRide
            ? MaterialPageRoute(
                settings: s, builder: (_) => const BookRideScreen())
            : null,
      ),
    ));
    nav.currentState!.pushNamed(AppRoutes.bookRide, arguments: args.toMap());
    await settle(t);
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  /// The confirm bar's button (not the empty state's "Search" button).
  Finder get confirmFinder => find.descendant(
      of: find.byType(ConfirmRideBar), matching: find.byType(CtsPrimaryButton));

  CtsPrimaryButton? get button {
    final found = confirmFinder.evaluate();
    return found.isEmpty ? null : found.single.widget as CtsPrimaryButton;
  }

  /// The confirm bar is on screen at full size and can be tapped.
  void expectConfirmVisible(WidgetTester t, String label) {
    expect(button?.label, label);
    expect(button!.onPressed, isNotNull);
    final scale = t.widget<ScaleTransition>(find.descendant(
        of: find.byType(ConfirmRideBar),
        matching: find.byType(ScaleTransition)));
    expect(scale.scale.value, 1.0, reason: 'bar fully shown');
    expect(confirmFinder.hitTestable(), findsOneWidget);
  }

  /// Chooses a vehicle as tapping its card does.
  Future<void> choose(WidgetTester t, ServiceType service) async {
    final card = t
        .widgetList<RideOptionCard>(find.byType(RideOptionCard))
        .firstWhere((c) => c.option.serviceType == service);
    card.onTap!();
    await t.pump();
  }
}

BookRideArgs _rebook() => rebookArgsFromTrip({
      'serviceType': 'okada',
      'pickupAddress': 'Kwame Nkrumah Circle, Accra',
      'pickupLocation': GeoPoint(_circle.latitude, _circle.longitude),
      'dropoffAddress': 'Kotoka International Airport, Terminal 3',
      'dropoffLocation': GeoPoint(_airport.latitude, _airport.longitude),
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The server's fares (settings/platform), read before a booking; keys
    // left out keep the built-in fares the trip was shown at.
    PricingService.debugServerReader = () async => {'platformFeePercent': 15};
  });
  tearDown(() {
    PricingService.debugServerReader = null;
    PricingService.instance.debugSetSettings(null);
  });

  group('rebook from trip history', () {
    test('args carry the original pickup, destination, coordinates and vehicle',
        () {
      final a = _rebook();
      expect(a.service, ServiceType.okada);
      expect(a.pickupAddress, 'Kwame Nkrumah Circle, Accra');
      expect(a.pickupLocation, _circle);
      expect(a.destinationAddress, 'Kotoka International Airport, Terminal 3');
      expect(a.destinationLocation, _airport);
      expect(a.openSearch, isFalse);
      // And they survive the route-argument round trip.
      final back = BookRideArgs.fromRoute(a.toMap());
      expect(back.toMap(), a.toMap());
    });

    test('an unsupported vehicle or placeholder address is dropped, not invented',
        () {
      final a = rebookArgsFromTrip(
          {'serviceType': 'delivery', 'pickupAddress': '—', 'dropoffAddress': ' '});
      expect(a.service, isNull);
      expect(a.pickupAddress, isNull);
      expect(a.destinationAddress, isNull);
    });

    testWidgets('prefills the original trip and shows a usable Confirm button',
        (t) async {
      final b = _Booking();
      await b.open(t, _rebook());

      final s = b.state;
      expect(s.origin, 'Kwame Nkrumah Circle, Accra');
      expect(s.pickupLocation, GeoPoint(_circle.latitude, _circle.longitude));
      expect(s.destination, 'Kotoka International Airport, Terminal 3');
      expect(s.dropoffLocation, GeoPoint(_airport.latitude, _airport.longitude));
      expect(s.selectedRide?.serviceType, ServiceType.okada);
      expect(find.text('Kotoka International Airport, Terminal 3'), findsWidgets);
      b.expectConfirmVisible(t, 'Confirm Okada');
      expect(find.byType(DestinationSearchScreen), findsNothing);
      expect(b.creator.calls, 0, reason: 'nothing booked by opening');
    });

    testWidgets('Confirm books nothing when current fares cannot be read',
        (t) async {
      PricingService.debugServerReader = () async =>
          throw Exception('[cloud_firestore/unavailable] client is offline');
      final b = _Booking();
      await b.open(t, _rebook());
      b.container
          .read(rideRequestProvider.notifier)
          .selectPaymentMethod(PaymentType.cash);
      await t.pump();

      await t.tap(b.confirmFinder);
      await t.pump();
      expect(b.creator.calls, 0);
      expect(b.state.isLoading, isFalse);
      expect(find.textContaining("Couldn't confirm current fares"), findsOneWidget);
    });

    testWidgets('Confirm books nothing when the current fare differs from the one shown',
        (t) async {
      PricingService.debugServerReader = () async => {
            'okada': {'baseFare': 50.0, 'minimumFare': 60.0}
          };
      final b = _Booking();
      await b.open(t, _rebook());
      b.container
          .read(rideRequestProvider.notifier)
          .selectPaymentMethod(PaymentType.cash);
      await t.pump();

      await t.tap(b.confirmFinder);
      await t.pump();
      expect(b.creator.calls, 0);
      expect(find.textContaining('Fares were updated'), findsOneWidget);
    });

    testWidgets('Confirm books once through the existing flow, however often tapped',
        (t) async {
      final b = _Booking();
      await b.open(t, _rebook());
      b.container
          .read(rideRequestProvider.notifier)
          .selectPaymentMethod(PaymentType.cash); // no wallet hold in tests
      await t.pump();

      await t.tap(b.confirmFinder);
      await t.pump();
      await t.tap(b.confirmFinder, warnIfMissed: false);
      await t.pump();
      b.button?.onPressed?.call();
      await t.pump();
      expect(b.creator.calls, 1);
      expect(b.state.isLoading, isTrue);

      b.creator.result.completeError(StateError('stopped by test'));
      await b.settle(t);
      expect(b.state.isLoading, isFalse);
    });
  });

  group('saved-place shortcut', () {
    test('placeholders and blank places are not destinations', () {
      expect(savedPlaceArgs(configured: false, address: 'Set home address'),
          isNull);
      expect(savedPlaceArgs(configured: false, address: 'Set work address'),
          isNull);
      expect(savedPlaceArgs(configured: true, address: '  '), isNull);
    });

    test('a saved place keeps its coordinates and the last vehicle', () {
      final a = savedPlaceArgs(
        configured: true,
        address: 'East Legon, Accra',
        lat: 5.65,
        lng: -0.16,
        lastVehicle: ServiceType.pragyia,
      )!;
      expect(a.destinationAddress, 'East Legon, Accra');
      expect(a.destinationLocation, const LatLng(5.65, -0.16));
      expect(a.service, ServiceType.pragyia);
      expect(a.openSearch, isFalse);
    });

    test('the last vehicle is remembered, and only ride vehicles count',
        () async {
      final store = LastVehicleStore();
      expect(await store.read(), isNull);
      await store.save(ServiceType.okada);
      expect(await store.read(), ServiceType.okada);
      await store.save(ServiceType.gas);
      expect(await store.read(), ServiceType.okada);
      SharedPreferences.setMockInitialValues({LastVehicleStore.key: 'rocket'});
      expect(await LastVehicleStore().read(), isNull);
    });

    testWidgets('opens with the saved destination and last vehicle, ready to confirm',
        (t) async {
      final b = _Booking();
      await b.open(
          t,
          savedPlaceArgs(
            configured: true,
            address: 'East Legon, Accra',
            lat: 5.65,
            lng: -0.16,
            lastVehicle: ServiceType.taxi,
          )!.copyForTest(currentLocation: _here));
      expect(b.state.destination, 'East Legon, Accra');
      expect(b.state.dropoffLocation, const GeoPoint(5.65, -0.16));
      expect(b.state.selectedRide?.serviceType, ServiceType.taxi);
      b.expectConfirmVisible(t, 'Confirm CTSGo Taxi');
    });

    testWidgets('with no remembered vehicle the button stays disabled until one is chosen',
        (t) async {
      final b = _Booking();
      await b.open(
          t,
          savedPlaceArgs(
                  configured: true, address: 'East Legon', lat: 5.65, lng: -0.16)!
              .copyForTest(currentLocation: _here));
      expect(b.button?.label, 'Choose a ride to continue');
      expect(b.button?.onPressed, isNull);

      await b.choose(t, ServiceType.okada);
      b.expectConfirmVisible(t, 'Confirm Okada');
      expect(await LastVehicleStore().read(), ServiceType.okada,
          reason: 'the choice is remembered');
    });

    testWidgets('without a pickup the booking is refused with a message',
        (t) async {
      // Location services off: the GPS fix fails, as on a device.
      final messenger = t.binding.defaultBinaryMessenger;
      for (final name in [
        'flutter.baseflow.com/geolocator',
        'flutter.baseflow.com/geolocator_android',
      ]) {
        final channel = MethodChannel(name);
        messenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'LOCATION_SERVICES_DISABLED');
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      }
      final b = _Booking();
      // No pickup passed and no GPS in tests: the pickup stays unset.
      await b.open(
          t,
          savedPlaceArgs(
            configured: true,
            address: 'East Legon',
            lat: 5.65,
            lng: -0.16,
            lastVehicle: ServiceType.taxi,
          )!);
      expect(b.state.pickupLocation, isNull);
      expect(b.state.isDestinationSet, isTrue);
      await t.tap(b.confirmFinder);
      await t.pump();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(b.creator.calls, 0);
    });

    testWidgets('a place that cannot be found says so and books nothing',
        (t) async {
      final b = _Booking();
      // No coordinates and no geocoder in tests: the lookup fails.
      await b.open(
          t,
          const BookRideArgs(
              destinationAddress: 'Nowhere Street', currentLocation: _here));
      expect(b.state.isDestinationSet, isFalse);
      expect(find.textContaining("couldn't find \"Nowhere Street\""),
          findsOneWidget);
      expect(b.button, isNull);
    });
  });

  group('Home search bar and vehicle tiles', () {
    testWidgets('search opens destination entry once, with no vehicle chosen',
        (t) async {
      final b = _Booking();
      await b.open(t, homeSearchArgs.copyForTest(currentLocation: _here));
      expect(find.byType(DestinationSearchScreen), findsOneWidget);
      expect(b.state.selectedRide, isNull);

      // Cancel: back on the booking screen, nothing booked, not reopened
      // (also across rebuilds).
      b.nav.currentState!.pop();
      await b.settle(t);
      expect(find.byType(DestinationSearchScreen), findsNothing);
      expect(find.byType(BookRideScreen), findsOneWidget);
      b.container
          .read(rideRequestProvider.notifier)
          .selectPaymentMethod(PaymentType.cash);
      await b.settle(t);
      expect(find.byType(DestinationSearchScreen), findsNothing);
      expect(b.creator.calls, 0);
      expect(find.text('Where are you going?'), findsOneWidget);
    });

    for (final service in [
      ServiceType.taxi,
      ServiceType.okada,
      ServiceType.pragyia,
    ]) {
      testWidgets('${service.name} opens destination entry once with it chosen',
          (t) async {
        final b = _Booking();
        await b.open(t, vehicleTileArgs(service).copyForTest(currentLocation: _here));
        expect(find.byType(DestinationSearchScreen), findsOneWidget);
        expect(b.state.selectedRide?.serviceType, service);
        b.nav.currentState!.pop();
        await b.settle(t);
        expect(find.byType(DestinationSearchScreen), findsNothing);
        expect(b.state.selectedRide?.serviceType, service);
        expect(b.creator.calls, 0);
      });
    }
  });
}

extension on BookRideArgs {
  /// The same entry with Home's resolved location, as _openBooking adds it.
  BookRideArgs copyForTest({LatLng? currentLocation}) => BookRideArgs(
        service: service,
        currentLocation: currentLocation,
        pickupAddress: pickupAddress,
        pickupLocation: pickupLocation,
        destinationAddress: destinationAddress,
        destinationLocation: destinationLocation,
        openSearch: openSearch,
      );
}
