import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/ghost_keystore.dart'
    show appLockBackgroundTimeout;
import 'package:klabautermann_app/controllers/app_lock_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/app_lock_gate.dart';

import 'support/device_authenticator.dart';

const _title = 'Klabautermann is locked';
const _content = 'fleet content';

/// SAF-20: the lock screen over the whole app.
void main() {
  late FakeDeviceAuthenticator device;
  late Duration elapsed;
  late DateTime wall;
  late int locks;
  late int taps;

  setUp(() {
    device = FakeDeviceAuthenticator();
    elapsed = Duration.zero;
    wall = DateTime.utc(2026, 10, 25, 12);
    locks = 0;
    taps = 0;
  });

  Future<AppLockController> pump(
    WidgetTester tester, {
    bool enabled = true,
  }) async {
    final lock = AppLockController(
      authenticator: device,
      supported: true,
      enabled: enabled,
      onLocked: () => locks++,
      elapsed: () => elapsed,
      wallClock: () => wall,
    );
    addTearDown(lock.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => AppLockGate(lock: lock, child: child!),
        home: Scaffold(
          body: TextButton(
            onPressed: () => taps++,
            child: const Text(_content),
          ),
        ),
      ),
    );
    return lock;
  }

  testWidgets('off, the app shows at once and never asks', (tester) async {
    await pump(tester, enabled: false);
    await tester.pumpAndSettle();

    expect(find.text(_title), findsNothing);
    expect(find.text(_content), findsOneWidget);
    expect(device.prompts, 0);
  });

  testWidgets('on, the app opens behind the lock screen, which asks by '
      'itself and hides the app from touch and screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    device.hold = Completer<void>();
    final lock = await pump(tester);
    await tester.pump();

    expect(device.prompts, 1);
    expect(find.text(_title), findsOneWidget);
    expect(find.bySemanticsLabel(_content), findsNothing);
    expect(find.bySemanticsLabel(_title), findsOneWidget);
    // A tap on the app beneath reaches nothing.
    await tester.tap(find.text(_content), warnIfMissed: false);
    expect(taps, 0);

    device.hold!.complete();
    await tester.pumpAndSettle();
    expect(lock.locked, isFalse);
    expect(find.text(_title), findsNothing);
    expect(find.bySemanticsLabel(_content), findsOneWidget);
    expect(device.prompts, 1);
    semantics.dispose();
  });

  testWidgets('a rejected prompt says so and Unlock asks again', (
    tester,
  ) async {
    device.accept = false;
    await pump(tester);
    await tester.pumpAndSettle();

    expect(
      find.text('Authentication failed or was cancelled. Try again.'),
      findsOneWidget,
    );
    expect(device.prompts, 1);

    device.accept = true;
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(device.prompts, 2);
    expect(find.text(_title), findsNothing);
  });

  testWidgets('a device with no authentication says what to set up', (
    tester,
  ) async {
    device.available = false;
    await pump(tester);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This device has no passcode, PIN or biometrics to ask for. Set '
        'one up, then try again.',
      ),
      findsOneWidget,
    );
    expect(device.prompts, 0);
  });

  testWidgets('back from the background past the timeout, the lock screen '
      'returns and asks again; sooner, it does not', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    elapsed += const Duration(minutes: 1);
    wall = wall.add(const Duration(minutes: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
    expect(device.prompts, 1);

    device.hold = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    elapsed += appLockBackgroundTimeout;
    wall = wall.add(appLockBackgroundTimeout);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(find.text(_title), findsOneWidget);
    expect(locks, 1);
    expect(device.prompts, 2);
    device.hold!.complete();
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
  });
}
