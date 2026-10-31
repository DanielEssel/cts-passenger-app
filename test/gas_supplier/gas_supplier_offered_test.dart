// The order type and size the passenger starts with come from what the
// server says can be ordered at the chosen address (listGasSupplierOptions
// with a location only): never a type with no verified, available product
// there. An older backend that cannot say leaves every choice open.
import 'package:cts_transport_app/features/gas_supplier/data/gas_supplier_repository.dart';
import 'package:cts_transport_app/features/gas_supplier/domain/gas_supplier_models.dart';
import 'package:cts_transport_app/features/gas_supplier/presentation/gas_supplier_order_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const home = (address: 'Customer home', latitude: 5.6547, longitude: -0.5814);
const elsewhere = (address: 'Far away', latitude: 6.0, longitude: -0.5);

class Server {
  /// What is orderable per latitude; null: an older backend without the location-only answer.
  Map<double, List<Map<String, String>>>? offered = {
    home.latitude: [{'orderType': 'newCylinder', 'cylinderSize': 'kg12_5'}],
  };
  final listed = <Map<String, dynamic>>[];

  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> d) async {
    if (name == 'gasSupplierOrderingStatus') return {'enabled': true};
    if (name == 'listGasSupplierOptions') {
      listed.add(d);
      if (!d.containsKey('orderType')) {
        final o = offered;
        if (o == null) throw const GasSupplierFailure('invalid-argument', 'unsupported_order_type', 'Invalid request.');
        return {'offered': o[((d['location'] as Map)['latitude'] as num).toDouble()] ?? const []};
      }
      return {'options': const []};
    }
    return {};
  }

  GasSupplierRepository repo() => GasSupplierRepository(call: call, hold: (_) async => 'e', activeOrders: () async => const []);
}

