// The OTP input takes a pasted or autofilled code, not just typed digits.

import 'package:cts_transport_app/features/auth/widgets/otp_code_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late TextEditingController controller;
  late List<String> completed;

  Future<void> pump(WidgetTester tester, {bool enabled = true}) async {
    controller = TextEditingController();
    completed = [];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OtpCodeField(
          controller: controller,
          enabled: enabled,
          onCompleted: completed.add,
        ),
      ),
    ));
  }

  testWidgets('a whole pasted code fills every box and completes once',
      (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    expect(controller.text, '123456');
    expect(completed, ['123456']);
    for (final d in ['1', '2', '3', '4', '5', '6']) {
      expect(find.text(d), findsOneWidget);
    }
  });

  testWidgets('SMS text pasted as-is keeps only the code digits',
      (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), '123-456');
    await tester.pump();
    expect(controller.text, '123456');
    expect(completed, ['123456']);
  });

  testWidgets('more than six digits are cut to six', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), '12345678');
    expect(controller.text, '123456');
  });

  testWidgets('a partial code does not complete; fixing it completes again',
      (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), '12345');
    expect(completed, isEmpty);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.enterText(find.byType(TextField), '12345');
    await tester.enterText(find.byType(TextField), '123457');
    expect(completed, ['123456', '123457']);
  });

  testWidgets('offers the platform one-time-code autofill', (tester) async {
    await pump(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autofillHints, contains(AutofillHints.oneTimeCode));
    expect(field.keyboardType, TextInputType.number);
  });

  testWidgets('disabled while verifying', (tester) async {
    await pump(tester, enabled: false);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
  });
}
