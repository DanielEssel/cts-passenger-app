// Controls whose own tap is hidden behind excludeSemantics must still expose
// a tap action to screen readers, run the same callback as a finger tap, and
// drop the action while disabled or busy.

import 'package:cts_transport_app/core/theme/cts_theme.dart';
import 'package:cts_transport_app/core/widgets/cts_ui.dart';
import 'package:cts_transport_app/features/auth/widgets/auth_widgets.dart';
import 'package:cts_transport_app/features/root/passenger_root_shell.dart';
import 'package:cts_transport_app/widgets/common/shared_widgets.dart';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
      theme: CtsTheme.light(),
      home: Scaffold(body: Center(child: child)),
    );

SemanticsData _data(WidgetTester t, Finder f) =>
    t.getSemantics(f).getSemanticsData();

bool _hasTap(WidgetTester t, Finder f) =>
    _data(t, f).hasAction(SemanticsAction.tap);

bool _on(Tristate v) => v == Tristate.isTrue;

/// Activates the node labelled [label] the way TalkBack / VoiceOver do: by
/// sending it a semantics tap action, not a pointer event.
Future<void> _screenReaderTap(WidgetTester t, Pattern label) async {
  t.semantics.tap(find.semantics.byLabel(label));
  await t.pumpAndSettle();
}

