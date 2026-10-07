import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/adaptive_shell.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The terminal reports its focus to the macOS menu; mocked so the tests
/// also run on a Mac.
const _menuChannel = MethodChannel('seance/menu');

/// The screen's insets around the terminal pane on a phone or tablet: a
/// status bar above, a home indicator or gesture bar below, a notch or a
/// navigation bar at a side. The tab strip is always above the terminal and
/// the status bar below it, so the top and bottom insets are never the
/// terminal's to keep clear of; the sides are, where it spans the screen.
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
      ..setMockMethodCallHandler(_pathChannel, null)
      ..setMockMethodCallHandler(_menuChannel, null);
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
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  /// [home] over one server with a connected tab, on a
  /// screen of [size] with [insets], in logical pixels.
  Future<void> pumpScreen(
    WidgetTester tester, {
    required Widget home,
    required Size size,
    required EdgeInsets insets,
  }) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-insets-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(_pathChannel, (_) async => directory!.path)
        ..setMockMethodCallHandler(_menuChannel, (_) async => null);
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      await state!.saveServer(server);
    });
    final engine = XtermTerminalEngine();
    final session =
        TerminalSession(
            id: 'tab',
            serverId: 'box',
            config: server,
            engine: engine,
          )
          ..session = _OpenSshSession(engine)
          ..connecting = false;
    state!.tabs.add(session);
    state!.focusTab(session.id);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final padding = FakeViewPadding(
      left: insets.left,
      top: insets.top,
      right: insets.right,
      bottom: insets.bottom,
    );
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: TargetPlatform.iOS),
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: home,
      ),
    );
    await tester.pump();
  }

  /// The terminal view's state: its renderer and the grid it laid out.
  TerminalViewState terminalView(WidgetTester tester) =>
      tester.state<TerminalViewState>(find.byType(TerminalView));

  /// The grid fills the terminal's height: no rows are held back for an
  /// inset at an edge the terminal does not have. Checked at the source as
  /// well, since a small inset can fit in the last row's slack.
  void expectFullHeight(WidgetTester tester) {
    final insets = MediaQuery.paddingOf(
      tester.element(find.byType(TerminalView)),
    );
    expect(
      (insets.top, insets.bottom),
      (0.0, 0.0),
      reason: 'insets reaching it',
    );
    final view = terminalView(tester);
    final render = view.renderTerminal;
    expect(render.getOffset(const CellOffset(0, 0)).dy, 0, reason: 'top');
    expect(
      view.widget.terminal.viewHeight,
      render.size.height ~/ render.lineHeight,
      reason: 'bottom',
    );
  }

  testWidgets('tablet: the tabs clear the status bar, the grid fills', (
    tester,
  ) async {
    const insets = EdgeInsets.only(top: 24, bottom: 20);
    await pumpScreen(
      tester,
      home: const AdaptiveShell(),
      size: const Size(1180, 820),
      insets: insets,
    );

    expect(tester.getRect(find.byType(TerminalTabStrip)).top, insets.top);
    expectFullHeight(tester);
  });

  testWidgets('phone: the grid fills down to the status bar', (tester) async {
    await pumpScreen(
      tester,
      home: TerminalPane(onBack: () {}),
      size: const Size(390, 844),
      insets: const EdgeInsets.only(top: 47, bottom: 34),
    );

    // The app bar took the status bar's inset; the tabs follow it directly.
    expect(
      tester.getRect(find.byType(TerminalTabStrip)).top,
      tester.getRect(find.byType(AppBar)).bottom,
    );
    expectFullHeight(tester);
  });

  testWidgets('phone in landscape: the sides are still kept clear', (
    tester,
  ) async {
    const insets = EdgeInsets.only(left: 47, right: 47, bottom: 21);
    await pumpScreen(
      tester,
      home: TerminalPane(onBack: () {}),
      size: const Size(844, 390),
      insets: insets,
    );

    expectFullHeight(tester);
    final render = terminalView(tester).renderTerminal;
    expect(render.getOffset(const CellOffset(0, 0)).dx, insets.left);
  });
}

/// Just enough of a live SSH session for the terminal to count as connected.
class _OpenSshSession implements SshSession {
  _OpenSshSession(this.engine);

  @override
  final TerminalEngine engine;

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => engine.dispose();

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