void main() {
  group('rules', () {
    test('OF-01 only types and sizes the app orders are kept, in the app order', () {
      final o = parseOffered([
        {'orderType': 'pickupAndReturn', 'cylinderSize': 'kg12_5'}, // not ordered by the app
        {'orderType': 'newCylinder', 'cylinderSize': 'kg45'},
        {'orderType': 'newCylinder', 'cylinderSize': 'kg6'},
        {'orderType': 'mystery', 'cylinderSize': 'kg6'},
        'junk',
      ]);
      expect(o, [(orderType: 'newCylinder', cylinderSize: 'kg6'), (orderType: 'newCylinder', cylinderSize: 'kg45')]);
      expect(offeredTypes(o), ['newCylinder']);
      expect(offeredSizes(o, 'newCylinder'), ['kg6', 'kg45']);
      expect(offeredSizes(o, 'exchangeEmpty'), isEmpty);
    });

    test('OF-02 the selection keeps what is still offered, else the first offered; nothing offered gives none', () {
      final o = parseOffered([
        {'orderType': 'exchangeEmpty', 'cylinderSize': 'kg6'},
        {'orderType': 'newCylinder', 'cylinderSize': 'kg12_5'},
      ]);
      expect(selectionFor(o, orderType: 'newCylinder', cylinderSize: 'kg12_5'), (orderType: 'newCylinder', cylinderSize: 'kg12_5'));
      expect(selectionFor(o, orderType: 'exchangeEmpty', cylinderSize: 'kg12_5'), (orderType: 'exchangeEmpty', cylinderSize: 'kg6'));
      expect(selectionFor(o, orderType: 'commercialBulk', cylinderSize: 'kg45'), (orderType: 'exchangeEmpty', cylinderSize: 'kg6'));
      expect(selectionFor(const [], orderType: 'exchangeEmpty', cylinderSize: 'kg12_5'), isNull);
    });

    test('OF-03 the repository asks with the location only; an older backend gives null, a bad location is an error', () async {
      final s = Server();
      expect(await s.repo().offeredAt(latitude: home.latitude, longitude: home.longitude), [(orderType: 'newCylinder', cylinderSize: 'kg12_5')]);
      expect(s.listed.single, {'location': {'latitude': home.latitude, 'longitude': home.longitude}});
      s.offered = null;
      expect(await s.repo().offeredAt(latitude: home.latitude, longitude: home.longitude), isNull);
      final bad = GasSupplierRepository(call: (n, d) async => throw const GasSupplierFailure('invalid-argument', 'invalid_location', 'x'));
      await expectLater(bad.offeredAt(latitude: 0, longitude: 0), throwsA(isA<GasSupplierFailure>()));
    });
  });

  group('order screen', () {
    Future<void> open(WidgetTester tester, Server s, {DeliveryPoint? at = home, PickDeliveryPoint? pick}) async {
      await tester.pumpWidget(MaterialApp(home: GasSupplierOrderScreen(repository: s.repo(), initialDelivery: at,
          pickDelivery: pick ?? (_) async => null)));
      await tester.pumpAndSettle();
    }

    bool selected(WidgetTester tester, String key) => tester.widget<ChoiceChip>(find.byKey(Key(key))).selected;

    testWidgets('OF-10 a New-Cylinder-only area starts on New cylinder and offers nothing else', (tester) async {
      final s = Server();
      await open(tester, s);
      expect(find.byKey(const Key('gs-type-exchangeEmpty')), findsNothing);
      expect(find.byKey(const Key('gs-type-commercialBulk')), findsNothing);
      expect(selected(tester, 'gs-type-newCylinder'), isTrue);
      expect(find.byKey(const Key('gs-size-kg6')), findsNothing);
      expect(selected(tester, 'gs-size-kg12_5'), isTrue);
      await tester.tap(find.byKey(const Key('gs-find')));
      await tester.pumpAndSettle();
      expect(s.listed.last, containsPair('orderType', 'newCylinder'));
      expect(s.listed.last, containsPair('cylinderSize', 'kg12_5'));
    });

    testWidgets('OF-11 several types offered: each stays selectable, with its own sizes', (tester) async {
      final s = Server()..offered = {home.latitude: [
        {'orderType': 'exchangeEmpty', 'cylinderSize': 'kg6'}, {'orderType': 'newCylinder', 'cylinderSize': 'kg12_5'}]};
      await open(tester, s);
      expect(selected(tester, 'gs-type-exchangeEmpty'), isTrue);
      expect(selected(tester, 'gs-size-kg6'), isTrue);
      await tester.tap(find.byKey(const Key('gs-type-newCylinder')));
      await tester.pumpAndSettle();
      expect(selected(tester, 'gs-size-kg12_5'), isTrue);
      expect(find.byKey(const Key('gs-size-kg6')), findsNothing);
    });

    testWidgets('OF-12 nothing orderable at the address: said plainly, and suppliers are not searched', (tester) async {
      final s = Server();
      await open(tester, s, at: elsewhere);
      expect(find.byKey(const Key('gs-none-here')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('gs-find'))).onPressed, isNull);
    });

    testWidgets('OF-13 an older backend that cannot say keeps every type and size', (tester) async {
      final s = Server()..offered = null;
      await open(tester, s);
      for (final t in supplierOrderTypes) {
        expect(find.byKey(Key('gs-type-$t')), findsOneWidget);
      }
      expect(find.byKey(const Key('gs-none-here')), findsNothing);
    });

    testWidgets('OF-14 a new address asks again and adjusts the selection', (tester) async {
      final s = Server()..offered = {
        home.latitude: [{'orderType': 'newCylinder', 'cylinderSize': 'kg12_5'}],
        elsewhere.latitude: [{'orderType': 'exchangeEmpty', 'cylinderSize': 'kg3'}],
      };
      await open(tester, s, pick: (_) async => elsewhere);
      expect(selected(tester, 'gs-type-newCylinder'), isTrue);
      await tester.tap(find.byKey(const Key('gs-address')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gs-type-newCylinder')), findsNothing);
      expect(selected(tester, 'gs-type-exchangeEmpty'), isTrue);
      expect(selected(tester, 'gs-size-kg3'), isTrue);
    });
  });
}
