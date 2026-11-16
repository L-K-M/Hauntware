import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/app_lock.dart';
import 'package:ghost_keystore/testing.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show FakeDialogs, MemoryDocuments;
import 'services/memory_settings.dart';

const _locked = 'Planchette is locked';

/// The app lock over the editor: off by default, and when on, the window
/// opens behind its screen, hot-exit documents included.
void main() {
  late DocumentWorkspace workspace;
  late FakeDeviceAuthenticator device;
  late MemorySettings store;
  late SettingsController settings;

  setUp(() {
    workspace = DocumentWorkspace(
      store: MemoryDocuments(),
      dialogs: FakeDialogs(),
    );
    addTearDown(workspace.dispose);
    device = FakeDeviceAuthenticator();
    store = MemorySettings();
  });

  /// The controller as `openAppLock` builds it, over the fake device.
  AppLockController lockFor({required bool enabled}) {
    settings = SettingsController(
      store: store,
      initial: AppSettings(themeMode: ThemeMode.light, appLock: enabled),
    );
    addTearDown(settings.dispose);
    final lock = AppLockController(
      authenticator: device,
      supported: true,
      enabled: settings.value.appLock,
      save: settings.saveAppLock,
    );
    addTearDown(lock.dispose);
    return lock;
  }

  Future<void> mount(WidgetTester tester, AppLockController lock) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: settings, appLock: lock),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pump();
  }

  /// Whether the document surface sits under the gate's semantics and
  /// pointer exclusion, so neither a screen reader nor a click reaches it.
  bool documentCovered(WidgetTester tester) {
    final document = find.byKey(const ValueKey('planchette.document'));
    final hidden = find.ancestor(
      of: document,
      matching: find.byWidgetPredicate(
        (widget) => widget is ExcludeSemantics && widget.excluding,
      ),
    );
    final inert = find.ancestor(
      of: document,
      matching: find.byWidgetPredicate(
        (widget) => widget is IgnorePointer && widget.ignoring,
      ),
    );
    return tester.any(hidden) && tester.any(inert);
  }

  testWidgets('with the lock off there is no gate and no prompt', (
    tester,
  ) async {
    workspace.newDocument()!.editor.text.text = 'restored draft';
    final lock = lockFor(enabled: false);
    await mount(tester, lock);
    await tester.pumpAndSettle();

    expect(find.text(_locked), findsNothing);
    expect(device.prompts, 0);
    expect(documentCovered(tester), isFalse);
  });

  testWidgets('with the lock on, a restored document opens behind the gate '
      'until the device authenticates', (tester) async {
    // What the hot-exit journal restores before the first frame.
    workspace.newDocument()!.editor.text.text = 'restored draft';
    final lock = lockFor(enabled: true);
    device.hold = Completer<void>();
    await mount(tester, lock);
    await tester.pump();

    expect(find.text(_locked), findsOneWidget);
    expect(device.prompts, 1, reason: 'the gate asks by itself at launch');
    expect(documentCovered(tester), isTrue);

    device.hold!.complete();
    await tester.pumpAndSettle();
    expect(find.text(_locked), findsNothing);
    expect(documentCovered(tester), isFalse);
    expect(workspace.documents.single.editor.text.text, 'restored draft');
  });

  testWidgets('a refused prompt keeps the gate and offers Unlock again', (
    tester,
  ) async {
    final lock = lockFor(enabled: true);
    device.accept = false;
    await mount(tester, lock);
    await tester.pumpAndSettle();

    expect(find.text(_locked), findsOneWidget);
    expect(
      find.text('Authentication failed or was cancelled. Try again.'),
      findsOneWidget,
    );

    device.accept = true;
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text(_locked), findsNothing);
    expect(device.prompts, 2);
  });

  testWidgets('Settings turns the lock on after authenticating and saves '
      'it', (tester) async {
    final lock = lockFor(enabled: false);
    await mount(tester, lock);
    await tester.pumpAndSettle();

    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings…'));
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(
      SwitchListTile,
      'Require device authentication',
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(device.prompts, 1);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(lock.enabled, isTrue);
    expect(lock.locked, isFalse, reason: 'turning it on just authenticated');
    expect(store.stored, contains('"appLock":true'));

    // Cancel keeps the lock: it was authenticated and saved on its own.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(settings.value.appLock, isTrue);
    expect(store.stored, contains('"appLock":true'));
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('a refused prompt leaves the lock off and unsaved', (
    tester,
  ) async {
    final lock = lockFor(enabled: false);
    await mount(tester, lock);
    await tester.pumpAndSettle();
    device.accept = false;

    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings…'));
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(
      SwitchListTile,
      'Require device authentication',
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(lock.enabled, isFalse);
    expect(settings.value.appLock, isFalse);
    expect(store.stored, isNull);
    expect(
      find.text(
        'The app lock did not change: authentication failed or was '
        'cancelled.',
      ),
      findsOneWidget,
    );
    // The toast's own timer.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('macOS: while locked the native menus offer only Quit', (
    tester,
  ) async {
    final delegate = _RecordingMenuDelegate();
    final original = WidgetsBinding.instance.platformMenuDelegate;
    WidgetsBinding.instance.platformMenuDelegate = delegate;
    addTearDown(() => WidgetsBinding.instance.platformMenuDelegate = original);
    workspace.newDocument()!.editor.text.text = 'restored draft';
    final lock = lockFor(enabled: true);
    device.hold = Completer<void>();
    await tester.pumpWidget(
      PlanchetteApp(
        workspace: workspace,
        settings: settings,
        appLock: lock,
        onQuit: () async {},
      ),
    );
    await tester.pump();

    final enabled = [
      for (final item in _leaves(delegate.menus))
        if (item.onSelected != null) item.label,
    ];
    expect(enabled, ['Quit Planchette']);

    device.hold!.complete();
    await tester.pumpAndSettle();
    final unlocked = [
      for (final item in _leaves(delegate.menus))
        if (item.onSelected != null) item.label,
    ];
    expect(unlocked, containsAll(['Settings…', 'Quit Planchette']));
    expect(unlocked.length, greaterThan(2));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}

/// Records native menu replacement without requiring AppKit's provided items.
final class _RecordingMenuDelegate extends PlatformMenuDelegate {
  List<PlatformMenuItem> menus = const [];

  @override
  void clearMenus() => menus = const [];

  @override
  void setMenus(List<PlatformMenuItem> topLevelMenus) => menus = topLevelMenus;

  @override
  bool debugLockDelegate(BuildContext context) => true;

  @override
  bool debugUnlockDelegate(BuildContext context) => true;
}

Iterable<PlatformMenuItem> _leaves(Iterable<PlatformMenuItem> menus) =>
    menus.expand(
      (item) => switch (item) {
        PlatformMenu(:final menus) => _leaves(menus),
        PlatformMenuItemGroup(:final members) => _leaves(members),
        _ => [item],
      },
    );
