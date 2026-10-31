// Call / SMS / emergency actions must try to open the phone app and tell the
// user when they can't, instead of silently doing nothing.

import 'package:cts_transport_app/core/utils/phone_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ScaffoldMessengerState messenger;

  Future<void> host(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) {
        messenger = ScaffoldMessenger.of(context);
        return const SizedBox();
      })),
    ));
  }

  testWidgets('opens tel: with the cleaned number and shows nothing on success', (tester) async {
    await host(tester);
    Uri? opened;
    final result = await openPhoneAction(
      action: PhoneAction.call,
      number: '+233 24 000-0001',
      label: 'your driver',
      messenger: messenger,
      opener: (uri) async {
        opened = uri;
        return true;
      },
    );
    await tester.pump();

    expect(result, PhoneLaunchResult.opened);
    expect(opened, Uri(scheme: 'tel', path: '+233240000001'));
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('uses sms: for messages', (tester) async {
    await host(tester);
    Uri? opened;
    await openPhoneAction(
      action: PhoneAction.sms,
      number: '0240000001',
      label: 'your driver',
      messenger: messenger,
      opener: (uri) async {
        opened = uri;
        return true;
      },
    );
    expect(opened?.scheme, 'sms');
  });

  testWidgets('tells the user the number when the dialer cannot open', (tester) async {
    await host(tester);
    final result = await openPhoneAction(
      action: PhoneAction.call,
      number: '191',
      label: 'Police (191)',
      messenger: messenger,
      opener: (_) async => false,
    );
    await tester.pump();

    expect(result, PhoneLaunchResult.failed);
    expect(find.textContaining("Couldn't open your phone app"), findsOneWidget);
    expect(find.textContaining('191'), findsOneWidget);
    // It must not claim a call was placed.
    expect(find.textContaining('Calling'), findsNothing);
  });

  testWidgets('treats a launcher exception as a failure, not a crash', (tester) async {
    await host(tester);
    final result = await openPhoneAction(
      action: PhoneAction.call,
      number: '112',
      label: 'Emergency (112)',
      messenger: messenger,
      opener: (_) async => throw Exception('no activity'),
    );
    await tester.pump();
    expect(result, PhoneLaunchResult.failed);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('explains a missing number without trying to open anything', (tester) async {
    await host(tester);
    var called = false;
    final result = await openPhoneAction(
      action: PhoneAction.call,
      number: '  ',
      label: 'your driver',
      messenger: messenger,
      opener: (_) async => called = true,
    );
    await tester.pump();
    expect(result, PhoneLaunchResult.noNumber);
    expect(called, isFalse);
    expect(find.text('No phone number is available for your driver.'), findsOneWidget);
  });
}
