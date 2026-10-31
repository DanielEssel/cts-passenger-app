// A completed ride asks "Have you arrived?" only while it is unconfirmed,
// unsettled and undisputed; otherwise it shows the summary. Only the two
// buttons write anything (Android Back writes nothing), cash trips are not
// told the fare leaves their wallet, and "/trip-complete?tripId=…" opens the
// trip from every notification entry point. No Firebase.

import 'package:cts_transport_app/core/routes/app_routes.dart';
import 'package:cts_transport_app/core/routes/deep_link.dart';
import 'package:cts_transport_app/features/ride_tracking/ride_tracking_screen.dart';
import 'package:cts_transport_app/features/tracking/domain/trip_completion.dart';
import 'package:cts_transport_app/features/tracking/widgets/arrival_prompt.dart';
import 'package:cts_transport_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingWriter implements ArrivalWriter {
  final writes = <String>[];
  @override
  Future<void> confirmArrival(String tripId) async =>
      writes.add('confirm:$tripId');
  @override
  Future<void> reportNotArrived(String tripId, {String? userId}) async =>
      writes.add('dispute:$tripId:$userId');
}

Map<String, dynamic> _completed([Map<String, dynamic> more = const {}]) =>
    {'status': 'completed', 'paymentMethod': 'cash', ...more};

/// Opens the dialog from a button and returns the answer it produced.
Future<ArrivalAnswer?> _ask(WidgetTester t,
    Future<void> Function(WidgetTester) act) async {
  ArrivalAnswer? answer;
  await t.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async =>
              answer = await askArrival(context, message: 'msg'),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  expect(find.text('Have you arrived?'), findsOneWidget);
  await act(t);
  await t.pumpAndSettle();
  expect(find.text('Have you arrived?'), findsNothing);
  return answer;
}

void main() {
  group('what a completed trip shows', () {
    test('settled or confirmed trips go straight to the summary', () {
      for (final settled in [
        {'walletProcessed': true},
        {'settlementStatus': 'completed'},
        {'settlementStatus': 'processing'},
        {'passengerConfirmed': true},
        {'autoConfirmed': true},
        {'passengerConfirmed': true, 'walletProcessed': true},
      ]) {
        expect(tripCompletionStep(_completed(settled)),
            TripCompletionStep.showSummary,
            reason: '$settled');
      }
    });

    test('a genuinely completed, unconfirmed trip still asks once', () {
      expect(tripCompletionStep(_completed()), TripCompletionStep.askArrival);
      expect(
          tripCompletionStep(_completed(
              {'passengerConfirmed': false, 'walletProcessed': false})),
          TripCompletionStep.askArrival);
    });

    test('a disputed trip is not offered for confirmation', () {
      expect(tripCompletionStep(_completed({'disputed': true})),
          TripCompletionStep.underReview);
    });

    test('trips that are not completed keep tracking', () {
      for (final s in ['tripStarted', 'cancelled', null]) {
        expect(tripCompletionStep({'status': s}), TripCompletionStep.none);
      }
    });
  });

  group('arrival wording', () {
    test('a cash trip is paid to the driver, not from the wallet', () {
      final m = arrivalMessage(fare: 'GHS 42.00', paymentMethod: 'cash');
      expect(m, contains('cash'));
      expect(m, contains('GHS 42.00'));
      expect(m.toLowerCase(), isNot(contains('wallet')));
    });

    test('a wallet trip says the fare comes from the wallet', () {
      final m = arrivalMessage(fare: 'GHS 42.00', paymentMethod: 'wallet');
      expect(m, contains('wallet'));
    });
  });

  group('arrival dialog answers', () {
    testWidgets('Android Back closes it as "dismissed" and writes nothing',
        (t) async {
      final answer = await _ask(t, (t) => t.binding.handlePopRoute());
      expect(answer, ArrivalAnswer.dismissed);

      final writer = _RecordingWriter();
      await applyArrivalAnswer(answer!, writer, tripId: 't1', userId: 'u1');
      expect(writer.writes, isEmpty, reason: 'no dispute, no ticket');
    });

    testWidgets('"Yes, I arrived!" only confirms', (t) async {
      final answer =
          await _ask(t, (t) => t.tap(find.text('Yes, I arrived!')));
      expect(answer, ArrivalAnswer.arrived);
      final writer = _RecordingWriter();
      await applyArrivalAnswer(answer!, writer, tripId: 't1');
      expect(writer.writes, ['confirm:t1']);
    });

    testWidgets('the explicit report button keeps the dispute flow',
        (t) async {
      final answer = await _ask(
          t, (t) => t.tap(find.text("I didn't arrive — Report issue")));
      expect(answer, ArrivalAnswer.reportIssue);
      final writer = _RecordingWriter();
      await applyArrivalAnswer(answer!, writer, tripId: 't1', userId: 'u1');
      expect(writer.writes, ['dispute:t1:u1']);
    });
  });

  group('/trip-complete deep links', () {
    test('the trip id survives parsing from the route or stored metadata', () {
      final push = DeepLink.parse('/trip-complete?tripId=abc123')!;
      expect(push.path, AppRoutes.tripComplete);
      expect(push.arguments, {'tripId': 'abc123'});

      final inApp =
          DeepLink.parse('/trip-complete', metadata: {'tripId': 'abc123'})!;
      expect(inApp.path, AppRoutes.tripComplete);
      expect(inApp.arguments, {'tripId': 'abc123'});

      expect(DeepLink.parse(''), isNull);
      expect(DeepLink.parse(null), isNull);
    });

    testWidgets('every entry point opens that trip on the root navigator',
        (t) async {
      late BuildContext context;
      await t.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })));

      String openedTrip(RouteSettings settings) {
        final route = RiderApp.generateRoute(settings);
        expect(route, isA<MaterialPageRoute>(), reason: '${settings.name}');
        final screen = (route as MaterialPageRoute).builder(context);
        return (screen as RideTrackingScreen).tripId;
      }

      // Foreground, background and launch taps, and the notification list,
      // all push DeepLink.parse(...)'s path with its arguments.
      final link = DeepLink.parse('/trip-complete?tripId=abc123')!;
      expect(
          openedTrip(RouteSettings(name: link.path, arguments: link.arguments)),
          'abc123');
      // A raw route name still works (query read by the generator).
      expect(openedTrip(const RouteSettings(name: '/trip-complete?tripId=abc123')),
          'abc123');
      // Ride tracking links resolve the same way.
      expect(
          openedTrip(const RouteSettings(
              name: AppRoutes.rideTracking, arguments: 'xyz')),
          'xyz');
    });
  });
}
