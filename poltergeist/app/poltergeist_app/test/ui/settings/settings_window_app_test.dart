import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/app_lock.dart'
    show AppLockChange, AppLockSettings, AppLockSupport;
import 'package:planchette_editor/planchette_editor.dart' show EditorLigatures;
import 'package:poltergeist_app/services/appearance_controller.dart';
import 'package:poltergeist_app/services/directory_grouping_controller.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/double_click_action_controller.dart';
import 'package:poltergeist_app/services/editor_font_controller.dart';
import 'package:poltergeist_app/services/editor_text_size_controller.dart';
import 'package:poltergeist_app/services/settings_window/remote_settings.dart';
import 'package:poltergeist_app/services/settings_window/settings_window_host.dart';
import 'package:poltergeist_app/services/settings_window/settings_window_link.dart';
import 'package:poltergeist_app/settings_window_app.dart';
import 'package:poltergeist_app/theme/app_appearance.dart';
import 'package:poltergeist_app/theme/theme_presets.dart';
import 'package:poltergeist_app/ui/settings/app_lock_settings.dart';
import 'package:poltergeist_app/ui/settings/appearance_settings.dart';
import 'package:poltergeist_app/ui/settings/backup_settings.dart';
import 'package:poltergeist_app/ui/settings/directory_grouping_settings.dart';
import 'package:poltergeist_app/ui/settings/double_click_action_settings.dart';
import 'package:poltergeist_app/ui/settings/editor_font_settings.dart';
import 'package:poltergeist_app/ui/settings/editor_text_size_settings.dart';
import 'package:poltergeist_app/ui/settings/general_settings.dart';
import 'package:poltergeist_app/ui/settings/preview_settings.dart';
import 'package:poltergeist_app/ui/settings/recovery_settings.dart';
import 'package:poltergeist_core/poltergeist_core.dart' show DirectoryGrouping;

import '../../support/fake_backup_settings.dart';
import '../../support/fake_recovery_settings.dart';

const _appLink = MethodChannel('test/settings_window_app/app');
const _windowLink = MethodChannel('test/settings_window_app/window');
const _control = MethodChannel('test/settings_window_app/control');

/// The app lock with scripted state, notifying like the controller does.
final class _ManualAppLock extends ChangeNotifier implements AppLockSettings {
  @override
  bool enabled = false;

  @override
  bool locked = false;

  @override
  AppLockSupport get support => AppLockSupport.available;

  @override
  Future<AppLockChange> setEnabled(bool enabled) async {
    this.enabled = enabled;
    notifyListeners();
    return AppLockChange.changed;
  }
}

