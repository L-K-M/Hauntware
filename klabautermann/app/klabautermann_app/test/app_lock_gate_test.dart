import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/app_lock.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/app_lock_gate.dart';

import 'support/device_authenticator.dart';

/// SAF-20: the shared gate over the app's own lock controller.
void main() {
  late FakeDeviceAuthenticator device;

  setUp(() => device = FakeDeviceAuthenticator());

  AppLockController controller({bool enabled = true}) => AppLockController(
    authenticator: device,
    supported: true,
    enabled: enabled,
  );

  test('the model reports the lock and maps each unlock outcome', () async {
    final lock = controller();
    final model = AppLockGateModel(lock);
    addTearDown(lock.dispose);

    expect(model.locked, isTrue);
    await model.refreshAvailability();
    expect(model.locked, isTrue);

    device.accept = false;
    expect(await model.unlock(), GhostAppLockUnlock.failed);

    device.available = false;
    expect(await model.unlock(), GhostAppLockUnlock.unavailable);

    device.available = true;
    device.accept = true;
    expect(await model.unlock(), GhostAppLockUnlock.unlocked);
    expect(model.locked, isFalse);
  });

  Widget app(AppLockController lock) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => GhostAppLockGate(
      model: AppLockGateModel(lock),
      strings: GhostAppLockStrings(
        title: AppLocalizations.of(context).appLockTitle,
        detail: AppLocalizations.of(context).appLockDetail,
        unlock: AppLocalizations.of(context).appLockUnlock,
        failed: AppLocalizations.of(context).appLockFailed,
        unavailable: AppLocalizations.of(context).appLockUnavailable,
      ),
      child: child!,
    ),
    home: const Scaffold(body: Text('content')),
  );

  testWidgets('the gate over the controller asks by itself and unlocks', (
    tester,
  ) async {
    final lock = controller();
    addTearDown(lock.dispose);
    device.hold = Completer<void>();
    await tester.pumpWidget(app(lock));
    await tester.pump();

    expect(find.text('Klabautermann is locked'), findsOneWidget);
    expect(device.prompts, 1);

    device.hold!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Klabautermann is locked'), findsNothing);
  });

  testWidgets('a rebuild over the same controller does not ask again', (
    tester,
  ) async {
    final lock = controller();
    addTearDown(lock.dispose);
    device.accept = false;
    await tester.pumpWidget(app(lock));
    await tester.pumpAndSettle();
    expect(device.prompts, 1);
    expect(
      find.text('Authentication failed or was cancelled. Try again.'),
      findsOneWidget,
    );

    // A new wrapper over the same controller is the same lock: the failed
    // outcome stays and the gate does not ask again on its own.
    await tester.pumpWidget(app(lock));
    await tester.pumpAndSettle();
    expect(device.prompts, 1);

    device.accept = true;
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(device.prompts, 2);
    expect(find.text('Klabautermann is locked'), findsNothing);
  });
}
