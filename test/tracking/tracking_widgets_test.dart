// Shared passenger tracking widgets: honest status, progress, driver and
// location details, safe actions, and layouts that fit small phones.

import 'package:cts_transport_app/features/ride_tracking/ride_tracking_screen.dart';
import 'package:cts_transport_app/features/tracking/domain/tracking_view.dart';
import 'package:cts_transport_app/features/tracking/widgets/passenger_tracking_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  group('status header', () {
    testWidgets('says plainly when nothing is needed', (tester) async {
      await tester.pumpWidget(
          _host(TrackingStatusHeader(view: rideTrackingView('tripStarted'))));
      expect(find.text('Your ride is in progress'), findsOneWidget);
      expect(
          find.textContaining("You don't need to do anything"), findsOneWidget);
    });

    testWidgets('says what to do when the passenger must act', (tester) async {
      await tester.pumpWidget(
          _host(TrackingStatusHeader(view: rideTrackingView('driverArrived'))));
      expect(find.textContaining('What to do'), findsOneWidget);
      expect(find.textContaining("You don't need"), findsNothing);
    });

    testWidgets('the headline is announced when it changes', (tester) async {
      await tester.pumpWidget(
          _host(TrackingStatusHeader(view: rideTrackingView('tripAccepted'))));
      final semantics =
          tester.getSemantics(find.text('Your driver is on the way'));
      expect(semantics.flagsCollection.isLiveRegion, isTrue);
    });
  });

  group('progress', () {
    testWidgets('announces the current step by name', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
          _host(const TrackingProgressBar(steps: rideSteps, current: 2)));
      expect(find.bySemanticsLabel('Step 3 of 5: Pickup'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('completed steps carry a tick, not just a colour',
        (tester) async {
      await tester.pumpWidget(
          _host(const TrackingProgressBar(steps: rideSteps, current: 2)));
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
    });

    testWidgets('hidden when progress does not apply', (tester) async {
      await tester.pumpWidget(
          _host(const TrackingProgressBar(steps: rideSteps, current: -1)));
      expect(find.text('Pickup'), findsNothing);
    });
  });

  group('driver card', () {
    testWidgets('never invents a rating', (tester) async {
      await tester.pumpWidget(_host(const TrackingDriverCard(
          name: 'Kwame Mensah', rating: null, vehicle: 'Taxi')));
      expect(find.textContaining('★'), findsNothing);
      expect(find.textContaining('5.0'), findsNothing);
      expect(find.text('Kwame Mensah'), findsOneWidget);
      expect(find.text('KM'), findsOneWidget);
    });

    testWidgets('shows a stored rating and plate', (tester) async {
      await tester.pumpWidget(_host(const TrackingDriverCard(
          name: 'Ama', rating: 4.7, vehicle: 'Taxi', plate: 'GR 1234-24')));
      expect(find.textContaining('★ 4.7'), findsOneWidget);
      expect(find.text('GR 1234-24'), findsOneWidget);
    });

    testWidgets('missing details fall back without crashing', (tester) async {
      await tester.pumpWidget(_host(const TrackingDriverCard(
          name: null, rating: 0, vehicle: '', plate: '  ')));
      expect(find.text('Your driver'), findsOneWidget);
      expect(find.textContaining('★'), findsNothing);
    });
  });

  group('location note', () {
    final now = DateTime(2026, 10, 13, 12);
    Widget note({required bool has, DateTime? at}) => _host(
        TrackingLocationNote(hasLocation: has, updatedAt: at, now: () => now));

    testWidgets('live only when the position is recent', (tester) async {
      await tester.pumpWidget(
          note(has: true, at: now.subtract(const Duration(seconds: 20))));
      expect(find.text('Live location'), findsOneWidget);
    });

    testWidgets('stale positions say how old they are', (tester) async {
      await tester.pumpWidget(
          note(has: true, at: now.subtract(const Duration(minutes: 6))));
      expect(find.text('Live location'), findsNothing);
      expect(find.textContaining('Updated 6 min ago'), findsOneWidget);
    });

    testWidgets('no position is never called live', (tester) async {
      await tester.pumpWidget(note(has: false, at: now));
      expect(find.text('Live location'), findsNothing);
      expect(find.textContaining("isn't available yet"), findsOneWidget);
    });
  });

  group('actions', () {
    testWidgets('busy actions ignore taps and show progress', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: TrackingActionBar(
            primary: TrackingAction(
                label: 'Call driver',
                icon: Icons.phone_rounded,
                onTap: () => taps++,
                busy: true),
          ),
        ),
      ));
      await tester.tap(find.text('Call driver'));
      expect(taps, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('action buttons are at least 48 dp tall', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: TrackingActionBar(
            primary: TrackingAction(
                label: 'Call driver', icon: Icons.phone_rounded, onTap: () {}),
            secondary: TrackingAction(
                label: 'Message', icon: Icons.sms_rounded, onTap: () {}),
          ),
        ),
      ));
      for (final t in ['Call driver', 'Message']) {
        final button = find.ancestor(
            of: find.text(t),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('cancel link shows progress and blocks repeat taps',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(TrackingCancelLink(
          label: 'Cancel ride', busy: true, onTap: () => taps++)));
      await tester.tap(find.byKey(const ValueKey('tracking-cancel')));
      expect(taps, 0);
      expect(find.text('Cancelling…'), findsOneWidget);
    });

    testWidgets('keeping the ride closes only the dialog', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showTrackingConfirm(
                context,
                title: 'Cancel this ride?',
                message: 'm',
                confirmLabel: 'Cancel ride',
                keepLabel: 'Keep ride',
                destructive: true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep ride'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      expect(find.text('open'), findsOneWidget);
    });
  });

  group('ended screen', () {
    testWidgets('shows the outcome and only a way home', (tester) async {
      var home = 0;
      await tester.pumpWidget(MaterialApp(
        home: TrackingEndedScreen(
          view: rideTrackingView('cancelledByDriver'),
          homeLabel: 'Book another ride',
          onHome: () => home++,
        ),
      ));
      expect(find.text('Your driver cancelled'), findsOneWidget);
      expect(find.byKey(const ValueKey('tracking-cancel')), findsNothing);
      expect(find.textContaining('What to do'), findsNothing);
      await tester.tap(find.text('Book another ride'));
      expect(home, 1);
    });

    testWidgets('unknown statuses are explained, not guessed', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TrackingEndedScreen(
            view: rideTrackingView('teleporting'), onHome: () {}),
      ));
      expect(find.textContaining("can't show this ride"), findsOneWidget);
      expect(find.textContaining('teleporting'), findsOneWidget);
    });
  });

  test('ride share text has real details and no tracking link', () {
    final text = rideShareText({
      'dropoffAddress': 'Accra Mall',
      'driverName': 'Kofi',
      'driverPlate': 'GT 55-24',
    });
    expect(text, contains('Accra Mall'));
    expect(text, contains('Kofi'));
    expect(text, contains('GT 55-24'));
    expect(text, isNot(contains('http')));
    expect(rideShareText({}), "I'm on a CTSGo ride.");
  });

  testWidgets('tracking panel fits a small phone with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final views = [
      for (final s in [
        'searching',
        'tripAccepted',
        'driverArrived',
        'tripStarted'
      ])
        rideTrackingView(s),
      for (final s in ['pending', 'arrivedAtPickup', 'arrivedAtDropoff'])
        deliveryTrackingView(s, hasOtp: true),
      for (final s in [
        'pendingApproval',
        'driverArrived',
        'refilling',
        'returning'
      ])
        gasTrackingView(s, refillType: 'pickupAndReturn', hasOtp: true),
    ];
    for (final view in views) {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: TrackingLayout(
              map: const ColoredBox(color: Colors.grey),
              actions: TrackingActionBar(
                primary: TrackingAction(
                    label: 'Call driver',
                    icon: Icons.phone_rounded,
                    onTap: () {}),
                secondary: TrackingAction(
                    label: 'Message', icon: Icons.sms_rounded, onTap: () {}),
              ),
              children: [
                TrackingStatusHeader(view: view),
                const SizedBox(height: 16),
                TrackingProgressBar(steps: view.steps, current: view.stepIndex),
                const SizedBox(height: 16),
                const TrackingDriverCard(
                    name: 'Abena Owusu-Ansah',
                    rating: 4.8,
                    vehicle: 'Pragya (tricycle)',
                    plate: 'GW 4521-23'),
                const SizedBox(height: 12),
                const TrackingRouteSummary(
                  fromLabel: 'Pickup',
                  fromAddress: 'Kwame Nkrumah Circle, Accra',
                  toLabel: 'Destination',
                  toAddress: 'Kotoka International Airport, Terminal 3',
                  priceLabel: 'GHS 42.50',
                ),
              ],
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull, reason: view.headline);
    }
  });
}
