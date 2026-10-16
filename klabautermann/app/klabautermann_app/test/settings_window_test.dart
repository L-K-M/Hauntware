import 'dart:async';
import 'dart:io' show FileSystemException;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart' show GhostSettingsLinkMethod;
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/app.dart';
import 'package:klabautermann_app/controllers/announcement_controller.dart';
import 'package:klabautermann_app/controllers/appearance_controller.dart';
import 'package:klabautermann_app/controllers/coverage_controller.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/services/settings_window/remote_settings.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_host.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_link.dart';
import 'package:klabautermann_app/settings_window_app.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/settings_page.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';

// One engine in a test, so the two ends of the link get a channel each and a
// relay between them stands in for the runners' byte-for-byte forwarding.
const _control = MethodChannel('test/settings_window');
const _appLink = MethodChannel('test/settings_link/app');
const _windowLink = MethodChannel('test/settings_link/window');

/// An app whose appearance refuses every change.
final class _RefusingAppearance extends ChangeNotifier
    implements AppearanceSettings {
  @override
  AppAppearance get value =>
      AppAppearance(palette: klabautermannThemePresets.initial);

  @override
  Future<void> setMode(ThemeModePreference mode) async =>
      throw StateError('read-only appearance');
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

  SettingsWindowHost newHost(
    AppearanceSettings appearance, [
    AnnouncementSettings? announcements,
  ]) {
    final host = SettingsWindowHost(
      appearance: appearance,
      announcements: announcements ?? AnnouncementController(),
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
    late SettingsWindowHost host;

    setUp(() {
      runnerWithWindow();
      appearance = AppearanceController();
      announcements = AnnouncementController();
      host = newHost(appearance, announcements);
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
      final coverage = CoverageController(firstRunCardDismissed: true);
      addTearDown(() async {
        fleet.dispose();
        monitoring.dispose();
        coverage.dispose();
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
                appearance: main,
                coverage: coverage,
                announcements: announcements,
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

    test('uses the channel names 04 §12.3 fixes', () {
      expect(
        settingsWindowControlChannel.name,
        'klabautermann/settings_window',
      );
      expect(settingsWindowLinkChannel.name, 'klabautermann/settings_link');
    });
  });
}
