// cred-05: the Settings > General app lock switch's ARB wording. The
// switch's behavior is ghost_keystore's GhostAppLockSection, tested
// there.
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

  testWidgets('the switch, its detail and its notes come from the ARB '
      'catalog', (tester) async {
    await tester.pumpWidget(
      wrap(_FakeLock(support: AppLockSupport.unavailable)),
    );

    expect(find.text('App lock'), findsOneWidget);
    expect(find.text('Require device authentication'), findsOneWidget);
    expect(
      find.textContaining('after 5 minutes in the background'),
      findsOneWidget,
    );
    expect(find.textContaining('Set up a passcode'), findsOneWidget);

    await tester.pumpWidget(
      wrap(_FakeLock(support: AppLockSupport.unsupported)),
    );
    expect(find.textContaining('no device authentication'), findsOneWidget);
  });

  final refusals = <String, _FakeLock Function()>{
    'authentication failed': () =>
        _FakeLock(result: AppLockChange.notAuthenticated),
    'no authentication to ask for': () =>
        _FakeLock(result: AppLockChange.unavailable),
    'could not be saved': () => _FakeLock(result: AppLockChange.notSaved),
    'The app lock did not change.': () =>
        _FakeLock(failure: const SettingsLinkException('Settings link closed')),
  };
  for (final MapEntry(key: words, value: lock) in refusals.entries) {
    testWidgets('a change that did not take says "$words"', (tester) async {
      await tester.pumpWidget(wrap(lock()));

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(find.textContaining(words), findsOneWidget);
    });
  }
}
