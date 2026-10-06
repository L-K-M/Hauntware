import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart' show EditorZoom;
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/managed_remote_file_store.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/files_pane.dart';
import 'package:seance_app/ui/terminal_appearance.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

/// Settings writes that the test answers by hand.
class _Services implements AppServices {
  _Services(this.managedRemoteFiles);

  @override
  final ManagedRemoteFileStore managedRemoteFiles;
  @override
  final AppSettings settings = AppSettings();
  @override
  final ProbeService probe = ProbeService();

  final saves = <Completer<void>>[];

  @override
  Future<void> saveSettings() {
    final save = Completer<void>();
    saves.add(save);
    return save.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OpenShell implements SshSession {
  _OpenShell(this.engine);
  @override
  final TerminalEngine engine;
  @override
  bool get isClosed => false;
  @override
  Future<void> close() => engine.dispose();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _server = ServerConfig(
  id: 'box',
  label: 'box',
  host: 'box.example.com',
  username: 'deploy',
  createdAt: 1,
  updatedAt: 1,
);

const _diskFull = FileSystemException('disk full');

/// The zoom chords resize at once and save afterwards. A failed save says
/// so, unless a newer zoom's save already carries the change.
void main() {
  late Directory directory;
  late _Services services;
  late AppState state;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('seance-zoom-save-');
    services = _Services(
      ManagedRemoteFileStore(
        indexFile: File('${directory.path}/index.json'),
        checkoutRoot: Directory('${directory.path}/checkouts'),
      ),
    );
    state = AppState(services);
  });

  tearDown(() {
    state.dispose();
    directory.deleteSync(recursive: true);
  });

  test('only the newest zoom reports a failed save', () async {
    final older = state.zoomEditor(EditorZoom.zoomIn);
    final newer = state.zoomTerminal(1);
    expect(services.saves, hasLength(2));

    services.saves[0].completeError(_diskFull);
    await expectLater(older, completes);

    services.saves[1].completeError(_diskFull);
    await expectLater(newer, throwsA(_diskFull));

    // Both sizes stay applied for this session.
    expect(services.settings.editorFontSize, 16);
    expect(services.settings.terminalFontSize, kDefaultTerminalFontSize + 1);
  });

  /// The chord's modifier: ⌘ on Apple platforms, Ctrl+Shift in a terminal
  /// elsewhere (plain Ctrl in an editor).
  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    required bool terminal,
  }) async {
    final apple = Platform.isMacOS || Platform.isIOS;
    final modifiers = [
      apple ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft,
      if (terminal && !apple) LogicalKeyboardKey.shiftLeft,
    ];
    for (final modifier in modifiers) {
      await tester.sendKeyDownEvent(modifier);
    }
    await tester.sendKeyEvent(key);
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
  }

  testWidgets('a terminal zoom that is not saved says so', (tester) async {
    final tab = TerminalSession(
      id: 'tab',
      serverId: _server.id,
      config: _server,
      engine: XtermTerminalEngine(),
    );
    tab
      ..session = _OpenShell(tab.engine)
      ..connecting = false;
    state.tabs.add(tab);
    state.activeTabId = tab.id;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(state: state, child: child!),
        home: TerminalPane(showAssistantAffordance: false, onBack: () {}),
      ),
    );
    await tester.pump();

    await chord(tester, LogicalKeyboardKey.equal, terminal: true);
    expect(services.settings.terminalFontSize, kDefaultTerminalFontSize + 1);
    services.saves.single.completeError(_diskFull);
    await tester.pump();

    expect(
      find.text('Terminal font size not saved — $_diskFull'),
      findsOneWidget,
    );
    // The toast's timer.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an editor zoom that is not saved says so', (tester) async {
    const localPath = 'box/config.txt';
    await tester.runAsync(() async {
      final file = services.managedRemoteFiles.checkoutFile(localPath);
      await file.create(recursive: true);
      await file.writeAsString('one\n');
    });
    final tab = EditorTab(
      id: 'editor',
      serverId: _server.id,
      config: _server,
      remotePath: '/etc/config.txt',
      localPath: localPath,
      ownerEditSessionId: 'gone',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorTabView(tab: tab, state: state, isActive: true),
        ),
      ),
    );
    // The editor reads its checkout from disk, outside the fake clock.
    for (var i = 0; i < 100 && find.byType(TextField).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.tap(find.byType(TextField));
    await tester.pump();

    await chord(tester, LogicalKeyboardKey.equal, terminal: false);
    expect(services.settings.editorFontSize, 16);
    services.saves.single.completeError(_diskFull);
    await tester.pump();

    expect(
      find.text('Editor text size not saved — $_diskFull'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    tab.dirty.dispose();
  });
}
