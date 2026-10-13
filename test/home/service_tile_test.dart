// Home redesign: image-led service tiles and the promo card.

import 'package:cts_transport_app/core/routes/app_routes.dart';
import 'package:cts_transport_app/features/home/extensions/service_type_extensions.dart';
import 'package:cts_transport_app/features/home/widgets/home_promo_card.dart';
import 'package:cts_transport_app/features/home/widgets/service_tile.dart';
import 'package:cts_transport_app/features/ride/models/service_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {double textScale = 1.0}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    );

void _setScreen(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  test('every service photo is bundled under its expected name', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final s in ServiceType.values) {
      final data = await rootBundle.load(serviceImageAsset(s));
      expect(data.lengthInBytes, greaterThan(0), reason: s.name);
    }
  });

  test('service taps keep their original destinations', () {
    // _openBooking pushes service.route; the redesign must not change it.
    expect(ServiceType.taxi.route, AppRoutes.bookRide);
    expect(ServiceType.okada.route, AppRoutes.bookRide);
    expect(ServiceType.pragyia.route, AppRoutes.bookRide);
    expect(ServiceType.delivery.route, AppRoutes.delivery);
    expect(ServiceType.gas.route, AppRoutes.gasOrder);
  });

  testWidgets('each tile reports its own service, all five shown',
      (tester) async {
    final tapped = <ServiceType>[];
    await tester.pumpWidget(_host(HomeServicesSection(onSelect: tapped.add)));

    for (final s in ServiceType.values) {
      await tester.tap(find.bySemanticsLabel(RegExp('^${s.displayName},')));
    }
    expect(tapped, ServiceType.values);
  });

  for (final size in const [Size(320, 640), Size(360, 760), Size(430, 932)]) {
    for (final scale in const [1.0, 1.3]) {
      testWidgets('no overflow at ${size.width.toInt()}dp, text x$scale',
          (tester) async {
        _setScreen(tester, size);
        await tester.pumpWidget(_host(
          Column(children: [
            HomeServicesSection(onSelect: (_) {}),
            const SizedBox(height: 16),
            HomePromoCard(
              eyebrow: 'CTS Gas',
              title: 'Cooking gas, delivered',
              subtitle: 'Order a refill and track it to your door.',
              ctaLabel: 'Order gas',
              onTap: () {},
              trailing: const SizedBox(
                width: 100,
                child: ServiceImage(
                    service: ServiceType.gas, aspectRatio: 0.85),
              ),
            ),
          ]),
          textScale: scale,
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('tiles in a row share one height', (tester) async {
    _setScreen(tester, const Size(360, 760));
    await tester.pumpWidget(_host(HomeServicesSection(onSelect: (_) {})));
    final heights = [
      for (final s in [ServiceType.pragyia, ServiceType.delivery, ServiceType.gas])
        tester
            .getSize(find.ancestor(
                of: find.text(s.displayName),
                matching: find.byType(ServiceTile)))
            .height,
    ];
    expect(heights.toSet().length, 1);
  });
}
