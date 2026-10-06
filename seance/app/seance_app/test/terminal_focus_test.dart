import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/adaptive_shell.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _menuChannel = MethodChannel('seance/menu');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  late AppState state;
  final pending = <_PendingConnection>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-terminal-focus-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      _pathChannel,
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(_menuChannel, (_) async => null);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(
      services,
      openSshSession:
          (
            manager, {
            required config,
            required credentials,
            required engine,
            log,
          }) async {
            final connection = _PendingConnection(engine);
            pending.add(connection);
            await connection.ready.future;
            return connection.session;
          },
    );
    for (final id in ['alpha', 'beta']) {
      await state.saveServer(
        ServerConfig(
          id: id,
          label: id,
          host: '$id.example.com',
          username: 'deploy',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
    }
  });

  tearDown(() async {
    state.dispose();
    await services.probe.dispose();
    pending.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_pathChannel, null);
    messenger.setMockMethodCallHandler(_menuChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Handles can outlive disposal briefly on Windows; the OS reaps temp dirs.
    }
  });

  Future<void> pumpFrames(WidgetTester tester) async {
    // Connecting placeholders and terminal cursors animate indefinitely.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: TargetPlatform.linux),
        builder: (_, child) => AppScope(state: state, child: child!),
        home: const AdaptiveShell(),
      ),
    );
    await pumpFrames(tester);
  }

  Future<void> open(WidgetTester tester, String label) async {
    await tester.runAsync(() => tester.tap(find.text(label).first));
    await pumpFrames(tester);
  }

  Future<void> complete(WidgetTester tester, int index) async {
    await tester.runAsync(() async {
      pending[index].ready.complete();
      await Future<void>.delayed(Duration.zero);
    });
    await pumpFrames(tester);
  }

  FocusNode terminalFocus(WidgetTester tester) => tester
      .widget<TerminalView>(
        find.byWidgetPredicate(
          (widget) =>
              widget is TerminalView &&
              identical(widget.terminal, state.activeSession!.engine.terminal),
        ),
      )
      .focusNode!;

  testWidgets('connecting from the sidebar focuses the new terminal', (
    tester,
  ) async {
    await mount(tester);
    await open(tester, 'alpha');
    expect(state.activeSession!.status, TerminalStatus.connecting);
    final sidebarFocus = FocusManager.instance.primaryFocus;
    expect(sidebarFocus, isNotNull);
    expect(find.byType(TerminalView), findsNothing);

    await complete(tester, 0);

    expect(state.activeSession!.status, TerminalStatus.connected);
    expect(terminalFocus(tester).hasPrimaryFocus, isTrue);
    expect(sidebarFocus!.hasFocus, isFalse);
    final input = <int>[];
    final subscription = state.activeSession!.engine.userInput.listen(
      input.addAll,
    );
    addTearDown(subscription.cancel);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(String.fromCharCodes(input), '\r');
  });

  testWidgets('new tabs and reconnects focus their new terminal', (
    tester,
  ) async {
    await mount(tester);
    await open(tester, 'alpha');
    await complete(tester, 0);
    final firstId = state.activeTabId;

    await tester.runAsync(() => tester.tap(find.byTooltip('New tab')));
    await pumpFrames(tester);
    expect(state.activeTabId, isNot(firstId));
    await complete(tester, 1);
    expect(terminalFocus(tester).hasPrimaryFocus, isTrue);

    final secondId = state.activeTabId!;
    await tester.runAsync(() => state.disconnect(secondId));
    await pumpFrames(tester);
    await open(tester, 'alpha');
    expect(state.activeTabId, isNot(secondId));
    await complete(tester, 2);
    expect(terminalFocus(tester).hasPrimaryFocus, isTrue);
  });

  testWidgets(
    'background completion preserves focus; selecting it focuses it',
    (tester) async {
      await mount(tester);
      await open(tester, 'alpha');
      await open(tester, 'beta');
      await complete(tester, 1);
      final betaFocus = terminalFocus(tester);
      expect(betaFocus.hasPrimaryFocus, isTrue);

      await complete(tester, 0);
      expect(betaFocus.hasPrimaryFocus, isTrue);

      await open(tester, 'alpha');
      expect(state.activeServerId, 'alpha');
      expect(terminalFocus(tester).hasPrimaryFocus, isTrue);
      expect(betaFocus.hasFocus, isFalse);
    },
  );

  testWidgets(
    'restored shell output survives the editor tab changing terminal rows',
    (tester) async {
      await mount(tester);
      await open(tester, 'alpha');
      await complete(tester, 0);
      final session = state.activeSession!;
      final terminal = session.engine.terminal;
      final terminalRows = terminal.viewHeight;
      final checkout = services.managedRemoteFiles.checkoutFile('motd');
      await tester.runAsync(() async {
        await checkout.parent.create(recursive: true);
        await checkout.writeAsString('Editable file\n');
      });
      final editor = EditorTab(
        id: 'motd-editor',
        serverId: session.serverId,
        config: session.config!,
        remotePath: '/etc/motd',
        localPath: 'motd',
        ownerEditSessionId: session.editSessionId,
      );
      state.tabs.add(editor);
      state.focusTab(editor.id);
      await pumpFrames(tester);
      expect(terminal.viewHeight, greaterThan(terminalRows));

      // A background shell can save its cursor at the bottom of the larger
      // grid while the editor owns the status row. Its next prompt redraw
      // restores that cursor after the terminal tab's status bar returns.
      session.engine.feed(
        Uint8List.fromList(utf8.encode('\x1b[${terminal.viewHeight};1H\x1b7')),
      );
      state.focusTab(session.id);
      await pumpFrames(tester);
      expect(terminal.viewHeight, terminalRows);
      expect(
        () => session.engine.feed(
          Uint8List.fromList(utf8.encode('\x1b8Restored shell output')),
        ),
        returnsNormally,
      );
      await pumpFrames(tester);
      expect(terminal.buffer.getText(), contains('Restored shell output'));
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      expect(render.size.width, greaterThan(0));
      expect(render.size.height, greaterThan(0));
      expect(render.cursorOffset.dx, inInclusiveRange(0, render.size.width));
      expect(render.cursorOffset.dy, inInclusiveRange(0, render.size.height));
      expect(terminalFocus(tester).hasPrimaryFocus, isTrue);
      final input = <int>[];
      final subscription = session.engine.userInput.listen(input.addAll);
      addTearDown(subscription.cancel);
      tester.testTextInput.enterText('still usable');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(String.fromCharCodes(input), 'still usable\r');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rebuilding a connected terminal preserves sidebar filter focus',
    (tester) async {
      await mount(tester);
      await open(tester, 'alpha');
      await complete(tester, 0);
      expect(ServerListPane.revealFilter(), isTrue);
      await pumpFrames(tester);
      final filter = tester.widget<TextField>(
        find.byKey(const ValueKey('servers.filter.field')),
      );
      expect(filter.focusNode!.hasPrimaryFocus, isTrue);

      state.focusTab(state.activeTabId!);
      await pumpFrames(tester);
      expect(filter.focusNode!.hasPrimaryFocus, isTrue);
      expect(terminalFocus(tester).hasFocus, isFalse);
    },
  );

  testWidgets('connection completion does not take focus from a dialog', (
    tester,
  ) async {
    await mount(tester);
    await open(tester, 'alpha');
    final dialogFocus = FocusNode();
    addTearDown(dialogFocus.dispose);
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(AdaptiveShell)),
        builder: (_) => AlertDialog(
          content: TextField(focusNode: dialogFocus, autofocus: true),
        ),
      ),
    );
    await pumpFrames(tester);
    expect(dialogFocus.hasPrimaryFocus, isTrue);

    await complete(tester, 0);
    expect(dialogFocus.hasPrimaryFocus, isTrue);
  });
}

class _PendingConnection {
  _PendingConnection(TerminalEngine engine) : session = _OpenSshSession(engine);

  final ready = Completer<void>();
  final _OpenSshSession session;
}

class _OpenSshSession implements SshSession {
  _OpenSshSession(this.engine);

  @override
  final TerminalEngine engine;

  @override
  bool isClosed = false;

  @override
  void Function()? onClosed;

  @override
  void resize(TerminalSize size) {}

  @override
  Future<void> close() async {
    isClosed = true;
    await engine.dispose();
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
