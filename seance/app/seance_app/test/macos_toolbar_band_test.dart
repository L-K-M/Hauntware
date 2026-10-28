import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/adaptive_shell.dart';
import 'package:seance_app/ui/header_toolbar.dart';
import 'package:seance_app/ui/macos_toolbar_band.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_app/ui/sidebar_panel.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// On macOS the window's titlebar is part of the app, as in Poltergeist:
/// the wide layout draws its header under the unified toolbar band, with
/// the traffic lights over the rail, while everything else the navigator
/// shows keeps its controls below the band, where AppKit does not take the
/// clicks for window drag.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    state = null;
    await services?.probe.dispose();
    services = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    directory = null;
  });

  final server = ServerConfig(
    id: 'box',
    label: 'box',
    host: 'box.example.com',
    port: 2222,
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  /// Enough servers beside [server] for the rail to show its filter field.
  final others = [
    for (var i = 2; i <= ServerListPane.filterThreshold; i++)
      ServerConfig(
        id: 'box$i',
        label: 'box$i',
        host: 'box$i.example.com',
        username: 'deploy',
        createdAt: 1,
        updatedAt: 1,
      ),
  ];

  /// The shell over one server with an open (still connecting) tab, in a
  /// MaterialApp composed like the app's: the band's scope and
  /// reservation above the navigator. [more] servers join it in the rail.
  Future<GlobalKey<NavigatorState>> pumpShell(
    WidgetTester tester, {
    required TargetPlatform platform,
    ValueListenable<bool>? band,
    Size size = const Size(1280, 800),
    List<ServerConfig> more = const [],
  }) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-band-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _pathChannel,
            (call) async => directory!.path,
          );
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      await state!.saveServer(server);
      for (final other in more) {
        await state!.saveServer(other);
      }
    });
    final session = TerminalSession(
      id: 'tab',
      serverId: 'box',
      config: server,
      engine: XtermTerminalEngine(),
    );
    state!.tabs.add(session);
    state!.focusTab(session.id);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: SeanceTheme.light(platform: platform),
        builder: (context, child) => AppScope(
          state: state!,
          child: withMacosToolbarBand(band, child: child!),
        ),
        home: const AdaptiveShell(),
      ),
    );
    await tester.pump();
    return navigator;
  }

  /// Unmounts the shell and lets the passthrough views' debounce timers
  /// run out, so none is left pending when the test ends.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> pushRoute(
    WidgetTester tester,
    GlobalKey<NavigatorState> navigator,
  ) async {
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            leading: const BackButton(),
            title: const Text('Pushed'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Finder inStrip(Finder finder) =>
      find.descendant(of: find.byType(TerminalTabStrip), matching: finder);

  testWidgets('macOS: the header sits in the band, the rail below it', (
    tester,
  ) async {
    final band = ValueNotifier(true);
    addTearDown(band.dispose);
    await pumpShell(tester, platform: TargetPlatform.macOS, band: band);

    final header = tester.getRect(find.byType(HeaderToolbar));
    expect(header.top, 0);
    expect(header.height, macosToolbarBandHeight);
    // It spans the terminal and the utility panel, right of the rail.
    final rail = tester.getRect(find.byKey(AdaptivePaneLayout.listPaneKey));
    expect(header.left, greaterThan(rail.right));
    expect(header.right, 1280);

    // The window's title: the server and where it connects.
    expect(find.byKey(HeaderToolbar.titleKey), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(HeaderToolbar.subtitleKey)).data,
      'deploy@box.example.com:2222',
    );

    // The traffic lights sit over the rail's top band; its content and
    // the tab strip start level, below the header and its rule.
    expect(rail.top, 0);
    final strip = tester.getRect(find.byType(TerminalTabStrip));
    expect(strip.top, macosToolbarBandHeight + 1);
    expect(tester.getRect(find.byType(ServerListPane)).top, strip.top);

    // The layout took the band back: the side panel's safe area does not
    // push its tabs a band further down.
    final utility = tester.getRect(
      find.byKey(AdaptivePaneLayout.utilityPaneKey),
    );
    expect(utility.top, header.bottom + 1);
    expect(
      tester.getRect(find.byKey(SidebarPanel.tabStripKey)).top,
      utility.top,
    );

    // Generate command moved up into the header; the strip keeps "+".
    expect(find.byKey(HeaderToolbar.generateCommandKey), findsOneWidget);
    expect(inStrip(find.byTooltip('Generate command')), findsNothing);
    expect(inStrip(find.byTooltip('New tab')), findsOneWidget);
    await unmount(tester);
  });

  // The rail, the terminal and the side panel meet in one band under the
  // header: the filter field is as tall as the tabs and level with them,
  // and the side panel's rule continues the strip's across the seam.
  for (final (platform, unified) in [
    (TargetPlatform.macOS, true),
    (TargetPlatform.linux, false),
  ]) {
    testWidgets('${platform.name}: the filter field, the tabs and the side '
        "panel's rule line up", (tester) async {
      final band = ValueNotifier(true);
      addTearDown(band.dispose);
      await pumpShell(
        tester,
        platform: platform,
        band: unified ? band : null,
        more: others,
      );
      expect(find.byType(HeaderToolbar), findsOneWidget);

      final strip = tester.getRect(find.byType(TerminalTabStrip));
      expect(strip.height, TerminalTabStrip.height);
      final field = tester.getRect(
        find.byKey(const ValueKey('servers.filter.field')),
      );
      expect(field.top, strip.top);
      expect(field.bottom, strip.bottom);
      expect(
        tester.getRect(find.byKey(SidebarPanel.tabStripKey)),
        Rect.fromLTRB(
          tester.getRect(find.byKey(AdaptivePaneLayout.utilityPaneKey)).left,
          strip.top,
          1280,
          strip.bottom,
        ),
      );
      await unmount(tester);
    });
  }

  testWidgets('macOS: only the controls take clicks through the band', (
    tester,
  ) async {
    final band = ValueNotifier(true);
    addTearDown(band.dispose);
    await pumpShell(tester, platform: TargetPlatform.macOS, band: band);

    Finder passthroughAbove(Finder finder) => find.ancestor(
      of: finder,
      matching: find.byType(MacosToolbarPassthrough),
    );
    expect(
      passthroughAbove(find.byKey(HeaderToolbar.generateCommandKey)),
      findsOneWidget,
    );
    expect(
      passthroughAbove(find.byKey(HeaderToolbar.inspectorToggleKey)),
      findsOneWidget,
    );
    expect(
      passthroughAbove(find.byKey(SidebarBand.sidebarToggleKey)),
      findsOneWidget,
    );
    // The full-height rail handle reaches into the band too.
    expect(
      passthroughAbove(find.byKey(AdaptivePaneLayout.listResizeHandleKey)),
      findsOneWidget,
    );
    // The title drags and zooms the window, as a titlebar does.
    expect(passthroughAbove(find.byKey(HeaderToolbar.titleKey)), findsNothing);
    await unmount(tester);
  });

  testWidgets('macOS: the dividers still resize from the keyboard', (
    tester,
  ) async {
    final band = ValueNotifier(true);
    addTearDown(band.dispose);
    await pumpShell(tester, platform: TargetPlatform.macOS, band: band);
    expect(find.byType(HeaderToolbar), findsOneWidget);

    Future<double> stepRight(Key handleKey, Key paneKey) async {
      final handle = find.byKey(handleKey);
      Focus.of(
        tester.element(
          find.descendant(of: handle, matching: find.byType(GestureDetector)),
        ),
      ).requestFocus();
      await tester.pump();
      final before = tester.getSize(find.byKey(paneKey)).width;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      return tester.getSize(find.byKey(paneKey)).width - before;
    }

    // The rail's handle sits inside the band's passthrough, and the
    // utility handle below the header; both keep their keyboard steps.
    expect(
      await stepRight(
        AdaptivePaneLayout.listResizeHandleKey,
        AdaptivePaneLayout.listPaneKey,
      ),
      16,
    );
    expect(
      await stepRight(
        AdaptivePaneLayout.utilityResizeHandleKey,
        AdaptivePaneLayout.utilityPaneKey,
      ),
      -16,
    );
    await unmount(tester);
  });

  testWidgets('macOS: a pushed route keeps its controls below the band', (
    tester,
  ) async {
    final band = ValueNotifier(true);
    addTearDown(band.dispose);
    final navigator = await pumpShell(
      tester,
      platform: TargetPlatform.macOS,
      band: band,
    );
    await pushRoute(tester, navigator);

    expect(
      tester.getRect(find.byType(BackButton)).top,
      greaterThanOrEqualTo(macosToolbarBandHeight),
    );
    expect(
      tester.getRect(find.text('Pushed')).top,
      greaterThanOrEqualTo(macosToolbarBandHeight),
    );
    await unmount(tester);
  });

  testWidgets('macOS full screen: no band to keep clear of', (tester) async {
    final band = ValueNotifier(true);
    addTearDown(band.dispose);
    final navigator = await pumpShell(
      tester,
      platform: TargetPlatform.macOS,
      band: band,
    );
    await pushRoute(tester, navigator);

    band.value = false;
    await tester.pump();
    expect(
      tester.getRect(find.text('Pushed')).top,
      lessThan(macosToolbarBandHeight),
    );
    // The route survived the switch rather than being rebuilt away.
    expect(find.text('Pushed'), findsOneWidget);

    navigator.currentState!.pop();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The header stays at the top of the window.
    expect(tester.getRect(find.byType(HeaderToolbar)).top, 0);

    band.value = true;
    await tester.pump();
    expect(tester.getRect(find.byType(HeaderToolbar)).top, 0);
    await unmount(tester);
  });

  testWidgets('macOS narrow window: the app bars sit below the band', (
    tester,
  ) async {
    final band = ValueNotifier(true);
    addTearDown(band.dispose);
    await pumpShell(
      tester,
      platform: TargetPlatform.macOS,
      band: band,
      size: const Size(700, 800),
    );

    expect(find.byType(HeaderToolbar), findsNothing);
    final appBar = find.descendant(
      of: find.byType(ServerListPane),
      matching: find.byType(AppBar),
    );
    expect(
      tester
          .getRect(find.descendant(of: appBar, matching: find.text('Séance')))
          .top,
      greaterThanOrEqualTo(macosToolbarBandHeight),
    );
    await unmount(tester);
  });

  testWidgets('macOS: the sidebar button sits after the traffic lights, '
      'over the list or leading the header', (tester) async {
    final band = ValueNotifier(true);
    addTearDown(band.dispose);
    await pumpShell(tester, platform: TargetPlatform.macOS, band: band);

    final rail = tester.getRect(find.byKey(AdaptivePaneLayout.listPaneKey));
    final overList = tester.getRect(find.byKey(SidebarBand.sidebarToggleKey));
    expect(overList.left, greaterThanOrEqualTo(76));
    expect(overList.right, lessThan(rail.right));
    expect(overList.center.dy, macosToolbarBandHeight / 2);

    await tester.tap(find.byKey(SidebarBand.sidebarToggleKey));
    await tester.pump();
    expect(state!.sidebarVisible, isFalse);
    expect(find.byKey(AdaptivePaneLayout.listPaneKey), findsNothing);
    final leading = tester.getRect(find.byKey(HeaderToolbar.sidebarToggleKey));
    expect(leading.left, greaterThanOrEqualTo(76));
    expect(
      tester.getRect(find.byKey(HeaderToolbar.titleKey)).left,
      greaterThan(leading.right),
    );

    // Full screen has no traffic lights to keep clear of.
    band.value = false;
    await tester.pump();
    expect(
      tester.getRect(find.byKey(HeaderToolbar.sidebarToggleKey)).left,
      lessThan(76),
    );
    await unmount(tester);
  });

  testWidgets('macOS without the titlebar: the header, and no passthrough', (
    tester,
  ) async {
    await pumpShell(tester, platform: TargetPlatform.macOS);

    expect(tester.getRect(find.byType(HeaderToolbar)).top, 0);
    expect(find.byType(MacosToolbarPassthrough), findsNothing);
    expect(
      tester.getRect(find.byKey(SidebarBand.sidebarToggleKey)).left,
      lessThan(76),
    );
    expect(find.byKey(HeaderToolbar.generateCommandKey), findsOneWidget);
    expect(inStrip(find.byTooltip('Generate command')), findsNothing);
    await unmount(tester);
  });

  testWidgets('Linux: the same header under its native titlebar', (
    tester,
  ) async {
    final band = ValueNotifier(true);
    addTearDown(band.dispose);
    final navigator = await pumpShell(
      tester,
      platform: TargetPlatform.linux,
      band: band,
    );

    final header = tester.getRect(find.byType(HeaderToolbar));
    expect(header.top, 0);
    expect(find.byType(MacosToolbarPassthrough), findsNothing);
    expect(find.byKey(HeaderToolbar.generateCommandKey), findsOneWidget);
    expect(find.byKey(HeaderToolbar.inspectorToggleKey), findsOneWidget);
    expect(inStrip(find.byTooltip('Generate command')), findsNothing);
    // No traffic lights: the sidebar button leads the list's band.
    expect(
      tester.getRect(find.byKey(SidebarBand.sidebarToggleKey)).left,
      lessThan(76),
    );
    expect(
      tester.getRect(find.byType(TerminalTabStrip)).top,
      header.bottom + 1,
    );
    await pushRoute(tester, navigator);
    expect(
      tester.getRect(find.text('Pushed')).top,
      lessThan(macosToolbarBandHeight),
    );
    await unmount(tester);
  });
}
