// The transaction receipt and the trip detail sheet: same data, actions and
// routes as before, presented with the shared CTSGo receipt pattern.
// Sample values stand in for Firestore; nothing here changes app data.

import 'package:cloud_firestore/cloud_firestore.dart' show GeoPoint;
import 'package:cts_transport_app/core/theme/cts_theme.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/history/presentation/history_screen.dart';
import 'package:cts_transport_app/features/ride/models/book_ride_args.dart';
import 'package:cts_transport_app/features/ride/models/service_type.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:cts_transport_app/features/wallet/presentation/screens/transaction_detail_screen.dart';
import 'package:cts_transport_app/features/wallet/presentation/screens/wallet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TxItem _tx({bool credit = false, String status = 'pending'}) => TxItem(
      icon: Icons.local_taxi_rounded,
      iconBg: CtsTheme.appleSoft,
      iconColor: CtsTheme.primaryDeep,
      label: credit
          ? 'Wallet top-up'
          : 'Taxi ride to Kotoka International Airport, Terminal 3',
      sub: 'Today 14:30',
      amount: credit ? '+GHS 100.00' : '-GHS 1,242.50',
      isCredit: credit,
      type: credit ? 'Top-ups' : 'Rides',
      ref: 'CTS-7F3K9Q2M',
      fullDate: 'Oct 19, 2026 · 2:30 PM',
      status: status,
      note: '',
    );

final _ride = HistoryItem(
  id: 'a',
  type: HistoryItemType.ride,
  status: 'completed',
  origin: 'Kwame Nkrumah Circle, Accra',
  destination: 'Kotoka International Airport, Terminal 3',
  fare: 1242.5,
  createdAt: DateTime(2026, 10, 19, 14, 30),
  driverName: 'Kwame Mensah',
  vehicleType: 'taxi',
  rating: 5,
  rebook: rebookArgsFromTrip(const {
    'serviceType': 'taxi',
    'pickupAddress': 'Kwame Nkrumah Circle, Accra',
    'pickupLocation': GeoPoint(5.5713, -0.2131),
    'dropoffAddress': 'Kotoka International Airport, Terminal 3',
    'dropoffLocation': GeoPoint(5.6052, -0.1668),
  }),
);

final _gas = HistoryItem(
  id: 'c',
  type: HistoryItemType.gas,
  status: 'cancelled',
  origin: 'Total Energies, Spintex',
  destination: 'Spintex Road, House 14',
  fare: 165,
  createdAt: DateTime(2026, 10, 19, 11, 0),
  cylinderSize: '12.5kg',
  cancelReason: 'Changed my mind about this order today',
);

