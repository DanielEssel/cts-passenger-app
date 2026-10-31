// Release blocker B2: the total shown, the amount held from the wallet and the
// total recorded on the order must be the same number.
//
// Release v5: the delivery fee is a flat charge at
// GasPricing.standardDistanceKm (the server's price, functions/gas_pricing.js),
// so the distance estimate (ETA only) never changes or delays the price; a
// price change between display and submission is shown to the customer and
// charged only with their agreement; malformed price settings block ordering.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cts_transport_app/core/services/escrow_service.dart';
import 'package:cts_transport_app/core/services/pricing_service.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/gas/domain/gas_checkout.dart';
import 'package:cts_transport_app/features/gas/domain/gas_pricing.dart';
import 'package:cts_transport_app/features/gas/models/gas_refill_request.dart';
import 'package:cts_transport_app/features/gas/presentation/screens/gas_order_screen.dart';
import 'package:cts_transport_app/features/gas/providers/gas_order_providers.dart';
import 'package:cts_transport_app/features/gas/repositories/gas_order_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRepo implements GasOrderRepository {
  final created = <GasRefillRequest>[];

  @override
  Future<String> createGasOrder(GasRefillRequest order) async {
    created.add(order);
    return 'order-1';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _addressA = 'House 12, Osu Badu Street, Accra';
const _addressB = 'Plot 7, Spintex Road, Accra';
const _geoA = GeoPoint(5.556, -0.182);
const _geoB = GeoPoint(5.640, -0.105);

/// Scripted collaborators: every outside call is recorded or controlled.
class _Harness {
  final addresses = <Map<String, dynamic>>[];
  final distanceRequests = <Completer<double>>[];
  final sheetTotals = <double>[];
  final heldAmounts = <double>[];
  Completer<EscrowResult>? holdCompleter;
  final attached = <String>[];
  final repo = _FakeRepo();

  /// Settings the "server" returns when the screen reads prices again
  /// before submitting; null keeps the current ones.
  Map<String, dynamic>? settingsOnRefresh;

  /// False when the server's prices cannot be read (offline, missing).
  bool pricesAvailable = true;
  bool acceptPriceChange = false;
  final priceChanges = <(double, double)>[];

  GasCheckoutDeps get deps => GasCheckoutDeps(
        pickAddress: (_) async =>
            addresses.isEmpty ? null : addresses.removeAt(0),
        estimateDistanceKm: (_) {
          final c = Completer<double>();
          distanceRequests.add(c);
          return c.future;
        },
        confirmWalletPayment: (_, sheet) async {
          sheetTotals.add(sheet.total);
          return true;
        },
        holdBalance: (amount) {
          heldAmounts.add(amount);
          return holdCompleter?.future ??
              Future.value(
                  const EscrowResult(success: true, escrowId: 'escrow-1'));
        },
        attachEscrow: (escrowId, orderId) async =>
            attached.add('$escrowId→$orderId'),
        saveOrderEscrowId: (_, __) async {},
        currentUserId: () => 'customer-1',
        refreshPricing: () async {
          if (!pricesAvailable) return false;
          if (settingsOnRefresh != null) {
            PricingService.instance.debugSetSettings(settingsOnRefresh);
          }
          return true;
        },
        confirmPriceChange: (_, was, now) async {
          priceChanges.add((was, now));
          return acceptPriceChange;
        },
      );
}

Future<void> _pump(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      gasOrderRepositoryProvider.overrideWithValue(h.repo),
      gasOrderStreamProvider.overrideWith((ref, id) => const Stream.empty()),
    ],
    child: MaterialApp(home: GasOrderScreen(deps: h.deps)),
  ));
  await tester.pump();
}

Future<void> _reveal(WidgetTester tester, Finder f, {double dy = -150}) =>
    tester.dragUntilVisible(
        f.hitTestable(), find.byType(CustomScrollView), Offset(0, dy));

