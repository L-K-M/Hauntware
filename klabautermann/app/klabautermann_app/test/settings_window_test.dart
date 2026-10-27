import 'dart:async';
import 'dart:io' show FileSystemException;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart' show GhostSettingsLinkMethod;
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/app.dart';
import 'package:klabautermann_app/app_identity.dart';
import 'package:klabautermann_app/controllers/announcement_controller.dart';
import 'package:klabautermann_app/controllers/app_lock_controller.dart';
import 'package:klabautermann_app/controllers/sync_secrets_controller.dart';
import 'package:klabautermann_app/controllers/threshold_controller.dart';
import 'package:klabautermann_app/controllers/appearance_controller.dart';
import 'package:klabautermann_app/controllers/coverage_controller.dart';
import 'package:klabautermann_app/controllers/device_name.dart';
import 'package:klabautermann_app/controllers/docker_notice_controller.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitor_set.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/prompt_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/services/settings_window/remote_settings.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_host.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_link.dart';
import 'package:klabautermann_app/settings_window_app.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/settings_page.dart';
import 'package:klabautermann_app/ui/charts/charts.dart' show ChartThresholds;
import 'package:klabautermann_app/ui/threshold_scope.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show MonitorEligibility, SafetyPolicy, ServerSafety;

import 'support/device_authenticator.dart';
import 'support/fake_engine.dart';
import 'support/harness.dart';

// One engine in a test, so the two ends of the link get a channel each and a
// relay between them stands in for the runners' byte-for-byte forwarding.
const _control = MethodChannel('test/settings_window');
const _appLink = MethodChannel('test/settings_link/app');
const _windowLink = MethodChannel('test/settings_link/window');

/// What the app's `readAppVersion` read, which the window cannot read.
const _appVersion = '1.2.3';

/// An app whose appearance refuses every change.
final class _RefusingAppearance extends ChangeNotifier
    implements AppearanceSettings {
  @override
  AppAppearance get value =>
      AppAppearance(palette: klabautermannThemePresets.initial);

  @override
  Future<void> setMode(ThemeModePreference mode) async =>
      throw StateError('read-only appearance');

  @override
  Future<void> setAppearance(
    ThemePalette palette,
    ThemeModePreference mode,
  ) async => throw StateError('read-only appearance');
}

/// An app lock the test locks and unlocks by hand.
final class _ManualAppLock extends ChangeNotifier implements AppLockSettings {
  @override
  bool get enabled => true;

  @override
  AppLockSupport get support => AppLockSupport.available;

  @override
  bool get locked => _locked;
  bool _locked = false;
  set locked(bool locked) {
    _locked = locked;
    notifyListeners();
  }

  @override
  Future<AppLockChange> setEnabled(bool enabled) async => AppLockChange.changed;
}

