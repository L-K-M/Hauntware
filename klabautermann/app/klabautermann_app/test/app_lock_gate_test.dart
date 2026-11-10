import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/ghost_keystore.dart'
    show appLockBackgroundTimeout;
import 'package:klabautermann_app/controllers/app_lock_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/app_lock_gate.dart';
import 'package:klabautermann_app/ui/menus/app_commands.dart';
import 'package:klabautermann_app/ui/menus/app_menu_host.dart';

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

  testWidgets('a prompt that fails some other way leaves Unlock working', (
    tester,
  ) async {
    device.failWith = StateError('channel lost');
    await pump(tester);
    await tester.pumpAndSettle();

    // ghost_keystore's AppLock turns any failure into a refusal, so the
    // screen says the prompt failed rather than waiting on it.
    expect(
      find.text('Authentication failed or was cancelled. Try again.'),
      findsOneWidget,
    );

    device.failWith = null;
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

  testWidgets('a new controller asks by itself again', (tester) async {
    device.accept = false;
    await pump(tester);
    await tester.pumpAndSettle();
    expect(device.prompts, 1);

    device.accept = true;
    await pump(tester);
    await tester.pumpAndSettle();
    expect(device.prompts, 2);
    expect(find.text(_title), findsNothing);
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

  testWidgets('a dialog open when the lock engages stays covered and gives '
      'up focus', (tester) async {
    final lock = await pump(tester);
    await tester.pumpAndSettle();
    var dialogTaps = 0;
    unawaited(
      showDialog<void>(
        context: tester.element(find.text(_content)),
        builder: (_) => AlertDialog(
          content: TextButton(
            autofocus: true,
            onPressed: () => dialogTaps++,
            child: const Text('dialog action'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final action = find.text('dialog action');
    expect(Focus.of(tester.element(action)).hasFocus, isTrue);

    device.hold = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    elapsed += appLockBackgroundTimeout;
    wall = wall.add(appLockBackgroundTimeout);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(lock.locked, isTrue);
    expect(find.text(_title), findsOneWidget);
    expect(Focus.of(tester.element(action)).hasFocus, isFalse);
    await tester.tap(action, warnIfMissed: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(dialogTaps, 0);

    device.hold!.complete();
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
    await tester.tap(action);
    expect(dialogTaps, 1);
  });

  group('the app menus behind the lock (03 §8.13)', () {
    late List<String> runs;

    AppCommand command(
      String id, {
      required int order,
      List<ShortcutActivator> keys = const [],
    }) => AppCommand(
      id: id,
      label: (_) => id,
      activators: (_) => keys,
      run: (_) async => runs.add(id),
      menuPlacement: CommandMenuPlacement(menu: AppMenuId.edit, order: order),
    );

    /// The app's shape: the menu host inside the gate's child, as
    /// KlabautermannApp mounts it, over a lock that stays locked.
    Future<AppLockController> pumpMenus(WidgetTester tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.menu,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.menu,
          null,
        ),
      );
      runs = [];
      device.accept = false;
      final lock = AppLockController(
        authenticator: device,
        supported: true,
        enabled: true,
        elapsed: () => elapsed,
        wallClock: () => wall,
      );
      addTearDown(lock.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: defaultTargetPlatform),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => AppLockGate(lock: lock, child: child!),
          home: AppMenuHost(
            locked: () => lock.locked,
            listenable: lock,
            commands: [
              command(
                kEditUndoCommandId,
                order: 10,
                keys: const [
                  SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
                ],
              ),
              command(kAppSettingsCommandId, order: 20),
            ],
            child: const Scaffold(body: Text(_content)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(lock.locked, isTrue);
      return lock;
    }

    PlatformMenuItem item(WidgetTester tester, String label) {
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      PlatformMenuItem? search(List<PlatformMenuItem> items) {
        for (final item in items) {
          if (item.label == label && item is! PlatformMenu) return item;
          final children = switch (item) {
            PlatformMenu(:final menus) => menus,
            PlatformMenuItemGroup(:final members) => members,
            _ => const <PlatformMenuItem>[],
          };
          if (search(children) case final found?) return found;
        }
        return null;
      }

      return search(bar.menus)!;
    }

    testWidgets('macOS: while locked the native items are disabled but '
        'Settings, and come back on unlock', (tester) async {
      final lock = await pumpMenus(tester);

      expect(item(tester, kEditUndoCommandId).onSelected, isNull);
      // Settings shows its own locked notice in its window.
      item(tester, kAppSettingsCommandId).onSelected!();
      await tester.pump();
      expect(runs, [kAppSettingsCommandId]);

      device.accept = true;
      await lock.unlock();
      await tester.pumpAndSettle();
      item(tester, kEditUndoCommandId).onSelected!();
      await tester.pump();
      expect(runs, [kAppSettingsCommandId, kEditUndoCommandId]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a command chord runs nothing while locked', (tester) async {
      await pumpMenus(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(runs, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });
}