Future<void> _chooseAddress(
    WidgetTester tester, _Harness h, String address, GeoPoint geo,
    {required String currentText, double dy = -150}) async {
  h.addresses.add({'address': address, 'location': geo});
  await _reveal(tester, find.text(currentText), dy: dy);
  await tester.tap(find.text(currentText));
  await tester.pump();
}

Future<void> _acceptSafety(WidgetTester tester) async {
  const label = 'I confirm all safety requirements are met';
  await _reveal(tester, find.text(label));
  await tester.tap(find.text(label));
  await tester.pump();
}

/// Lets the submission's awaits complete and the next screen open. Not
/// pumpAndSettle: the tracking screen's loading spinner never settles.
Future<void> _finishSubmission(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

CtsPrimaryButton _button(WidgetTester tester) =>
    tester.widget<CtsPrimaryButton>(find.byType(CtsPrimaryButton));

/// The server's price for the default order (12.5 kg exchange, no brand):
/// the delivery charge at the standard distance.
double _expectedTotal() => _totalAtKm(GasPricing.standardDistanceKm);

/// What the default order would cost at [km] (the former distance pricing).
double _totalAtKm(double km) {
  final p = PricingService.instance;
  return GasPricing.compute(
    type: GasRefillType.exchangeEmpty,
    size: CylinderSize.kg12_5,
    quantity: 1,
    brand: null,
    distanceKm: km,
    inputs: GasPricingInputs(
      refillPriceOf: (s) => s.refillPrice,
      fullCylinderPriceOf: (s) => s.fullCylinderPrice,
      baseFare: p.gasBaseFare,
      perKm: p.gasPerKm,
      minDeliveryFee: p.gasMinDeliveryFee,
      roundTripFee: p.gasRoundTripFee,
      commercialRate: p.gasCommercialRate,
    ),
  ).total;
}

String _money(double v) => 'GHS ${v.toStringAsFixed(2)}';

void main() {
  tearDown(() => PricingService.instance.debugSetSettings(null));

  testWidgets('the price neither waits for nor depends on the distance estimate',
      (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    await _acceptSafety(tester);

    // Form complete, distance still pending: the server's price is known.
    expect(h.distanceRequests, hasLength(1));
    expect(_button(tester).onPressed, isNotNull);
    expect(_button(tester).trailingText, _money(_expectedTotal()));
    // A far estimate (which used to raise the fee) changes nothing.
    expect(_totalAtKm(20), isNot(_expectedTotal()));
    h.distanceRequests.single.complete(20);
    await tester.pump();
    expect(_button(tester).trailingText, _money(_expectedTotal()));

    await tester.tap(find.byType(CtsPrimaryButton));
    await _finishSubmission(tester);
    expect(h.heldAmounts.single, _expectedTotal());
    final order = h.repo.created.single;
    expect(order.totalPrice, _expectedTotal());
    expect(order.deliveryFee, 12.0, reason: 'max(12, 8 + 2 × 1 km) at built-in prices');
  });

  testWidgets(
      'a distance result arriving during submission does not change the '
      'amount held or recorded', (tester) async {
    final h = _Harness()..holdCompleter = Completer<EscrowResult>();
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    h.distanceRequests.last.complete(4);
    await tester.pump();
    await _acceptSafety(tester);

    final shown = _button(tester).trailingText;
    expect(shown, _money(_expectedTotal()));

    await tester.tap(find.byType(CtsPrimaryButton));
    await tester.pump(); // sheet confirmed, hold now pending

    // While the hold is in flight the customer changes the address and a
    // new (larger) delivery fee arrives.
    // The address card is above the safety section the page is now at.
    await _chooseAddress(tester, h, _addressB, _geoB,
        currentText: _addressA, dy: 150);
    h.distanceRequests.last.complete(12);
    await tester.pump();

    h.holdCompleter!
        .complete(const EscrowResult(success: true, escrowId: 'escrow-1'));
    await _finishSubmission(tester);

    final order = h.repo.created.single;
    expect(h.sheetTotals.single, _expectedTotal());
    expect(h.heldAmounts.single, _expectedTotal());
    expect(order.totalPrice, _expectedTotal());
    expect(_money(order.totalPrice), shown);
    expect(order.deliveryAddress, _addressA);
    expect(order.deliveryLocation, _geoA);
    expect(order.deliveryFee, isNot(0));
    expect(h.attached.single, 'escrow-1→order-1');
  });

  testWidgets('distance results in any order leave the price unchanged',
      (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    await _chooseAddress(tester, h, _addressB, _geoB, currentText: _addressA);
    await _acceptSafety(tester);
    expect(h.distanceRequests, hasLength(2));
    final [forA, forB] = h.distanceRequests;

    forA.complete(20);
    await tester.pump();
    expect(_button(tester).trailingText, _money(_expectedTotal()));
    expect(_button(tester).onPressed, isNotNull);

    forB.complete(3);
    await tester.pump();
    expect(_button(tester).trailingText, _money(_expectedTotal()));
  });

  testWidgets('a late result for an earlier address is ignored',
      (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    await _chooseAddress(tester, h, _addressB, _geoB, currentText: _addressA);
    await _acceptSafety(tester);
    final [forA, forB] = h.distanceRequests;

    forB.complete(3);
    await tester.pump();
    forA.complete(20); // arrives last, for the address no longer shown
    await tester.pump();

    expect(_button(tester).trailingText, _money(_expectedTotal()));

    await tester.tap(find.byType(CtsPrimaryButton));
    await _finishSubmission(tester);
    expect(h.heldAmounts.single, _expectedTotal());
    expect(h.repo.created.single.totalPrice, _expectedTotal());
    expect(h.repo.created.single.deliveryAddress, _addressB);
  });

  testWidgets('cash orders record the total that was shown', (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    h.distanceRequests.last.complete(6);
    await tester.pump();
    await _acceptSafety(tester);
    await _reveal(tester, find.text('Cash'));
    await tester.tap(find.text('Cash'));
    await tester.pump();

    final shown = _button(tester).trailingText;
    await tester.tap(find.byType(CtsPrimaryButton));
    await _finishSubmission(tester);

    expect(h.sheetTotals, isEmpty, reason: 'no wallet sheet for cash');
    expect(h.heldAmounts, isEmpty, reason: 'nothing is held for cash');
    final order = h.repo.created.single;
    expect(order.paymentMethod, 'cash');
    expect(_money(order.totalPrice), shown);
    expect(order.totalPrice, _expectedTotal());
  });

  testWidgets('a double tap places one order', (tester) async {
    final h = _Harness()..holdCompleter = Completer<EscrowResult>();
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    h.distanceRequests.last.complete(4);
    await tester.pump();
    await _acceptSafety(tester);

    await tester.tap(find.byType(CtsPrimaryButton));
    await tester.pump();
    await tester.tap(find.byType(CtsPrimaryButton), warnIfMissed: false);
    await tester.pump();
    h.holdCompleter!
        .complete(const EscrowResult(success: true, escrowId: 'escrow-1'));
    await _finishSubmission(tester);

    expect(h.heldAmounts, hasLength(1));
    expect(h.repo.created, hasLength(1));
  });

  testWidgets(
      'a price change before submission is shown and not charged when refused',
      (tester) async {
    final h = _Harness()
      ..settingsOnRefresh = {
        'gas': {'refill12kg': 160}
      };
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    await _acceptSafety(tester);
    final was = _expectedTotal();

    await tester.tap(find.byType(CtsPrimaryButton));
    await _finishSubmission(tester);

    expect(h.priceChanges, [(was, 172.0)]);
    expect(h.sheetTotals, isEmpty);
    expect(h.heldAmounts, isEmpty);
    expect(h.repo.created, isEmpty);
  });

  testWidgets('an accepted price change is held and recorded at the new total',
      (tester) async {
    final h = _Harness()
      ..settingsOnRefresh = {
        'gas': {'refill12kg': '160'} // a numeric string reads as 160
      }
      ..acceptPriceChange = true;
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    await _acceptSafety(tester);

    await tester.tap(find.byType(CtsPrimaryButton));
    await _finishSubmission(tester);

    expect(h.priceChanges.single.$2, 172.0);
    expect(h.sheetTotals.single, 172.0);
    expect(h.heldAmounts.single, 172.0);
    final order = h.repo.created.single;
    expect(order.totalPrice, 172.0);
    expect(order.deliveryFee, 12.0);
    expect(order.gasPrice, 160.0);
  });

  testWidgets('malformed price settings block ordering', (tester) async {
    PricingService.instance.debugSetSettings({
      'gas': {'refill12kg': 'ask the shop'}
    });
    final h = _Harness();
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    await _acceptSafety(tester);

    expect(_button(tester).onPressed, isNull);
    expect(_button(tester).trailingText, isNull);
    await tester.tap(find.byType(CtsPrimaryButton), warnIfMissed: false);
    await _finishSubmission(tester);
    expect(h.repo.created, isEmpty);
  });

  testWidgets(
      'when current prices cannot be read nothing is held or ordered, and '
      'the customer can retry', (tester) async {
    final h = _Harness()..pricesAvailable = false;
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    await _acceptSafety(tester);

    await tester.tap(find.byType(CtsPrimaryButton));
    await _finishSubmission(tester);
    expect(h.sheetTotals, isEmpty);
    expect(h.heldAmounts, isEmpty);
    expect(h.repo.created, isEmpty);
    expect(find.textContaining("Couldn't confirm current gas prices"),
        findsOneWidget);

    // Back online: the same order goes through at the server's price.
    h.pricesAvailable = true;
    expect(_button(tester).onPressed, isNotNull);
    _button(tester).onPressed!(); // the SnackBar covers the button
    await tester.pump();
    await _finishSubmission(tester);
    expect(h.heldAmounts.single, _expectedTotal());
    expect(h.repo.created.single.totalPrice, _expectedTotal());
  });

  testWidgets('malformed prices read at submission hold nothing',
      (tester) async {
    final h = _Harness()
      ..settingsOnRefresh = {
        'gas': {'refill12kg': -5}
      };
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    await _acceptSafety(tester);

    await tester.tap(find.byType(CtsPrimaryButton));
    await _finishSubmission(tester);
    expect(h.heldAmounts, isEmpty);
    expect(h.repo.created, isEmpty);
  });

  testWidgets(
      'a failed distance estimate shows no ETA and leaves the price alone',
      (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await _chooseAddress(tester, h, _addressA, _geoA,
        currentText: 'Tap to set your location');
    await _acceptSafety(tester);

    h.distanceRequests.single.completeError(Exception('permission-denied'));
    await tester.pump();
    expect(find.text('Unavailable', skipOffstage: false), findsOneWidget);
    expect(_button(tester).trailingText, _money(_expectedTotal()));

    await tester.tap(find.byType(CtsPrimaryButton));
    await _finishSubmission(tester);
    expect(h.heldAmounts.single, _expectedTotal());
    expect(h.repo.created.single.totalPrice, _expectedTotal());
  });

  testWidgets('the quantity stops at the most the server prices',
      (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    // The quantity stepper belongs to Commercial Bulk.
    await _reveal(tester, find.text('Commercial Bulk'));
    await tester.tap(find.text('Commercial Bulk'));
    await tester.pump();
    final more = find.byIcon(Icons.add_rounded); // 'More cylinders'
    await _reveal(tester, more);
    for (var i = 1; i < GasPricing.maxQuantity + 3; i++) {
      await tester.tap(more, warnIfMissed: false);
      await tester.pump();
    }
    expect(find.text('${GasPricing.maxQuantity}'), findsOneWidget);
    expect(find.text('${GasPricing.maxQuantity + 1}'), findsNothing);
  });
}