/// The desktop settings window (03 §10.2, D32) over fake channels: the main
/// window asks the runner for it (phones push the route), and the window,
/// on a second engine that shares nothing with the app's, changes the app's
/// appearance only through the link.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> controlCalls;

  /// Deliver what one end sends to the other end's handler, and its reply
  /// back: what the runners do between the two engines.
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

  /// A runner with a settings window: records each control call.
  void runnerWithWindow() {
    messenger.setMockMethodCallHandler(_control, (call) async {
      controlCalls.add(call.method);
      return null;
    });
  }

  setUp(() {
    controlCalls = [];
    relay(_appLink, _windowLink);
    relay(_windowLink, _appLink);
  });

  tearDown(() {
    for (final channel in [_appLink, _windowLink]) {
      messenger.setMockMessageHandler(channel.name, null);
    }
    messenger.setMockMethodCallHandler(_control, null);
  });

  /// A fleet controller over a fake engine, disposed after the test.
  FleetController newFleet([List<FleetServer> servers = const []]) {
    final engine = FakeEngineClient();
    final fleet = FleetController(engine, servers: servers);
    addTearDown(() async {
      fleet.dispose();
      await engine.close();
    });
    return fleet;
  }

  /// A safety controller applying to nothing, disposed after the test.
  SafetyController newSafety([SafetyPolicy initial = const SafetyPolicy()]) {
    final safety = SafetyController(initial: initial, apply: (_) {});
    addTearDown(safety.dispose);
    return safety;
  }

  /// A sync passwords switch applying to nothing, disposed after the test.
  SyncSecretsController newSyncSecrets() {
    final syncSecrets = SyncSecretsController(apply: (_) {});
    addTearDown(syncSecrets.dispose);
    return syncSecrets;
  }

  /// A device name applying to nothing, disposed after the test.
  DeviceNameController newDeviceName() {
    final deviceName = DeviceNameController(
      fallback: 'Klabautermann on Linux',
      apply: (_) {},
    );
    addTearDown(deviceName.dispose);
    return deviceName;
  }

  SettingsWindowHost newHost(
    AppearanceSettings appearance, [
    AnnouncementSettings? announcements,
    MonitorSetSettings? monitorSet,
    SafetySettings? safety,
    SyncSecretsSettings? syncSecrets,
    DeviceNameSettings? deviceName,
    AppLockSettings? appLock,
    ThresholdSettings? thresholds,
  ]) {
    final host = SettingsWindowHost(
      appearance: appearance,
      announcements: announcements ?? AnnouncementController(),
      deviceName: deviceName ?? newDeviceName(),
      appVersion: _appVersion,
      monitorSet: monitorSet ?? newFleet().monitorSettings,
      safety: safety ?? newSafety(),
      syncSecrets: syncSecrets ?? newSyncSecrets(),
      appLock: appLock,
      thresholds: thresholds,
      control: _control,
      link: _appLink,
      requestAppExit: () async => AppExitResponse.exit,
    );
    addTearDown(host.dispose);
    return host;
  }

  group('the main window', () {
    testWidgets('on desktop, Settings opens the settings window', (
      tester,
    ) async {
      runnerWithWindow();
      final appearance = AppearanceController();
      final host = newHost(appearance);
      await pumpApp(
        tester,
        appearance: appearance,
        openSettingsWindow: host.open,
      );

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(controlCalls, ['open']);
      // The window shows Settings; the main window pushes nothing.
      expect(find.byType(SettingsPage), findsNothing);
    });

    testWidgets('a desktop runner without the window falls back to the '
        'route', (tester) async {
      // Nothing answers the control channel: a runner from before the
      // window.
      messenger.setMockMessageHandler(_control.name, (_) async => null);
      final appearance = AppearanceController();
      final host = newHost(appearance);
      await pumpApp(
        tester,
        appearance: appearance,
        openSettingsWindow: host.open,
      );

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('a runner that cannot create the window falls back to the '
        'route', (tester) async {
      messenger.setMockMethodCallHandler(_control, (call) async {
        controlCalls.add(call.method);
        throw PlatformException(code: 'open_failed');
      });
      final appearance = AppearanceController();
      final host = newHost(appearance);
      await pumpApp(
        tester,
        appearance: appearance,
        openSettingsWindow: host.open,
      );

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(controlCalls, ['open']);
      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('a window that fails with an error, not an exception, '
        'still falls back to the route', (tester) async {
      await pumpApp(
        tester,
        openSettingsWindow: (_) async => throw StateError('host disposed'),
      );

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      // Reported, and Settings is still reachable.
      expect(tester.takeException(), isA<StateError>());
      expect(find.byType(SettingsPage), findsOneWidget);
    });

    test('only the desktops get a settings window host', () {
      final appearance = AppearanceController();
      final announcements = AnnouncementController();
      addTearDown(appearance.dispose);
      addTearDown(announcements.dispose);
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          settingsWindowHostFor(
            platform,
            appearance: appearance,
            announcements: announcements,
            deviceName: newDeviceName(),
            appVersion: _appVersion,
            monitorSet: newFleet().monitorSettings,
            safety: newSafety(),
            syncSecrets: newSyncSecrets(),
          ),
          isNull,
          reason: '$platform',
        );
      }
      for (final platform in [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        final host = settingsWindowHostFor(
          platform,
          appearance: appearance,
          announcements: announcements,
          deviceName: newDeviceName(),
          appVersion: _appVersion,
          monitorSet: newFleet().monitorSettings,
          safety: newSafety(),
          syncSecrets: newSyncSecrets(),
        );
        expect(host, isNotNull, reason: '$platform');
        host!.dispose();
      }
    });

    testWidgets('without a host, as on a phone, Settings is the route and '
        'no window is asked for', (tester) async {
      runnerWithWindow();
      await pumpApp(tester, size: const Size(400, 800));

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(controlCalls, isEmpty);
      expect(find.byType(SettingsPage), findsOneWidget);
    });
  });

  group('the settings window', () {
    late AppearanceController appearance;
    late AnnouncementController announcements;
    late FleetController fleet;
    late SafetyController safety;
    late List<SafetyPolicy> applied;
    late SyncSecretsController syncSecrets;
    late List<bool> syncApplied;
    late DeviceNameController deviceName;
    late List<String> namesApplied;
    late FakeDeviceAuthenticator device;
    late AppLockController appLock;
    late List<bool> appLockSaved;
    late ThresholdController thresholds;
    late SettingsWindowHost host;

    setUp(() async {
      runnerWithWindow();
      appearance = AppearanceController();
      announcements = AnnouncementController();
      fleet = newFleet(const [
        FleetServer(id: 'srv-1', displayName: 'alpha'),
        FleetServer(
          id: 'srv-2',
          displayName: 'bravo',
          monitorEligibility: MonitorEligibility.endpointNotConfirmed,
        ),
      ]);
      applied = [];
      safety = SafetyController(
        initial: const SafetyPolicy(
          servers: {
            'srv-1': ServerSafety(management: true, marks: {'nginx.service'}),
          },
        ),
        apply: applied.add,
        labelOf: (id) => id == 'srv-1' ? 'alpha' : id,
      );
      addTearDown(safety.dispose);
      syncApplied = [];
      syncSecrets = SyncSecretsController(apply: syncApplied.add);
      addTearDown(syncSecrets.dispose);
      namesApplied = [];
      deviceName = DeviceNameController(
        fallback: 'Klabautermann on Linux',
        apply: namesApplied.add,
      );
      addTearDown(deviceName.dispose);
      device = FakeDeviceAuthenticator();
      appLockSaved = [];
      appLock = AppLockController(
        authenticator: device,
        supported: true,
        save: (enabled) async => appLockSaved.add(enabled),
      );
      await appLock.refreshAvailability();
      addTearDown(appLock.dispose);
      thresholds = ThresholdController();
      addTearDown(thresholds.dispose);
      host = newHost(
        appearance,
        announcements,
        fleet.monitorSettings,
        safety,
        syncSecrets,
        deviceName,
        appLock,
        thresholds,
      );
    });

    tearDown(() {
      appearance.dispose();
      announcements.dispose();
    });

    /// Opens Settings on [tab] and starts the window's side, as the runner
    /// does on the first open.
    Future<RemoteSettings> connectWindow(
      WidgetTester tester, [
      SettingsTab tab = SettingsTab.general,
    ]) async {
      final remote = (await tester.runAsync(() async {
        expect(await host.open(tab), isTrue);
        return RemoteSettings.connect(link: _windowLink);
      }))!;
      addTearDown(remote.dispose);
      return remote;
    }

    Future<RemoteSettings> pumpWindow(
      WidgetTester tester, [
      SettingsTab tab = SettingsTab.general,
    ]) async {
      final remote = await connectWindow(tester, tab);
      await tester.pumpWidget(SettingsWindowApp(remote: remote));
      await tester.pumpAndSettle();
      return remote;
    }

    MaterialApp windowApp(WidgetTester tester) => tester.widget<MaterialApp>(
      find.descendant(
        of: find.byType(SettingsWindowApp),
        matching: find.byType(MaterialApp),
      ),
    );

    MaterialApp mainApp(WidgetTester tester) => tester.widget<MaterialApp>(
      find.descendant(
        of: find.byType(KlabautermannApp),
        matching: find.byType(MaterialApp),
      ),
    );

    ThemeModePreference windowSwitch(WidgetTester tester) => tester
        .widget<SegmentedButton<ThemeModePreference>>(
          find.byType(SegmentedButton<ThemeModePreference>),
        )
        .selected
        .single;

    /// The main window over [main], the app's controller, and the window
    /// beside it on the Appearance tab: two engines in the product, one
    /// tree here, joined only by the relayed link.
    Future<RemoteSettings> pumpBothWindows(
      WidgetTester tester,
      AppearanceController main, {
      SettingsTab tab = SettingsTab.appearance,
    }) async {
      tester.view.physicalSize = const Size(2560, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final engine = FakeEngineClient();
      final fleet = FleetController(engine);
      final monitoring = MonitoringController(engine);
      final prompts = PromptController(engine);
      final coverage = CoverageController(firstRunCardDismissed: true);
      final dockerNotice = DockerNoticeController();
      addTearDown(() async {
        fleet.dispose();
        monitoring.dispose();
        prompts.dispose();
        coverage.dispose();
        dockerNotice.dispose();
        await engine.close();
      });
      final remote = await connectWindow(tester, tab);
      await tester.pumpWidget(
        Row(
          textDirection: TextDirection.ltr,
          children: [
            Expanded(
              child: KlabautermannApp(
                fleet: fleet,
                monitoring: monitoring,
                prompts: prompts,
                appearance: main,
                coverage: coverage,
                announcements: announcements,
                dockerNotice: dockerNotice,
              ),
            ),
            Expanded(child: SettingsWindowApp(remote: remote)),
          ],
        ),
      );
      await tester.pumpAndSettle();
      return remote;
    }

    testWidgets('opens on the tab asked for, with the seven tabs', (
      tester,
    ) async {
      await pumpWindow(tester, SettingsTab.appearance);

      expect(controlCalls, ['open']);
      expect(host.connected, isTrue);
      expect(
        tester
            .widget<TabBar>(find.byType(TabBar))
            .tabs
            .map((tab) => (tab as Tab).text),
        [
          'General',
          'Appearance',
          'Sync',
          'Servers',
          'Docker',
          'Safety',
          'Alerts',
        ],
      );
      expect(find.byType(SegmentedButton<ThemeModePreference>), findsOneWidget);
    });

    testWidgets('the General tab\'s about row shows the app\'s version, '
        'which only the link can bring (M16)', (tester) async {
      final remote = await pumpWindow(tester);
      expect(remote.appVersion, _appVersion);

      expect(find.text('Klabautermann $kPreviewLabel'), findsOneWidget);
      await tester.tap(find.text('Version $_appVersion'));
      await tester.pumpAndSettle();

      expect(find.byType(AboutDialog), findsOneWidget);
    });

    testWidgets('an appearance change in the window applies to the main '
        'window through the link', (tester) async {
      final remote = await pumpBothWindows(tester, appearance);
      expect(mainApp(tester).themeMode, ThemeMode.system);

      await tester.tap(find.text('Dark'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();

      expect(appearance.mode, ThemeModePreference.dark);
      expect(mainApp(tester).themeMode, ThemeMode.dark);
      // The snapshot that came back re-themed the window too, and its
      // switch shows the app's mode.
      expect(remote.appearance.value, appearance.value);
      expect(windowApp(tester).themeMode, ThemeMode.dark);
      expect(windowSwitch(tester), ThemeModePreference.dark);
    });

    testWidgets('a preset picked in the window re-themes the main window '
        'through the link (M4 E25)', (tester) async {
      final remote = await pumpBothWindows(tester, appearance);
      final target = klabautermannThemePresets.all
          .firstWhere(
            (p) => p.name != appearance.value.palette.name && p.surface != null,
          )
          .name;

      await tester.tap(find.text(target));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();

      expect(appearance.value.palette.name, target);
      expect(remote.appearance.value, appearance.value);
      expect(
        mainApp(tester).theme?.colorScheme.surface,
        appearance.value.palette.surface,
      );
      expect(
        windowApp(tester).theme?.colorScheme.surface,
        appearance.value.palette.surface,
      );
    });

    testWidgets('a change in the window the app applies but cannot save '
        'stays in both windows and says it was not saved', (tester) async {
      host.dispose();
      // Built off the test's fake clock, as the refusing app below is.
      final unsaved = (await tester.runAsync(() async {
        final unsaved = AppearanceController(
          save: (_) async => throw const FileSystemException('disk full'),
        );
        addTearDown(unsaved.dispose);
        host = newHost(unsaved);
        return unsaved;
      }))!;
      final remote = await pumpBothWindows(tester, unsaved);

      await tester.tap(find.text('Dark'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();

      // The app reported the failed save where it happened.
      expect(tester.takeException(), isA<AppearanceNotSavedException>());
      expect(
        find.text(
          'The theme changed, but it could not be saved, so it will not be '
          'kept after a restart.',
        ),
        findsOneWidget,
      );
      expect(find.text('The theme could not be changed.'), findsNothing);
      expect(unsaved.mode, ThemeModePreference.dark);
      expect(mainApp(tester).themeMode, ThemeMode.dark);
      expect(remote.appearance.value, unsaved.value);
      expect(windowApp(tester).themeMode, ThemeMode.dark);
      expect(windowSwitch(tester), ThemeModePreference.dark);
    });

    testWidgets('the General tab\'s announcement switch changes the app\'s '
        'through the link (A11Y-15, D60)', (tester) async {
      final remote = await pumpBothWindows(
        tester,
        appearance,
        tab: SettingsTab.general,
      );
      bool windowSwitch() => tester
          .widget<SwitchListTile>(
            find.descendant(
              of: find.byType(SettingsWindowApp),
              matching: find.byType(SwitchListTile),
            ),
          )
          .value;
      expect(windowSwitch(), isTrue);

      await tester.tap(
        find.descendant(
          of: find.byType(SettingsWindowApp),
          matching: find.text('Announce threshold changes'),
        ),
      );
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();

      expect(announcements.value, isFalse);
      expect(remote.announcements.value, isFalse);
      expect(windowSwitch(), isFalse);

      // A change in the app reaches the showing window too.
      await tester.runAsync(() async {
        await announcements.setAnnounceThresholdBands(true);
        await pumpEventQueue();
      });
      await tester.pumpAndSettle();
      expect(windowSwitch(), isTrue);
    });

    testWidgets('the Alerts tab\'s usage bands change the app\'s through '
        'the link (OV-11)', (tester) async {
      final remote = await pumpBothWindows(
        tester,
        appearance,
        tab: SettingsTab.alerts,
      );
      Finder inWindow(Finder finder) =>
          find.descendant(of: find.byType(SettingsWindowApp), matching: finder);
      const defaults = 'Careful from 70%, warning from 80%, critical from 90%';
      expect(remote.thresholds, isNotNull);
      expect(inWindow(find.text(defaults)), findsNWidgets(3));

      await tester.tap(inWindow(find.text('Disk')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Careful from'),
        '50',
      );
      await tester.tap(find.text('Save'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();

      const changed = ChartThresholds(careful: 50, warning: 80, critical: 90);
      expect(thresholds.value[ThresholdMetric.disk], changed);
      expect(remote.thresholds!.value[ThresholdMetric.disk], changed);

      // A change in the app reaches the showing window too.
      await tester.runAsync(() async {
        await thresholds.setThresholds(
          ThresholdMetric.cpu,
          const ChartThresholds(careful: 60, warning: 70, critical: 80),
        );
        await pumpEventQueue();
      });
      await tester.pumpAndSettle();
      expect(
        inWindow(
          find.text('Careful from 60%, warning from 70%, critical from 80%'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the General tab\'s device name changes the app\'s through '
        'the link, and blank means the default (M5 plan Q6)', (tester) async {
      final remote = await pumpBothWindows(
        tester,
        appearance,
        tab: SettingsTab.general,
      );
      Finder windowField() => find.descendant(
        of: find.byType(SettingsWindowApp),
        matching: find.byType(TextField),
      );
      expect(remote.deviceName.value, 'Klabautermann on Linux');
      await tester.scrollUntilVisible(
        windowField(),
        100,
        scrollable: find
            .descendant(
              of: find.descendant(
                of: find.byType(SettingsWindowApp),
                matching: find.byType(GeneralTab),
              ),
              matching: find.byType(Scrollable),
            )
            .first,
      );

      await tester.enterText(windowField(), '  Laptop  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(deviceName.value, 'Laptop');
      expect(namesApplied, ['Klabautermann on Linux', 'Laptop']);
      expect(remote.deviceName.value, 'Laptop');

      await tester.enterText(windowField(), ' ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(deviceName.value, 'Klabautermann on Linux');
      expect(
        tester.widget<TextField>(windowField()).controller!.text,
        'Klabautermann on Linux',
      );
    });

    testWidgets('the Sync tab\'s switch changes the app\'s sync passwords '
        'through the link (SYN-02)', (tester) async {
      final remote = await pumpBothWindows(
        tester,
        appearance,
        tab: SettingsTab.sync,
      );
      bool windowSwitch() => tester
          .widget<SwitchListTile>(
            find.descendant(
              of: find.byType(SettingsWindowApp),
              matching: find.byType(SwitchListTile),
            ),
          )
          .value;
      expect(windowSwitch(), isFalse);

      await tester.tap(
        find.descendant(
          of: find.byType(SettingsWindowApp),
          matching: find.text('Sync saved passwords & keys'),
        ),
      );
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();

      expect(syncSecrets.value, isTrue);
      expect(syncApplied, [false, true], reason: 'at once, then the change');
      expect(remote.syncSecrets.value, isTrue);
      expect(windowSwitch(), isTrue);
    });

    testWidgets('the Servers tab\'s switches change the app\'s monitor set '
        'through the link (FL-21)', (tester) async {
      final remote = await pumpWindow(tester, SettingsTab.servers);
      SwitchListTile switchOf(String label) => tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(find.text('0 of 10 servers monitored'), findsOneWidget);
      expect(switchOf('alpha').value, isFalse);
      expect(
        switchOf('bravo').onChanged,
        isNull,
        reason: 'its endpoint is not confirmed',
      );
      expect(
        find.text('Confirm this server\'s endpoint to monitor it.'),
        findsOneWidget,
      );

      await tester.tap(find.text('alpha'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();

      expect(fleet.monitoredServerIds, {'srv-1'});
      expect(remote.monitorSet.value.first.monitored, isTrue);
      expect(switchOf('alpha').value, isTrue);
      expect(find.text('1 of 10 servers monitored'), findsOneWidget);
    });

    testWidgets('the Safety tab changes the app\'s policy through the link, '
        'which applies it to the engine (M4 plan M4)', (tester) async {
      final remote = await pumpWindow(tester, SettingsTab.safety);
      expect(find.text('nginx.service on alpha'), findsOneWidget);

      await tester.tap(find.text('Read-only everywhere'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(safety.value.globalReadOnly, isTrue);
      expect(applied.last.globalReadOnly, isTrue);
      expect(remote.safety.value.globalReadOnly, isTrue);

      await tester.tap(find.text('30 min'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(safety.value.adminExpiry, const Duration(minutes: 30));

      await tester.tap(find.byTooltip('Remove the mark on nginx.service'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(safety.value.servers['srv-1']?.marks, isEmpty);
      expect(
        safety.value.servers['srv-1']?.management,
        isTrue,
        reason: 'removing a mark keeps the rest of the server\'s entry',
      );
      expect(
        find.text('You have not marked anything protected.'),
        findsOneWidget,
      );
    });

    testWidgets('the Safety tab\'s app lock switch asks for device '
        'authentication in the app and says when it did not change '
        '(SAF-20)', (tester) async {
      // Tall enough for the whole Safety tab, the app lock at its end.
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final remote = await pumpWindow(tester, SettingsTab.safety);
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
      expect(device.prompts, 1, reason: 'asked in the app, not the window');
      expect(appLock.enabled, isTrue);
      expect(appLockSaved, [true]);
      expect(remote.appLock.enabled, isTrue);
      expect(lockSwitch().value, isTrue);

      device.accept = false;
      await tester.tap(find.text('Require device authentication'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(appLock.enabled, isTrue);
      expect(lockSwitch().value, isTrue);
      expect(
        find.text(
          'The app lock did not change: authentication failed or was '
          'cancelled.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('while the app is locked the window covers its settings '
        'and the app refuses its calls (SAF-20)', (tester) async {
      host.dispose();
      final lock = _ManualAppLock();
      addTearDown(lock.dispose);
      await tester.runAsync(() async {
        host = newHost(
          appearance,
          announcements,
          fleet.monitorSettings,
          safety,
          syncSecrets,
          deviceName,
          lock,
        );
      });
      final remote = await pumpWindow(tester, SettingsTab.appearance);
      expect(find.text('Dark'), findsOneWidget);

      await tester.runAsync(() async {
        lock.locked = true;
        await pumpEventQueue();
      });
      await tester.pumpAndSettle();
      expect(find.text('Klabautermann is locked'), findsOneWidget);
      expect(find.text('Dark'), findsNothing);

      // A call already on its way when the lock engaged changes nothing.
      await tester.runAsync(() async {
        await expectLater(
          remote.appearance.setMode(ThemeModePreference.dark),
          throwsA(isA<SettingsLinkException>()),
        );
      });
      // The app's error reporter hears of the refusal, as of any other.
      expect(tester.takeException(), isA<AppLockedException>());
      expect(appearance.value.mode, ThemeModePreference.system);

      await tester.runAsync(() async {
        lock.locked = false;
        await pumpEventQueue();
      });
      await tester.pumpAndSettle();
      expect(find.text('Klabautermann is locked'), findsNothing);
      expect(find.text('Dark'), findsOneWidget);
    });

    testWidgets('a window opened while the app is locked shows the notice '
        'from its first frame (SAF-20)', (tester) async {
      host.dispose();
      final lock = _ManualAppLock()..locked = true;
      addTearDown(lock.dispose);
      await tester.runAsync(() async {
        host = newHost(
          appearance,
          announcements,
          fleet.monitorSettings,
          safety,
          syncSecrets,
          deviceName,
          lock,
        );
      });
      await pumpWindow(tester, SettingsTab.appearance);

      expect(find.text('Klabautermann is locked'), findsOneWidget);
      expect(find.text('Dark'), findsNothing);
    });

    testWidgets('a theme change in the app re-themes the showing window', (
      tester,
    ) async {
      await pumpWindow(tester);
      expect(windowApp(tester).themeMode, ThemeMode.system);

      await tester.runAsync(() async {
        await appearance.setMode(ThemeModePreference.light);
        await pumpEventQueue();
      });
      await tester.pumpAndSettle();

      expect(windowApp(tester).themeMode, ThemeMode.light);
    });

    testWidgets('opening Settings again switches the showing window to the '
        'tab', (tester) async {
      await pumpWindow(tester, SettingsTab.appearance);

      await tester.runAsync(() async {
        expect(await host.open(SettingsTab.general), isTrue);
        await pumpEventQueue();
      });
      await tester.pumpAndSettle();

      expect(controlCalls, ['open', 'open']);
      expect(find.byType(SegmentedButton<ThemeModePreference>), findsNothing);
    });

    testWidgets('a change the app refuses leaves the switch and says so', (
      tester,
    ) async {
      host.dispose();
      // Built off the test's fake clock, as setUp builds the others: a
      // channel handler runs in the zone it was set in, and the link's
      // round trips run on the real one.
      await tester.runAsync(() async {
        host = newHost(_RefusingAppearance());
      });
      await pumpWindow(tester, SettingsTab.appearance);

      await tester.tap(find.text('Dark'));
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();

      // The app reported the failure where it happened.
      expect(tester.takeException(), isA<StateError>());
      expect(find.text('The theme could not be changed.'), findsOneWidget);
      expect(find.textContaining('could not be saved'), findsNothing);
      expect(windowSwitch(tester), ThemeModePreference.system);
    });

    testWidgets('a window that loses the app says so', (tester) async {
      final remote = await pumpWindow(tester, SettingsTab.appearance);

      messenger.setMockMessageHandler(_windowLink.name, (_) async => null);
      await tester.runAsync(remote.requestAppExit);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Settings cannot reach Klabautermann. Close this window and open '
          'Settings again.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a window started without the app says so', (tester) async {
      await tester.pumpWidget(const SettingsWindowApp(remote: null));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Settings cannot reach Klabautermann. Close this window and open '
          'Settings again.',
        ),
        findsOneWidget,
      );
    });
  });

  group('the link', () {
    test('no product method takes a name the engine reserves', () {
      final reserved = {
        for (final method in GhostSettingsLinkMethod.values) method.name,
      };
      for (final method in SettingsLinkMethod.values) {
        expect(reserved, isNot(contains(method.name)), reason: '$method');
      }
    });

    test('the appearance crosses whole, every preset in every mode', () {
      for (final palette in klabautermannThemePresets.all) {
        for (final mode in ThemeModePreference.values) {
          final appearance = AppAppearance(palette: palette, mode: mode);
          expect(
            decodeAppearance(encodeAppearance(appearance)),
            appearance,
            reason: '${palette.name} $mode',
          );
        }
      }
    });

    test('a change the app applied but did not save crosses as itself; any '
        'other failure as what it printed', () {
      Exception roundTrip(Object error) =>
          decodeLinkError(encodeLinkError(error));

      expect(
        roundTrip(const AppearanceNotSavedException('disk full')),
        isA<AppearanceNotSavedException>().having(
          (error) => error.message,
          'message',
          'disk full',
        ),
      );
      expect(
        roundTrip(const AnnouncementNotSavedException('disk full')),
        isA<AnnouncementNotSavedException>().having(
          (error) => error.message,
          'message',
          'disk full',
        ),
      );
      expect(
        roundTrip(const ThresholdsNotSavedException('disk full')),
        isA<ThresholdsNotSavedException>().having(
          (error) => error.message,
          'message',
          'disk full',
        ),
      );
      expect(
        roundTrip(const DeviceNameNotSavedException('disk full')),
        isA<DeviceNameNotSavedException>().having(
          (error) => error.message,
          'message',
          'disk full',
        ),
      );
      expect(
        roundTrip(const SyncSecretsNotSavedException('disk full')),
        isA<SyncSecretsNotSavedException>().having(
          (error) => error.message,
          'message',
          'disk full',
        ),
      );
      expect(
        roundTrip(const MonitorSetFullException()),
        isA<MonitorSetFullException>(),
      );
      expect(
        roundTrip(const MonitorSetNotSavedException('disk full')),
        isA<MonitorSetNotSavedException>().having(
          (error) => error.message,
          'message',
          'disk full',
        ),
      );
      expect(
        roundTrip(StateError('read-only appearance')),
        isA<SettingsLinkException>().having(
          (error) => error.message,
          'message',
          contains('read-only appearance'),
        ),
      );
      // A code this build does not know reads as a plain failure.
      expect(
        decodeLinkError(PlatformException(code: 'settings-failed')),
        isA<SettingsLinkException>(),
      );
    });

    test('the monitor set\'s candidates cross whole, every eligibility', () {
      final candidates = [
        for (final (index, eligibility) in MonitorEligibility.values.indexed)
          MonitorCandidate(
            serverId: 'srv-$index',
            label: 'Server $index',
            eligibility: eligibility,
            monitored: index.isEven,
          ),
      ];

      expect(
        decodeMonitorCandidates(encodeMonitorCandidates(candidates)),
        candidates,
      );
    });

    test('uses the channel names 04 §12.3 fixes', () {
      expect(
        settingsWindowControlChannel.name,
        'klabautermann/settings_window',
      );
      expect(settingsWindowLinkChannel.name, 'klabautermann/settings_link');
    });
  });
}