void main() {
  group('AuthBackButton (Signup, OTP)', () {
    Future<void> openSecondPage(WidgetTester t) async {
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                c,
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                      body: Center(child: AuthBackButton())),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.byType(AuthBackButton), findsOneWidget);
    }

    testWidgets('screen readers can activate it and it pops', (t) async {
      final h = t.ensureSemantics();
      await openSecondPage(t);
      final back = find.bySemanticsLabel('Back');
      expect(_hasTap(t, back), isTrue);
      expect(_data(t, back).flagsCollection.isButton, isTrue);
      await _screenReaderTap(t, 'Back');
      expect(find.byType(AuthBackButton), findsNothing);
      h.dispose();
    });

    testWidgets('a finger tap still pops', (t) async {
      await openSecondPage(t);
      await t.tap(find.byType(AuthBackButton));
      await t.pumpAndSettle();
      expect(find.byType(AuthBackButton), findsNothing);
    });
  });

  group('PassengerBottomNavBar', () {
    Future<List<int>> pumpNav(WidgetTester t,
        {int current = 0, int unread = 0}) async {
      final taps = <int>[];
      await t.pumpWidget(MaterialApp(
        theme: CtsTheme.light(),
        home: Scaffold(
          bottomNavigationBar: PassengerBottomNavBar(
            currentIndex: current,
            onTap: taps.add,
            unreadCount: unread,
          ),
        ),
      ));
      return taps;
    }

    testWidgets('every tab exposes a tap that selects that tab',
        (t) async {
      final h = t.ensureSemantics();
      final taps = await pumpNav(t);
      const labels = ['Home', 'History', 'Wallet', 'Profile'];
      for (var i = 0; i < labels.length; i++) {
        final tab = find.bySemanticsLabel(labels[i]);
        expect(_hasTap(t, tab), isTrue, reason: labels[i]);
        await _screenReaderTap(t, labels[i]);
        expect(taps.last, i, reason: labels[i]);
      }
      h.dispose();
    });

    testWidgets('marks the current tab as selected', (t) async {
      final h = t.ensureSemantics();
      await pumpNav(t, current: 2);
      expect(
          _on(_data(t, find.bySemanticsLabel('Wallet'))
              .flagsCollection
              .isSelected),
          isTrue);
      expect(
          _on(_data(t, find.bySemanticsLabel('Home'))
              .flagsCollection
              .isSelected),
          isFalse);
      h.dispose();
    });

    testWidgets('announces unread notifications on Home', (t) async {
      final h = t.ensureSemantics();
      await pumpNav(t, unread: 3);
      expect(find.bySemanticsLabel('Home, 3 unread'), findsOneWidget);
      h.dispose();
    });

    testWidgets('a finger tap reports the same index', (t) async {
      final taps = await pumpNav(t);
      await t.tap(find.text('Profile'));
      expect(taps, [3]);
    });
  });

  group('CtsCloseButton (ride and delivery matching cancel)', () {
    testWidgets('enabled: screen-reader tap runs the callback', (t) async {
      final h = t.ensureSemantics();
      var calls = 0;
      await t.pumpWidget(_host(CtsCloseButton(
          label: 'Cancel request', onTap: () => calls++)));
      final f = find.bySemanticsLabel('Cancel request');
      expect(_hasTap(t, f), isTrue);
      expect(_on(_data(t, f).flagsCollection.isEnabled), isTrue);
      await _screenReaderTap(t, 'Cancel request');
      expect(calls, 1);
      await t.tap(find.byType(CtsCloseButton));
      expect(calls, 2);
      h.dispose();
    });

    testWidgets('loading: no tap action, reported disabled, taps ignored',
        (t) async {
      final h = t.ensureSemantics();
      var calls = 0;
      await t.pumpWidget(_host(CtsCloseButton(
          label: 'Cancel request', loading: true, onTap: () => calls++)));
      final f = find.bySemanticsLabel('Cancel request');
      expect(_hasTap(t, f), isFalse);
      expect(_on(_data(t, f).flagsCollection.isEnabled), isFalse);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.tap(find.byType(CtsCloseButton), warnIfMissed: false);
      expect(calls, 0);
      h.dispose();
    });

    testWidgets('no callback: disabled', (t) async {
      final h = t.ensureSemantics();
      await t.pumpWidget(
          _host(const CtsCloseButton(label: 'Cancel request', onTap: null)));
      final f = find.bySemanticsLabel('Cancel request');
      expect(_hasTap(t, f), isFalse);
      expect(_on(_data(t, f).flagsCollection.isEnabled), isFalse);
      h.dispose();
    });
  });

  group('shared controls', () {
    testWidgets('filter chip: selected state and tap', (t) async {
      final h = t.ensureSemantics();
      var calls = 0;
      await t.pumpWidget(_host(CtsFilterChip(
          label: 'Rides', selected: true, onTap: () => calls++)));
      final f = find.bySemanticsLabel('Rides');
      expect(_on(_data(t, f).flagsCollection.isSelected), isTrue);
      await _screenReaderTap(t, 'Rides');
      expect(calls, 1);
      h.dispose();
    });

    testWidgets('list row: tappable row is a button that runs onTap',
        (t) async {
      final h = t.ensureSemantics();
      var calls = 0;
      await t.pumpWidget(_host(CtsListRow(
          icon: Icons.person_rounded,
          title: 'Edit profile',
          subtitle: 'Name, photo, email',
          onTap: () => calls++)));
      final f = find.bySemanticsLabel(RegExp('Edit profile'));
      expect(_data(t, f).flagsCollection.isButton, isTrue);
      await _screenReaderTap(t, RegExp('Edit profile'));
      expect(calls, 1);
      h.dispose();
    });

    testWidgets('primary button: loading ignores taps and drops the action',
        (t) async {
      final h = t.ensureSemantics();
      var calls = 0;
      await t.pumpWidget(_host(
          PrimaryButton(label: 'Save', onTap: () => calls++, isLoading: true)));
      final f = find.byType(PrimaryButton);
      await t.tap(f, warnIfMissed: false);
      expect(calls, 0);
      final node = _data(t, find.byType(PrimaryButton));
      expect(node.hasAction(SemanticsAction.tap), isFalse);
      h.dispose();
    });

    testWidgets('primary button: enabled tap runs once', (t) async {
      var calls = 0;
      await t.pumpWidget(
          _host(PrimaryButton(label: 'Save', onTap: () => calls++)));
      await t.tap(find.text('Save'));
      expect(calls, 1);
    });
  });
}
