// cred-05: the Settings > General app lock switch. Turning it on or off
// asks the lock, which authenticates first; a change that did not take
// leaves the switch as it was and says why.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/ghost_keystore.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/settings_window/settings_window_link.dart';
import 'package:poltergeist_app/ui/settings/app_lock_settings.dart';

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
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(child: AppLockSection(lock: lock)),
    ),
  );

  bool value(WidgetTester tester) =>
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value;

  testWidgets('a change that did not take leaves the switch as it was and '
      'says why', (tester) async {
    final lock = _FakeLock(result: AppLockChange.notAuthenticated);
    await tester.pumpWidget(wrap(lock));

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(lock.changes, 1);
    expect(lock.enabled, isFalse);
    expect(value(tester), isFalse);
    expect(find.textContaining('authentication failed'), findsOneWidget);
  });

  testWidgets('a device with no authentication says what to set up', (
    tester,
  ) async {
    final lock = _FakeLock(
      support: AppLockSupport.unavailable,
      result: AppLockChange.unavailable,
    );
    await tester.pumpWidget(wrap(lock));
    expect(find.textContaining('Set up a passcode'), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(lock.enabled, isFalse);
    expect(value(tester), isFalse);
    expect(find.textContaining('no authentication to ask for'), findsOneWidget);
  });

  testWidgets('a change whose save failed says so', (tester) async {
    final lock = _FakeLock(result: AppLockChange.notSaved);
    await tester.pumpWidget(wrap(lock));

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(lock.enabled, isFalse);
    expect(value(tester), isFalse);
    expect(find.textContaining('could not be saved'), findsOneWidget);
  });

  testWidgets('an unexpected failure says the change did not take', (
    tester,
  ) async {
    final lock = _FakeLock(
      failure: const SettingsLinkException('Settings link closed'),
    );
    await tester.pumpWidget(wrap(lock));

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(lock.enabled, isFalse);
    expect(value(tester), isFalse);
    expect(find.textContaining('did not change'), findsOneWidget);
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
    final lock = _FakeLock(support: AppLockSupport.unsupported);
    await tester.pumpWidget(wrap(lock));

    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.onChanged, isNull);
    expect(find.textContaining('no device authentication'), findsOneWidget);
  });
}
