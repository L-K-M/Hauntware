// The shared Settings app lock switch: turning it on or off asks the
// lock, which authenticates first; a change that did not take leaves the
// switch as it was and says why in the app's words. Moved from
// Poltergeist's app test, which keeps its ARB wording.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/ghost_keystore.dart';

final _strings = GhostAppLockSectionStrings(
  title: 'App lock',
  toggle: 'Require device authentication',
  detail: (minutes) => 'Locks after $minutes minutes in the background.',
  unsupported: 'No device authentication here.',
  unavailable: 'Set up a passcode first.',
  notChanged: (change) => 'Not changed: ${change?.name ?? 'other'}',
);

/// A lock the test decides: [result] answers a change, [failure] throws
/// instead, and [support] is what the switch and its note read.
final class _FakeLock extends ChangeNotifier implements AppLockSettings {
  _FakeLock({
    this.support = AppLockSupport.available,
    this.result = AppLockChange.changed,
    this.failure,
  });

  @override
  bool enabled = false;
  @override
  bool locked = false;
  @override
  AppLockSupport support;
  AppLockChange result;
  Object? failure;
  int changes = 0;

  @override
  Future<AppLockChange> setEnabled(bool value) async {
    changes++;
    final failure = this.failure;
    if (failure != null) throw failure;
    if (result == AppLockChange.changed) {
      enabled = value;
      notifyListeners();
    }
    return result;
  }
}

void main() {
  Widget wrap(_FakeLock lock) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: GhostAppLockSection(lock: lock, strings: _strings),
      ),
    ),
  );

  bool value(WidgetTester tester) =>
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value;

  testWidgets('shows the heading, the switch and how long until it locks', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(_FakeLock()));

    expect(find.text('App lock'), findsOneWidget);
    expect(find.text('Require device authentication'), findsOneWidget);
    expect(
      find.text('Locks after 5 minutes in the background.'),
      findsOneWidget,
    );
  });

  for (final change in [
    AppLockChange.notAuthenticated,
    AppLockChange.unavailable,
    AppLockChange.notSaved,
  ]) {
    testWidgets('a change refused as ${change.name} leaves the switch as it '
        'was and says why', (tester) async {
      final lock = _FakeLock(result: change);
      await tester.pumpWidget(wrap(lock));

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(lock.changes, 1);
      expect(lock.enabled, isFalse);
      expect(value(tester), isFalse);
      expect(find.text('Not changed: ${change.name}'), findsOneWidget);
    });
  }

  testWidgets('a device with no authentication says what to set up', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(_FakeLock(support: AppLockSupport.unavailable)),
    );

    expect(find.textContaining('Set up a passcode first.'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.onChanged, isNotNull);
  });

  testWidgets('an unexpected failure says the change did not take', (
    tester,
  ) async {
    final lock = _FakeLock(failure: Exception('Settings link closed'));
    await tester.pumpWidget(wrap(lock));

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(lock.enabled, isFalse);
    expect(value(tester), isFalse);
    expect(find.text('Not changed: other'), findsOneWidget);
  });

  testWidgets('a supported, unchanged change takes', (tester) async {
    final lock = _FakeLock();
    await tester.pumpWidget(wrap(lock));

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(lock.enabled, isTrue);
    expect(value(tester), isTrue);
  });

  testWidgets('an unsupported platform disables the switch', (tester) async {
    await tester.pumpWidget(
      wrap(_FakeLock(support: AppLockSupport.unsupported)),
    );

    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.onChanged, isNull);
    expect(
      find.textContaining('No device authentication here.'),
      findsOneWidget,
    );
  });
}