void _size(WidgetTester t, Size size) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Widget _app(Widget home,
        {double scale = 1,
        List overrides = const [],
        RouteFactory? onGenerateRoute}) =>
    ProviderScope(
      overrides: [...overrides.cast()],
      child: MaterialApp(
        theme: CtsTheme.light(),
        onGenerateRoute: onGenerateRoute,
        // Scale applies app-wide so sheets opened over the page get it too.
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    );

void main() {
  group('Transaction receipt', () {
    testWidgets('shows every existing receipt field with accessible labels',
        (t) async {
      final h = t.ensureSemantics();
      _size(t, const Size(390, 844));
      await t.pumpWidget(_app(TransactionDetailScreen(tx: _tx())));
      await t.pumpAndSettle();

      expect(
          find.bySemanticsLabel(RegExp(r'^Paid GHS 1,242\.50\. Taxi ride to '
              r'Kotoka International Airport, Terminal 3\. Oct 19, 2026 · '
              r'2:30 PM\. Pending$')),
          findsOneWidget);
      for (final label in [
        'Transaction type: Debit',
        'Category: Rides',
        'Description: No description provided',
        'Date & time: Oct 19, 2026 · 2:30 PM',
        'Status: Pending',
        'Reference: CTS-7F3K9Q2M',
      ]) {
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      }
      expect(find.text('Save receipt'), findsOneWidget);
      expect(find.text('Share receipt'), findsOneWidget);
      await t.scrollUntilVisible(find.text('Report an issue'), 100);
      expect(find.text('Report an issue'), findsOneWidget);
      h.dispose();
    });

    testWidgets('status uses the shared tone in the hero and the details',
        (t) async {
      _size(t, const Size(390, 844));
      await t.pumpWidget(_app(TransactionDetailScreen(tx: _tx())));
      await t.pumpAndSettle();
      final pill = t.widget<CtsStatusPill>(find.byType(CtsStatusPill));
      expect((pill.label, pill.tone), ('Pending', CtsTone.warning));
      final value = t.widget<Text>(find.text('Pending').last);
      expect(value.style?.color, CtsTone.warning.foreground);
    });

    testWidgets('credits keep their receipt without a Report action',
        (t) async {
      _size(t, const Size(390, 844));
      await t.pumpWidget(_app(
          TransactionDetailScreen(tx: _tx(credit: true, status: 'completed'))));
      await t.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'^Received GHS 100\.00\.')),
          findsOneWidget);
      expect(find.text('Report an issue'), findsNothing);
      expect(find.bySemanticsLabel('Transaction type: Credit'), findsOneWidget);
    });

    testWidgets('Copy reference copies the reference and confirms', (t) async {
      final h = t.ensureSemantics();
      String? copied;
      t.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      _size(t, const Size(390, 844));
      await t.pumpWidget(_app(TransactionDetailScreen(tx: _tx())));
      await t.pumpAndSettle();

      final copy = find.bySemanticsLabel('Copy reference');
      expect(
          t
              .getSemantics(copy)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue);
      expect(t.getSize(find.widgetWithText(TextButton, 'Copy')).height,
          greaterThanOrEqualTo(48));
      await t.tap(find.text('Copy'));
      await t.pump();
      expect(copied, 'CTS-7F3K9Q2M');
      expect(find.text('Reference copied to clipboard'), findsOneWidget);
      h.dispose();
    });

    testWidgets('Report an issue opens the report sheet', (t) async {
      _size(t, const Size(390, 844));
      await t.pumpWidget(_app(TransactionDetailScreen(tx: _tx())));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('Report an issue'), 100);
      await t.tap(find.text('Report an issue'));
      await t.pumpAndSettle();
      // The truthful report sheet (no in-app submission exists yet).
      expect(find.text('Report a problem with this payment'), findsOneWidget);
      expect(find.bySemanticsLabel('Reference: CTS-7F3K9Q2M'), findsWidgets);
    });

    testWidgets('lays out at 320px with 2x text, details stacked', (t) async {
      _size(t, const Size(320, 640));
      await t.pumpWidget(_app(TransactionDetailScreen(tx: _tx()), scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      // Value sits under its label instead of beside it.
      final label = t.getTopLeft(find.text('Transaction type'));
      final value = t.getTopLeft(find.text('Debit'));
      expect(value.dy, greaterThan(label.dy));
      expect(value.dx, closeTo(label.dx, 0.5));
      await t.scrollUntilVisible(find.text('Report an issue'), 200);
      expect(t.takeException(), isNull);
    });
  });

  group('Trip detail sheet', () {
    Future<List<RouteSettings>> open(WidgetTester t, String card,
        {Size size = const Size(390, 844), double scale = 1}) async {
      final pushed = <RouteSettings>[];
      _size(t, size);
      await t.pumpWidget(_app(
        HistoryScreen(scrollController: ScrollController()),
        scale: scale,
        overrides: [
          historyProvider.overrideWith((ref) async => [_ride, _gas])
        ],
        onGenerateRoute: (s) {
          pushed.add(s);
          return MaterialPageRoute(builder: (_) => const SizedBox());
        },
      ));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text(card), 100,
          scrollable: find
              .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable))
              .first);
      await t.tap(find.text(card));
      await t.pumpAndSettle();
      return pushed;
    }

    Finder inSheet(Finder f) =>
        find.descendant(of: find.byType(BottomSheet), matching: f);

    testWidgets('completed ride: identity, route, details, total, Rebook',
        (t) async {
      final h = t.ensureSemantics();
      final pushed = await open(t, 'Taxi');
      expect(inSheet(find.text('Taxi')), findsOneWidget);
      final pill = t.widget<CtsStatusPill>(inSheet(find.byType(CtsStatusPill)));
      expect((pill.label, pill.tone), ('Completed', CtsTone.success));
      expect(find.bySemanticsLabel('From: Kwame Nkrumah Circle, Accra'),
          findsWidgets);
      expect(find.bySemanticsLabel('Driver: Kwame Mensah'), findsOneWidget);
      expect(find.bySemanticsLabel('Service: taxi'), findsOneWidget);
      expect(find.bySemanticsLabel('Total: GHS 1,242.50'), findsOneWidget);

      await t.tap(find.text('Rebook this trip'));
      await t.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(pushed.last.name, '/book-ride');
      // The arguments BookRideScreen prefills from (booking_entry_test.dart):
      // the trip's own pickup and destination with coordinates.
      final args = BookRideArgs.fromRoute(pushed.last.arguments);
      expect(args.pickupAddress, 'Kwame Nkrumah Circle, Accra');
      expect(args.pickupLocation, const LatLng(5.5713, -0.2131));
      expect(args.destinationAddress, 'Kotoka International Airport, Terminal 3');
      expect(args.destinationLocation, const LatLng(5.6052, -0.1668));
      expect(args.service, ServiceType.taxi);
      h.dispose();
    });

    testWidgets('cancelled gas order shows its reason and no Rebook',
        (t) async {
      final h = t.ensureSemantics();
      await open(t, '12.5kg Gas');
      final pill = t.widget<CtsStatusPill>(inSheet(find.byType(CtsStatusPill)));
      expect((pill.label, pill.tone), ('Cancelled', CtsTone.error));
      expect(find.bySemanticsLabel('Cylinder: 12.5kg'), findsOneWidget);
      expect(
          find.bySemanticsLabel(
              'Reason: Changed my mind about this order today'),
          findsOneWidget);
      expect(find.bySemanticsLabel('Total: GHS 165.00'), findsOneWidget);
      expect(find.text('Rebook this trip'), findsNothing);
      h.dispose();
    });

    testWidgets('lays out at 320px with 2x text', (t) async {
      await open(t, 'Taxi', size: const Size(320, 640), scale: 2);
      expect(t.takeException(), isNull);
      expect(inSheet(find.text('Taxi')), findsOneWidget);
      // Header stacks: the icon keeps its size above the title.
      expect(t.getSize(inSheet(find.byType(CtsIconTile))), const Size(48, 48));
      expect(t.getTopLeft(inSheet(find.text('Taxi'))).dy,
          greaterThan(t.getBottomLeft(inSheet(find.byType(CtsIconTile))).dy));
      await t.scrollUntilVisible(inSheet(find.text('Rebook this trip')), 200,
          scrollable: inSheet(find.byType(Scrollable)).first);
      expect(t.takeException(), isNull);
    });
  });
}
