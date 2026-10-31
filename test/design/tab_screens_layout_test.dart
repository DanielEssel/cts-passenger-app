// Wallet, Trips and Profile share one page pattern. They must lay out on a
// small phone with large text, and keep their real states and actions.
// Sample data stands in for Firestore; nothing here changes app data.

import 'package:cloud_firestore/cloud_firestore.dart' show GeoPoint;
import 'package:cts_transport_app/core/theme/cts_theme.dart';
import 'package:cts_transport_app/features/ride/models/book_ride_args.dart';
import 'package:cts_transport_app/features/ride/models/service_type.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/auth/providers/auth_providers.dart';
import 'package:cts_transport_app/features/history/presentation/history_screen.dart';
import 'package:cts_transport_app/features/profile/presentation/profile_screen.dart';
import 'package:cts_transport_app/features/wallet/domain/entities/transaction.dart';
import 'package:cts_transport_app/features/wallet/domain/entities/wallet.dart';
import 'package:cts_transport_app/features/wallet/presentation/providers/wallet_providers.dart';
import 'package:cts_transport_app/features/wallet/presentation/screens/wallet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 10, 19, 14, 30);

final _wallet = Wallet(
  userId: 'u',
  balance: 248.5,
  cashBalance: 0,
  mobileMoneyBalance: 0,
  cardBalance: 0,
  currency: 'GHS',
  createdAt: _now,
  lastUpdated: _now,
  status: 'active',
  heldBalance: 42,
);

final _txs = [
  Transaction(
      id: '1',
      userId: 'u',
      amount: 100,
      type: TransactionType.credit,
      status: TransactionStatus.completed,
      description: 'Wallet top-up',
      paymentMethod: PaymentMethod.mobileMoney,
      reference: 'R1',
      createdAt: _now),
  Transaction(
      id: '2',
      userId: 'u',
      amount: 42.5,
      type: TransactionType.debit,
      status: TransactionStatus.pending,
      description: 'Taxi ride to Kotoka International Airport, Terminal 3',
      paymentMethod: PaymentMethod.system,
      reference: 'R2',
      createdAt: _now,
      metadata: const {'category': 'ride'}),
];

final _trips = [
  HistoryItem(
      id: 'a',
      type: HistoryItemType.ride,
      status: 'completed',
      origin: 'Kwame Nkrumah Circle, Accra',
      destination: 'Kotoka International Airport, Terminal 3',
      fare: 1242.5,
      createdAt: _now,
      driverName: 'Kwame Mensah',
      vehicleType: 'Taxi',
      rating: 5,
      rebook: rebookArgsFromTrip(const {
        'serviceType': 'taxi',
        'pickupAddress': 'Kwame Nkrumah Circle, Accra',
        'pickupLocation': GeoPoint(5.5713, -0.2131),
        'dropoffAddress': 'Kotoka International Airport, Terminal 3',
        'dropoffLocation': GeoPoint(5.6052, -0.1668),
      })),
  HistoryItem(
      id: 'c',
      type: HistoryItemType.gas,
      status: 'cancelled',
      origin: 'Total Energies, Spintex',
      destination: 'Spintex Road, House 14',
      fare: 165,
      createdAt: _now,
      cylinderSize: '12.5kg',
      cancelReason: 'Changed my mind about this order today'),
];

// Day heading the Trips screen should show for [d], relative to today.
String _dayOf(DateTime d) {
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day)
      .difference(DateTime(d.year, d.month, d.day))
      .inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  return 'Mon 19 Oct${now.year == d.year ? '' : ' ${d.year}'}'; // 19 Oct 2026
}

