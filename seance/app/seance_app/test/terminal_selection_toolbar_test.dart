import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
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
import 'package:seance_app/ui/app_menus.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The touch selection toolbar: touch has no secondary click, so a
/// long-press (or double-tap) selection needs its own Copy/Paste/Select all,
/// as on Android and iOS text fields. Without it a touch selection could
/// not be copied at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  /// The system clipboard, as the platform channel sees it.
  String? clipboard;

  /// Everything the terminal sent its shell, in order.
  final shellInput = <String>[];

  tearDown(() async {
    state?.dispose();
    state = null;
    await services?.probe.dispose();
    services = null;
    clipboard = null;
    shellInput.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_pathChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    directory = null;
  });

  ServerConfig server(String id) => ServerConfig(
    id: id,
    label: id,
    host: '$id.example.com',
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  Future<void> settle(WidgetTester tester) async {
    // A live terminal animates indefinitely: pump fixed frames.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// One connected terminal on an Android-themed shell, showing two lines.
  Future<void> pumpTerminal(WidgetTester tester) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-toolbar-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _pathChannel,
            (call) async => directory!.path,
          );
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      await state!.saveServer(server('box'));
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String?;
            case 'Clipboard.getData':
              return clipboard == null ? null : {'text': clipboard};
          }
          return null;
        });
    final engine = XtermTerminalEngine();
    engine.userInput.listen((bytes) => shellInput.add(utf8.decode(bytes)));
    state!
      ..tabs.add(
        TerminalSession(
            id: 'tab',
            serverId: 'box',
            config: server('box'),
            engine: engine,
          )
          ..session = _OpenSshSession(engine)
          ..connecting = false,
      )
      ..activeTabId = 'tab';

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: TargetPlatform.android),
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: const AppMenus(child: AdaptiveShell()),
      ),
    );
    await settle(tester);
    engine.terminal.write('alpha bravo\r\ncharlie delta\r\n');
    await settle(tester);
  }

  /// Global position of the centre of cell ([col], [row]).
  Offset cell(WidgetTester tester, int col, int row) {
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    final size = render.cellSize;
    return render.localToGlobal(
      render.getOffset(CellOffset(col, row)) +
          Offset(size.width / 2, size.height / 2),
    );
  }

  TerminalController controller() => state!.activeSession!.controller!;

  Finder copyButton() => find.text('Copy');

  testWidgets('a long-press selection offers Copy, Paste and Select all; '
      'Copy takes the selection and closes the toolbar', (tester) async {
    await pumpTerminal(tester);
    expect(copyButton(), findsNothing);

    await tester.longPressAt(cell(tester, 8, 0));
    await settle(tester);

    expect(controller().selection, isNotNull);
    expect(copyButton(), findsOneWidget);
    expect(find.text('Paste'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);

    await tester.tap(copyButton());
    await settle(tester);

    expect(clipboard, 'bravo');
    expect(copyButton(), findsNothing);
  });

  testWidgets('the toolbar opens above the selection, or below it at the '
      'top of the view', (tester) async {
    await pumpTerminal(tester);
    final terminal = state!.activeSession!.engine.terminal;
    terminal.write('\r\n' * 10 + 'echo target\r\n');
    await settle(tester);

    await tester.longPressAt(cell(tester, 6, 12));
    await settle(tester);
    expect(tester.getCenter(copyButton()).dy, lessThan(cell(tester, 6, 12).dy));

    await tester.tapAt(cell(tester, 20, 14));
    await settle(tester);
    await tester.longPressAt(cell(tester, 2, 0));
    await settle(tester);
    expect(
      tester.getCenter(copyButton()).dy,
      greaterThan(cell(tester, 2, 0).dy),
    );
  });

  testWidgets('a touch double-tap selection offers the toolbar too', (
    tester,
  ) async {
    await pumpTerminal(tester);

    final position = cell(tester, 2, 1);
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(position);
    await settle(tester);

    expect(controller().selection, isNotNull);
    expect(copyButton(), findsOneWidget);
  });

  testWidgets('Paste sends the clipboard to the shell and closes the toolbar', (
    tester,
  ) async {
    await pumpTerminal(tester);
    clipboard = 'uptime';

    await tester.longPressAt(cell(tester, 2, 0));
    await settle(tester);
    shellInput.clear();
    await tester.tap(find.text('Paste'));
    await settle(tester);

    expect(shellInput.join(), contains('uptime'));
    expect(copyButton(), findsNothing);
  });

  testWidgets('Select all selects everything and keeps the toolbar', (
    tester,
  ) async {
    await pumpTerminal(tester);

    await tester.longPressAt(cell(tester, 2, 0));
    await settle(tester);
    await tester.tap(find.text('Select all'));
    await settle(tester);

    final terminal = state!.activeSession!.engine.terminal;
    final selected = terminal.buffer.getText(controller().selection);
    expect(selected, contains('alpha bravo'));
    expect(selected, contains('charlie delta'));
    expect(copyButton(), findsOneWidget);
  });

  testWidgets('a tap clears the selection and the toolbar with it', (
    tester,
  ) async {
    await pumpTerminal(tester);

    await tester.longPressAt(cell(tester, 2, 0));
    await settle(tester);
    expect(copyButton(), findsOneWidget);

    await tester.tapAt(cell(tester, 20, 4));
    await settle(tester);

    expect(controller().selection, isNull);
    expect(copyButton(), findsNothing);
  });

  testWidgets('focus leaving the terminal closes the toolbar', (tester) async {
    await pumpTerminal(tester);

    await tester.longPressAt(cell(tester, 2, 0));
    await settle(tester);
    expect(copyButton(), findsOneWidget);
    final focus = FocusManager.instance.primaryFocus!;
    expect(
      focus.context?.findAncestorWidgetOfExactType<TerminalView>(),
      isNotNull,
    );

    focus.unfocus();
    await settle(tester);

    expect(controller().selection, isNotNull);
    expect(copyButton(), findsNothing);
  });

  testWidgets('a mouse selection keeps to the right-click menu', (
    tester,
  ) async {
    await pumpTerminal(tester);

    final from = cell(tester, 0, 0);
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(cell(tester, 8, 0));
    await gesture.up();
    await settle(tester);

    expect(controller().selection, isNotNull);
    expect(copyButton(), findsNothing);
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