/// The Settings window's own app over a real host: the tabs follow the
/// sections the app has, a tab request switches them, and a window that
/// loses the app says so.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SettingsWindowHost host;
  late AppearanceController appearance;
  late EditorTextSizeController editorTextSize;
  late EditorFontController editorFont;
  late DirectoryGroupingController directoryGrouping;
  late DoubleClickActionController doubleClickAction;
  late _ManualAppLock appLock;
  late FakeBackupSettings backup;
  late FakeRecoverySettings recovery;
  late bool checkForUpdates;
  final updates = ChangeNotifier();

  void relay(MethodChannel from, MethodChannel to) {
    messenger.setMockMessageHandler(from.name, (message) {
      final reply = Completer<ByteData?>();
      ServicesBinding.instance.channelBuffers.push(
        to.name,
        message,
        reply.complete,
      );
      return reply.future;
    });
  }

  setUp(() {
    relay(_appLink, _windowLink);
    relay(_windowLink, _appLink);
    messenger.setMockMethodCallHandler(_control, (_) async => null);
    appearance = AppearanceController(
      initial: AppAppearance(palette: ThemePresets.midnight),
    );
    checkForUpdates = true;
    editorTextSize = EditorTextSizeController(initial: 18);
    addTearDown(editorTextSize.dispose);
    editorFont = EditorFontController();
    addTearDown(editorFont.dispose);
    directoryGrouping = DirectoryGroupingController();
    addTearDown(directoryGrouping.dispose);
    doubleClickAction = DoubleClickActionController();
    addTearDown(doubleClickAction.dispose);
    appLock = _ManualAppLock();
    addTearDown(appLock.dispose);
    backup = FakeBackupSettings();
    addTearDown(backup.dispose);
    recovery = FakeRecoverySettings();
    addTearDown(recovery.dispose);
    host = SettingsWindowHost(control: _control, link: _appLink)
      ..attach(
        SettingsWindowSources(
          general: () => GeneralSettings(
            checkForUpdates: checkForUpdates,
            onCheckForUpdatesChanged: (_) async {},
          ),
          appearance: appearance,
          editorTextSize: editorTextSize,
          editorFont: editorFont,
          directoryGrouping: directoryGrouping,
          doubleClickAction: doubleClickAction,
          appLock: appLock,
          backup: backup,
          recovery: recovery,
          changes: [updates],
          previewDownloads: () => PreviewDownloadsSettings(
            available: true,
            capacityBytes: 512 << 20,
            thresholdBytes: 100 << 20,
            onCapacityChanged: (_) async {},
            onThresholdChanged: (_) async {},
            onClearCache: () async => 0,
          ),
        ),
      );
  });

  tearDown(() {
    host.dispose();
    for (final channel in [_appLink, _windowLink]) {
      messenger.setMockMessageHandler(channel.name, null);
    }
    messenger.setMockMethodCallHandler(_control, null);
  });

  Future<RemoteSettings> pumpWindow(
    WidgetTester tester,
    SettingsWindowTab tab,
  ) async {
    final remote = (await tester.runAsync(() async {
      await host.open(tab);
      return RemoteSettings.connect(link: _windowLink);
    }))!;
    addTearDown(remote.dispose);
    await tester.pumpWidget(SettingsWindowApp(remote: remote));
    await tester.pumpAndSettle();
    return remote;
  }

  testWidgets('shows a tab per section the app has, on the one asked for', (
    tester,
  ) async {
    await pumpWindow(tester, SettingsWindowTab.editing);

    expect(find.widgetWithText(Tab, 'General'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Appearance'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Editing'), findsOneWidget);
    // In SettingsWindowTab's order: Appearance follows General, and
    // Sync follows Editing now that the app has the Backup service.
    expect(
      tester
          .widget<TabBar>(find.byType(TabBar))
          .tabs
          .map((tab) => (tab as Tab).text),
      ['General', 'Appearance', 'Editing', 'Sync'],
    );
    expect(find.widgetWithText(Tab, 'Sync'), findsOneWidget);
    expect(find.text('Preview cache limit'), findsOneWidget);
  });

  testWidgets('the Editing tab opens with the double-click action, which '
      'the app follows', (tester) async {
    await pumpWindow(tester, SettingsWindowTab.editing);
    Finder dropdown() =>
        find.byKey(const ValueKey('editing.doubleClickAction'));

    expect(
      tester.getRect(find.byType(DoubleClickActionSection)).top,
      lessThan(tester.getRect(find.byType(PreviewDownloadsSection)).top),
    );
    expect(
      tester.widget<DropdownButton<DoubleClickAction>>(dropdown()).value,
      DoubleClickAction.open,
    );

    await tester.tap(dropdown());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit in Poltergeist').last);
    // The dropdown shows the choice at once, before the app answers.
    await tester.pump();
    expect(
      tester.widget<DropdownButton<DoubleClickAction>>(dropdown()).value,
      DoubleClickAction.edit,
    );
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();

    expect(doubleClickAction.value, DoubleClickAction.edit);
    expect(
      tester.widget<DropdownButton<DoubleClickAction>>(dropdown()).value,
      DoubleClickAction.edit,
    );
  });

  testWidgets('a tab request switches the showing window', (tester) async {
    await pumpWindow(tester, SettingsWindowTab.editing);

    await tester.runAsync(() => host.open(SettingsWindowTab.general));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('updates.checkEnabled')), findsOneWidget);
  });

  testWidgets('a tab swaps its page in place instead of sliding to it', (
    tester,
  ) async {
    await pumpWindow(tester, SettingsWindowTab.editing);
    final editing = tester.getRect(
      find.byKey(const PageStorageKey(SettingsWindowTab.editing)),
    );

    await tester.tap(find.widgetWithText(Tab, 'General'));
    await tester.pump();

    // The first frame after the tap: all of the new page, where the old one
    // was, and none of the old.
    expect(find.text('Preview cache limit'), findsNothing);
    expect(
      tester.getRect(
        find.byKey(const PageStorageKey(SettingsWindowTab.general)),
      ),
      editing,
    );
  });

  testWidgets('a sideways swipe does not change the tab', (tester) async {
    await pumpWindow(tester, SettingsWindowTab.editing);

    await tester.fling(
      find.text('Preview cache limit'),
      const Offset(600, 0),
      2000,
    );
    await tester.pumpAndSettle();

    expect(find.text('Preview cache limit'), findsOneWidget);
  });

  testWidgets('a window with no sections says so and closes cleanly', (
    tester,
  ) async {
    host.attach(const SettingsWindowSources());
    await pumpWindow(tester, SettingsWindowTab.general);
    expect(find.text('Nothing to set here yet.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Appearance tab is the section, over the app\'s theme', (
    tester,
  ) async {
    await pumpWindow(tester, SettingsWindowTab.appearance);

    expect(find.byType(AppearanceSection), findsOneWidget);
    expect(find.byTooltip('Use the Midnight theme'), findsOneWidget);
    expect(find.text('Using Midnight.'), findsOneWidget);
  });

  testWidgets('the Appearance tab ends with the editor text size', (
    tester,
  ) async {
    await pumpWindow(tester, SettingsWindowTab.appearance);

    // The page is a lazy list: scroll the section into being.
    await tester.scrollUntilVisible(
      find.byType(EditorTextSizeSection),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey(SettingsWindowTab.appearance)),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('18 pt'), findsOneWidget);
  });

  testWidgets('the editor font follows the text size, and writes the app\'s '
      'font', (tester) async {
    await pumpWindow(tester, SettingsWindowTab.appearance);
    final ligatures = find.byKey(const ValueKey('editor.ligatures'));
    await tester.scrollUntilVisible(
      ligatures,
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey(SettingsWindowTab.appearance)),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      tester.getRect(find.byType(EditorFontSection)).top,
      greaterThan(tester.getRect(find.byType(EditorTextSizeSection)).top),
    );

    await tester.ensureVisible(ligatures);
    await tester.pumpAndSettle();
    await tester.tap(ligatures);
    await tester.pump();
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();

    expect(editorFont.value.ligatures, EditorLigatures.off);
  });

  testWidgets('the General tab ends with the folders switch, which '
      "writes the app's grouping", (tester) async {
    await pumpWindow(tester, SettingsWindowTab.general);
    Finder toggle() => find.byKey(const ValueKey('view.foldersOnTop'));

    expect(
      tester.getRect(find.byType(DirectoryGroupingSection)).top,
      greaterThan(tester.getRect(find.byType(GeneralSection)).top),
    );
    expect(tester.widget<SwitchListTile>(toggle()).value, isTrue);

    await tester.tap(toggle());
    // The switch shows the flip at once, before the app answers.
    await tester.pump();
    expect(tester.widget<SwitchListTile>(toggle()).value, isFalse);
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();

    expect(directoryGrouping.value, DirectoryGrouping.mixed);
    expect(tester.widget<SwitchListTile>(toggle()).value, isFalse);
  });

  testWidgets('the Sync tab carries Recovery beside the Backup section, '
      'and its actions run in the app', (tester) async {
    await pumpWindow(tester, SettingsWindowTab.sync);

    expect(find.byType(BackupSettingsSection), findsOneWidget);
    expect(find.byType(RecoverySection), findsOneWidget);
    expect(find.text('Recovery'), findsOneWidget);
    expect(find.text('This device has no recovery code yet.'), findsOneWidget);

    final setUp = find.byKey(const ValueKey('recovery.setUp'));
    await tester.ensureVisible(setUp);
    await tester.pumpAndSettle();
    await tester.tap(setUp);
    // The code crosses the link to the app's isolate and back.
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    final code = tester
        .widget<SelectableText>(find.byKey(const ValueKey('recovery.code')))
        .data!;
    await tester.enterText(
      find.byKey(const ValueKey('recovery.code.confirm')),
      code.split('-').first,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('recovery.code.done')));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();

    expect(recovery.calls, ['newRecoveryCode', 'saveRecoveryCode']);
    expect(recovery.configured, isTrue);
  });

  testWidgets('the General tab\'s app lock switch asks in the app and '
      'follows it', (tester) async {
    final remote = await pumpWindow(tester, SettingsWindowTab.general);
    expect(find.byType(AppLockSection), findsOneWidget);
    SwitchListTile lockSwitch() => tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('Require device authentication'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(lockSwitch().value, isFalse);
    expect(remote.appLock.support, AppLockSupport.available);

    await tester.tap(find.text('Require device authentication'));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();

    expect(appLock.enabled, isTrue);
    expect(remote.appLock.enabled, isTrue);
    expect(lockSwitch().value, isTrue);
  });

  testWidgets('while the app is locked the window covers its settings and '
      'the app refuses its calls', (tester) async {
    final remote = await pumpWindow(tester, SettingsWindowTab.general);
    expect(find.byType(GeneralSection), findsOneWidget);

    await tester.runAsync(() async {
      appLock.locked = true;
      appLock.notifyListeners();
      await pumpEventQueue();
    });
    await tester.pumpAndSettle();
    expect(find.text('Poltergeist is locked'), findsOneWidget);
    expect(find.byType(GeneralSection), findsNothing);

    // A call already on its way when the lock engaged changes nothing.
    await tester.runAsync(() async {
      await expectLater(
        remote.general!.onCheckForUpdatesChanged(false),
        throwsA(isA<SettingsLinkException>()),
      );
    });
    // The app's error reporter hears of the refusal, as of any other.
    expect(tester.takeException(), isA<AppLockedException>());
    expect(checkForUpdates, isTrue);

    await tester.runAsync(() async {
      appLock.locked = false;
      appLock.notifyListeners();
      await pumpEventQueue();
    });
    await tester.pumpAndSettle();
    expect(find.text('Poltergeist is locked'), findsNothing);
    expect(find.byType(GeneralSection), findsOneWidget);
  });

  testWidgets('a window opened while the app is locked shows the notice '
      'from its first frame', (tester) async {
    appLock.locked = true;
    await pumpWindow(tester, SettingsWindowTab.general);

    expect(find.text('Poltergeist is locked'), findsOneWidget);
    expect(find.byType(GeneralSection), findsNothing);
  });

  testWidgets('the window follows the app\'s theme, and only its theme', (
    tester,
  ) async {
    final remote = await pumpWindow(tester, SettingsWindowTab.general);
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app().theme?.colorScheme.surface, ThemePresets.midnight.surface);

    // Most snapshots carry nothing about the theme.
    final before = app();
    checkForUpdates = false;
    await tester.runAsync(() async {
      updates.notifyListeners();
      await pumpEventQueue();
    });
    await tester.pumpAndSettle();
    expect(remote.general?.checkForUpdates, isFalse);
    expect(app(), same(before));

    await tester.runAsync(() async {
      await appearance.setAppearance(
        ThemePresets.paper,
        ThemeModePreference.system,
      );
      await pumpEventQueue();
    });
    await tester.pumpAndSettle();
    expect(app(), isNot(same(before)));
    expect(app().theme?.colorScheme.surface, ThemePresets.paper.surface);
    final screen = tester.element(find.byType(SettingsWindowScreen));
    expect(Theme.of(screen).colorScheme.surface, ThemePresets.paper.surface);
  });

  testWidgets('a window that loses the app says so', (tester) async {
    final remote = await pumpWindow(tester, SettingsWindowTab.general);

    messenger.setMockMessageHandler(_windowLink.name, (_) async => null);
    await tester.runAsync(remote.requestAppExit);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Settings could not reach Poltergeist. Close this window and open '
        'Settings again.',
      ),
      findsOneWidget,
    );
  });
}