Future<void> _pump(WidgetTester t, Widget screen, List overrides,
    {Size size = const Size(390, 844), double scale = 1}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    overrides: [...overrides.cast()],
    child: MaterialApp(
      theme: CtsTheme.light(),
      home: Builder(
        builder: (c) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: screen,
        ),
      ),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  final walletData = [
    walletStreamProvider.overrideWith((ref) => Stream.value(_wallet)),
    recentTransactionsStreamProvider.overrideWith((ref) => Stream.value(_txs)),
  ];
  final tripData = [historyProvider.overrideWith((ref) async => _trips)];
  final userData = [
    userStreamProvider.overrideWith((ref) => Stream.value(UserData(
        uid: 'u',
        displayName: 'Ama Akosua Owusu-Mensah',
        phoneNumber: '+233241234567',
        createdAt: _now)))
  ];

  for (final (size, scale) in [
    (const Size(390, 844), 1.0),
    (const Size(320, 640), 2.0),
  ]) {
    final tag = '${size.width.toInt()}w @${scale}x';

    testWidgets('wallet lays out ($tag)', (t) async {
      await _pump(
          t, WalletScreen(scrollController: ScrollController()), walletData,
          size: size, scale: scale);
      expect(t.takeException(), isNull);
      expect(find.text('Wallet'), findsOneWidget);
      expect(find.byType(CtsPrimaryButton), findsOneWidget); // Top up
    });

    testWidgets('trips lay out ($tag)', (t) async {
      await _pump(
          t, HistoryScreen(scrollController: ScrollController()), tripData,
          size: size, scale: scale);
      expect(t.takeException(), isNull);
      expect(find.text('My Trips'), findsOneWidget);
    });

    testWidgets('profile lays out ($tag)', (t) async {
      await _pump(
          t, ProfileScreen(scrollController: ScrollController()), userData,
          size: size, scale: scale);
      expect(t.takeException(), isNull);
      expect(find.text('Log Out'), findsOneWidget);
    });
  }

  testWidgets('wallet shows a held amount only when there is one', (t) async {
    await _pump(
        t, WalletScreen(scrollController: ScrollController()), walletData);
    expect(find.text('GHS 290.50'), findsOneWidget); // balance + held
    expect(find.text('Total balance'), findsOneWidget);
    expect(find.bySemanticsLabel('Available: GHS 248.50'), findsOneWidget);
    expect(find.bySemanticsLabel('On hold: GHS 42.00'), findsOneWidget);
  });

  testWidgets('wallet without a hold shows one available figure', (t) async {
    await _pump(t, WalletScreen(scrollController: ScrollController()), [
      walletStreamProvider.overrideWith(
          (ref) => Stream.value(_wallet.copyWith(heldBalance: 0))),
      recentTransactionsStreamProvider
          .overrideWith((ref) => Stream.value(_txs)),
    ]);
    expect(find.text('Available balance'), findsOneWidget);
    expect(find.text('GHS 248.50'), findsOneWidget);
    expect(find.text('On hold'), findsNothing);
  });

  testWidgets('hiding the balance hides the breakdown too', (t) async {
    await _pump(
        t, WalletScreen(scrollController: ScrollController()), walletData);
    await t.tap(find.byTooltip('Hide balance'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('GHS 290.50'), findsNothing);
    expect(find.textContaining('248.50'), findsNothing);
    expect(find.bySemanticsLabel('Balance hidden'), findsOneWidget);
  });

  testWidgets('transaction rows read as one button and open the receipt',
      (t) async {
    final h = t.ensureSemantics();
    await _pump(
        t, WalletScreen(scrollController: ScrollController()), walletData);
    final row = find.bySemanticsLabel(
        RegExp(r'^Wallet top-up, received GHS 100\.00, Completed'));
    expect(row, findsOneWidget);
    // Only the unfinished payment carries a status label.
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Completed'), findsNothing);
    t.semantics.tap(find.semantics
        .byLabel(RegExp(r'^Wallet top-up, received GHS 100\.00')));
    await t.pumpAndSettle();
    expect(find.byType(WalletScreen, skipOffstage: false), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Received GHS 100\.00')),
        findsOneWidget); // receipt amount
    h.dispose();
  });

  testWidgets('wallet has no duplicate Filter button beside the chips',
      (t) async {
    await _pump(
        t, WalletScreen(scrollController: ScrollController()), walletData);
    expect(find.text('Filter'), findsNothing);
    await t.ensureVisible(find.text('Gas'));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('Gas'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('No gas yet'), findsOneWidget);
    await t.tap(find.text('Show all activity'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Wallet top-up'), findsOneWidget);
  });

  testWidgets('trips are grouped by day under a summary', (t) async {
    await _pump(
        t, HistoryScreen(scrollController: ScrollController()), tripData);
    expect(find.text('Spent on completed trips'), findsOneWidget);
    expect(find.text('GHS 1,242.50'), findsWidgets); // summary and card
    expect(find.bySemanticsLabel('2 trips'), findsOneWidget);
    expect(find.bySemanticsLabel('1 completed'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(CtsGroupLabel), matching: find.text(_dayOf(_now))),
        findsOneWidget);
    // The card is announced as one item that includes the rating.
    expect(find.bySemanticsLabel(RegExp('Rated 5.0 out of 5')), findsOneWidget);
  });

  testWidgets('profile shows the full name, contact details and row hints',
      (t) async {
    await _pump(
        t, ProfileScreen(scrollController: ScrollController()), userData,
        size: const Size(320, 640), scale: 2);
    expect(t.takeException(), isNull);
    final name =
        t.renderObject<RenderParagraph>(find.text('Ama Akosua Owusu-Mensah'));
    expect(name.didExceedMaxLines, isFalse);
    expect(find.text('+233241234567'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Name, photo and email'), 100);
    expect(find.text('Name, photo and email'), findsOneWidget);
  });

  testWidgets('wallet has one Top up action and it opens the top-up sheet',
      (t) async {
    await _pump(
        t, WalletScreen(scrollController: ScrollController()), walletData);
    expect(find.text('Add Money'), findsNothing);
    expect(find.widgetWithText(CtsPrimaryButton, 'Top up'), findsOneWidget);
    await t.tap(find.widgetWithText(CtsPrimaryButton, 'Top up'));
    await t.pumpAndSettle();
    expect(find.text('Top up wallet'), findsOneWidget); // the real sheet
    expect(find.text('Select amount'), findsOneWidget);
  });

  testWidgets('wallet keeps its empty state', (t) async {
    await _pump(t, WalletScreen(scrollController: ScrollController()), [
      walletStreamProvider.overrideWith((ref) => Stream.value(_wallet)),
      recentTransactionsStreamProvider
          .overrideWith((ref) => Stream.value(<Transaction>[])),
    ]);
    expect(find.text('No transactions yet'), findsOneWidget);
  });

  testWidgets('trips keep their empty state', (t) async {
    await _pump(t, HistoryScreen(scrollController: ScrollController()),
        [historyProvider.overrideWith((ref) async => <HistoryItem>[])]);
    expect(find.text('No trips yet'), findsOneWidget);
  });

  testWidgets('trip errors are explained without raw exception text',
      (t) async {
    await _pump(t, HistoryScreen(scrollController: ScrollController()), [
      historyProvider
          .overrideWith((ref) async => throw StateError('firestore: boom')),
    ]);
    expect(find.text('Could not load trips'), findsOneWidget);
    expect(find.textContaining('boom'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('completed rides offer Rebook to the original destination',
      (t) async {
    final pushed = <RouteSettings>[];
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      overrides: [...tripData],
      child: MaterialApp(
        theme: CtsTheme.light(),
        onGenerateRoute: (s) {
          pushed.add(s);
          return MaterialPageRoute(builder: (_) => const SizedBox());
        },
        home: HistoryScreen(scrollController: ScrollController()),
      ),
    ));
    await t.pumpAndSettle();
    await t.tap(find.text('Rebook'));
    await t.pumpAndSettle();
    expect(pushed.last.name, '/book-ride');
    // What BookRideScreen reads (see test/ride/booking_entry_test.dart for
    // the screen prefilling from it): the trip's own pickup and destination,
    // with coordinates and its vehicle.
    final args = BookRideArgs.fromRoute(pushed.last.arguments);
    expect(args.pickupAddress, 'Kwame Nkrumah Circle, Accra');
    expect(args.pickupLocation, const LatLng(5.5713, -0.2131));
    expect(args.destinationAddress, 'Kotoka International Airport, Terminal 3');
    expect(args.destinationLocation, const LatLng(5.6052, -0.1668));
    expect(args.service, ServiceType.taxi);

    // The detail sheet's "Rebook this trip" sends the same.
    t.state<NavigatorState>(find.byType(Navigator)).pop();
    await t.pumpAndSettle();
    await t.tap(find.text('Kotoka International Airport, Terminal 3').first);
    await t.pumpAndSettle();
    await t.tap(find.text('Rebook this trip'));
    await t.pumpAndSettle();
    expect(pushed.last.name, '/book-ride');
    expect(pushed.last.arguments, args.toMap());
  });

  testWidgets('profile rows open their original routes', (t) async {
    final pushed = <String?>[];
    await t.pumpWidget(ProviderScope(
      overrides: [...userData],
      child: MaterialApp(
        theme: CtsTheme.light(),
        onGenerateRoute: (s) {
          pushed.add(s.name);
          return MaterialPageRoute(builder: (_) => const SizedBox());
        },
        home: ProfileScreen(scrollController: ScrollController()),
      ),
    ));
    await t.pumpAndSettle();
    for (final label in [
      'Edit Profile',
      'Saved Places',
      'Privacy & Security',
      'Help & Support',
      'About CTSGo',
    ]) {
      await t.scrollUntilVisible(find.text(label), 100);
      await t.tap(find.text(label));
      await t.pumpAndSettle();
      Navigator.of(t.element(find.byType(SizedBox).last)).pop();
      await t.pumpAndSettle();
    }
    expect(pushed, [
      '/edit-profile',
      '/saved-places',
      '/privacy-security',
      '/help-support',
      '/about',
    ]);
  });
}
