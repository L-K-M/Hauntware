import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_quit_guard.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/built_in_text_editor.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('QuitRiskSnapshot', () {
    test(
      'collects every dirty editor and connecting or connected session',
      () async {
        final engines = <XtermTerminalEngine>[];
        TerminalSession terminal(
          String id, {
          bool connecting = false,
          bool connected = false,
        }) {
          final engine = XtermTerminalEngine();
          engines.add(engine);
          final tab = TerminalSession(
            id: id,
            serverId: 'server',
            config: _server,
            engine: engine,
            connecting: connecting,
          );
          if (connected) tab.session = _OpenTransport();
          return tab;
        }

        final dirty = EditorTab(
          id: 'dirty',
          serverId: _server.id,
          config: _server,
          remotePath: '/tmp/unsafe\nname',
          localPath: 'unsafe',
          ownerEditSessionId: 'owner',
        )..dirty.value = true;
        final clean = EditorTab(
          id: 'clean',
          serverId: _server.id,
          config: _server,
          remotePath: '/tmp/clean',
          localPath: 'clean',
          ownerEditSessionId: 'owner',
        );
        final connecting = terminal('connecting', connecting: true);
        final connected = terminal('connected', connected: true);
        final disconnected = terminal('disconnected');

        final snapshot = QuitRiskSnapshot.fromTabs([
          dirty,
          clean,
          connecting,
          connected,
          disconnected,
        ]);

        expect(snapshot.dirtyEditors, hasLength(1));
        expect(snapshot.dirtyEditors.single.path, '/tmp/unsafe name');
        expect(snapshot.dirtyEditors.single.server, 'Production server');
        expect(snapshot.activeSessions.map((session) => session.status), [
          QuitSessionStatus.connecting,
          QuitSessionStatus.connected,
        ]);
        expect(
          snapshot.activeSessions.map((session) => session.target),
          everyElement('deploy@example.test:22'),
        );

        for (final tab in [connecting, connected, disconnected]) {
          tab.dispose();
        }
        for (final engine in engines) {
          await engine.dispose();
        }
      },
    );
  });

  test('clean state exits immediately without a navigator or dialog', () async {
    var dialogs = 0;
    final guard = AppQuitGuard(
      navigatorKey: GlobalKey<NavigatorState>(),
      snapshotOverride: () => QuitRiskSnapshot(),
      presentDialog: (_, _) async {
        dialogs++;
        return QuitChoice.cancel;
      },
    );

    expect(await guard.confirmClose(), isTrue);
    expect(dialogs, 0);
  });

  test('hazards fail closed while the root navigator is unavailable', () async {
    var dialogs = 0;
    final guard = AppQuitGuard(
      navigatorKey: GlobalKey<NavigatorState>(),
      snapshotOverride: _hazards,
      presentDialog: (_, _) async {
        dialogs++;
        return QuitChoice.quit;
      },
    );

    expect(await guard.confirmClose(), isFalse);
    expect(dialogs, 0);
  });

  testWidgets('concurrent close routes share one decision', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await _pumpNavigator(tester, navigator);
    final answer = Completer<QuitChoice?>();
    var dialogs = 0;
    final guard = AppQuitGuard(
      navigatorKey: navigator,
      snapshotOverride: _hazards,
      presentDialog: (_, _) {
        dialogs++;
        return answer.future;
      },
    );

    final first = guard.confirmClose();
    final second = guard.confirmClose();
    expect(identical(first, second), isTrue);
    expect(dialogs, 1);

    answer.complete(QuitChoice.cancel);
    expect(await first, isFalse);
    expect(await second, isFalse);
  });

  testWidgets('cancel restores yielded Settings and a retry re-snapshots', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await _pumpNavigator(tester, navigator);
    final settings = _FakeSettingsWindow();
    var snapshot = _hazards();
    var dialogs = 0;
    final guard = AppQuitGuard(
      navigatorKey: navigator,
      settingsWindow: () => settings,
      snapshotOverride: () => snapshot,
      presentDialog: (_, _) async {
        settings.events.add('dialog');
        dialogs++;
        return QuitChoice.cancel;
      },
    );

    expect(await guard.confirmClose(), isFalse);
    expect(settings.events, ['yield', 'dialog', 'restore']);

    snapshot = QuitRiskSnapshot(
      dirtyEditors: const [QuitDirtyEditor(server: 'second', path: '/changed')],
    );
    expect(await guard.confirmClose(), isFalse);
    expect(dialogs, 2);
  });

  testWidgets('accepted quit stays latched and leaves Settings hidden', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await _pumpNavigator(tester, navigator);
    final settings = _FakeSettingsWindow();
    var dialogs = 0;
    final guard = AppQuitGuard(
      navigatorKey: navigator,
      settingsWindow: () => settings,
      snapshotOverride: _hazards,
      presentDialog: (_, _) async {
        dialogs++;
        return QuitChoice.quit;
      },
    );

    expect(await guard.confirmClose(), isTrue);
    expect(await guard.confirmClose(), isTrue);
    expect(dialogs, 1);
    expect(settings.events, ['yield']);

    await guard.handleCloseFailure();
    expect(settings.events, ['yield', 'restore']);
    expect(await guard.confirmClose(), isTrue);
    expect(dialogs, 2);
  });

  testWidgets('a dialog error fails closed and restores Settings', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await _pumpNavigator(tester, navigator);
    final settings = _FakeSettingsWindow();
    final errors = <Object>[];
    final guard = AppQuitGuard(
      navigatorKey: navigator,
      settingsWindow: () => settings,
      snapshotOverride: _hazards,
      presentDialog: (_, _) => throw StateError('dialog failed'),
      onError: (error, _) => errors.add(error),
    );

    expect(await guard.confirmClose(), isFalse);
    expect(settings.events, ['yield', 'restore']);
    expect(errors.single, isA<StateError>());
  });

  testWidgets('dialog lists every risk and Cancel is autofocus', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await _pumpNavigator(tester, navigator);
    final snapshot = QuitRiskSnapshot(
      dirtyEditors: const [
        QuitDirtyEditor(server: 'one', path: '/first'),
        QuitDirtyEditor(server: 'two', path: '/second'),
      ],
      activeSessions: const [
        QuitActiveSession(
          label: 'Build',
          target: 'dev@build:22',
          status: QuitSessionStatus.connecting,
        ),
        QuitActiveSession(
          label: 'Deploy',
          target: 'dev@deploy:22',
          status: QuitSessionStatus.connected,
        ),
      ],
    );
    final guard = AppQuitGuard(
      navigatorKey: navigator,
      snapshotOverride: () => snapshot,
    );

    final decision = guard.confirmClose();
    await tester.pumpAndSettle();

    expect(find.text('Quit Séance?'), findsOneWidget);
    expect(find.text('Unsaved files'), findsOneWidget);
    expect(find.text('/first'), findsOneWidget);
    expect(find.text('/second'), findsOneWidget);
    expect(find.text('Active sessions'), findsOneWidget);
    expect(find.text('dev@build:22 · Connecting'), findsOneWidget);
    expect(find.text('dev@deploy:22 · Connected'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('quit-cancel')))
          .autofocus,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('quit-cancel')));
    await tester.pumpAndSettle();
    expect(await decision, isFalse);
  });

  testWidgets('Escape and barrier dismissal both veto the quit', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await _pumpNavigator(tester, navigator);
    final guard = AppQuitGuard(
      navigatorKey: navigator,
      snapshotOverride: _hazards,
    );

    var decision = guard.confirmClose();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await decision, isFalse);

    decision = guard.confirmClose();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(await decision, isFalse);
  });

  testWidgets('Save All saves every dirty editor and quits', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final editorKey = GlobalKey<BuiltInTextEditorScreenState>();
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: BuiltInTextEditorScreen(
          key: editorKey,
          file: File('/tmp/seance-quit-save.txt'),
          remotePath: '/etc/config.txt',
          initialText: 'one\n',
          saveDocument: (_, text) async {
            saved.add(text);
          },
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'unsaved\n');
    await tester.pump();
    expect(editorKey.currentState!.isDirty, isTrue);

    final guard = AppQuitGuard(
      navigatorKey: navigator,
      snapshotOverride: () => QuitRiskSnapshot(
        dirtyEditors: [
          QuitDirtyEditor(
            server: 'server',
            path: '/etc/config.txt',
            editorKey: editorKey,
          ),
        ],
      ),
    );

    final decision = guard.confirmClose();
    await tester.pumpAndSettle();
    expect(find.text('Save All'), findsOneWidget);
    await tester.tap(find.text('Save All'));
    await tester.pumpAndSettle();

    expect(saved, ['unsaved\n']);
    expect(await decision, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Save All rechecks editors saved earlier in the batch', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final firstKey = GlobalKey<BuiltInTextEditorScreenState>();
    final secondKey = GlobalKey<BuiltInTextEditorScreenState>();
    TextEditingController? firstBuffer;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: Column(children: [
        Expanded(child: BuiltInTextEditorScreen(
          key: firstKey,
          file: File('/tmp/seance-quit-first.txt'),
          remotePath: '/first.txt',
          initialText: 'first',
          saveDocument: (_, _) async {},
        )),
        Expanded(child: BuiltInTextEditorScreen(
          key: secondKey,
          file: File('/tmp/seance-quit-second.txt'),
          remotePath: '/second.txt',
          initialText: 'second',
          saveDocument: (_, _) async {
            firstBuffer!.text = 'new edits while the second save waits';
          },
        )),
      ]),
    ));
    await tester.pump();
    final firstField = find.descendant(
      of: find.byKey(firstKey), matching: find.byType(TextField),
    ).first;
    final secondField = find.descendant(
      of: find.byKey(secondKey), matching: find.byType(TextField),
    ).first;
    firstBuffer = tester.widget<TextField>(firstField).controller;
    await tester.enterText(firstField, 'first changed');
    await tester.enterText(secondField, 'second changed');
    await tester.pump();
    final guard = AppQuitGuard(
      navigatorKey: navigator,
      snapshotOverride: () => QuitRiskSnapshot(dirtyEditors: [
        QuitDirtyEditor(server: 'server', path: '/first.txt', editorKey: firstKey),
        QuitDirtyEditor(server: 'server', path: '/second.txt', editorKey: secondKey),
      ]),
    );

    final decision = guard.confirmClose();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save All'));
    await tester.pumpAndSettle();

    expect(firstKey.currentState!.isDirty, isTrue);
    expect(await decision, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed Save All vetoes the quit and restores Settings', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final editorKey = GlobalKey<BuiltInTextEditorScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: BuiltInTextEditorScreen(
          key: editorKey,
          file: File('/tmp/seance-quit-fail.txt'),
          remotePath: '/etc/config.txt',
          initialText: 'one\n',
          saveDocument: (_, _) async => throw const FileSystemException('full'),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'unsaved\n');
    await tester.pump();

    final settings = _FakeSettingsWindow();
    final guard = AppQuitGuard(
      navigatorKey: navigator,
      settingsWindow: () => settings,
      snapshotOverride: () => QuitRiskSnapshot(
        dirtyEditors: [
          QuitDirtyEditor(
            server: 'server',
            path: '/etc/config.txt',
            editorKey: editorKey,
          ),
        ],
      ),
    );

    final decision = guard.confirmClose();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save All'));
    await tester.pumpAndSettle();

    expect(await decision, isFalse);
    expect(settings.events, ['yield', 'restore']);
    expect(find.textContaining('full'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a dirty editor with no mounted state vetoes Save All', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await _pumpNavigator(tester, navigator);
    final editorKey = GlobalKey<BuiltInTextEditorScreenState>();
    final guard = AppQuitGuard(
      navigatorKey: navigator,
      snapshotOverride: () => QuitRiskSnapshot(
        dirtyEditors: [
          QuitDirtyEditor(
            server: 'server',
            path: '/etc/config.txt',
            editorKey: editorKey,
          ),
        ],
      ),
    );

    final decision = guard.confirmClose();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save All'));
    await tester.pumpAndSettle();

    expect(await decision, isFalse);
  });

  testWidgets('no dirty editors hides Save All', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await _pumpNavigator(tester, navigator);
    final guard = AppQuitGuard(
      navigatorKey: navigator,
      snapshotOverride: () => QuitRiskSnapshot(
        activeSessions: const [
          QuitActiveSession(
            label: 'Build',
            target: 'dev@build:22',
            status: QuitSessionStatus.connected,
          ),
        ],
      ),
    );

    final decision = guard.confirmClose();
    await tester.pumpAndSettle();
    expect(find.text('Quit Séance?'), findsOneWidget);
    expect(find.text('Save All'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('quit-confirm')));
    await tester.pumpAndSettle();
    expect(await decision, isTrue);
  });
}

const _server = ServerConfig(
  id: 'server',
  label: 'Production server',
  host: 'example.test',
  username: 'deploy',
  createdAt: 1,
  updatedAt: 1,
);

QuitRiskSnapshot _hazards() => QuitRiskSnapshot(
  dirtyEditors: const [
    QuitDirtyEditor(server: 'Production server', path: '/etc/service.conf'),
  ],
);

Future<void> _pumpNavigator(
  WidgetTester tester,
  GlobalKey<NavigatorState> navigator,
) async {
  await tester.pumpWidget(
    MaterialApp(navigatorKey: navigator, home: const SizedBox()),
  );
  await tester.pump();
}

class _FakeSettingsWindow implements QuitSettingsWindow {
  final events = <String>[];

  @override
  Future<bool> yieldForQuitConfirmation() async {
    events.add('yield');
    return true;
  }

  @override
  Future<void> restoreAfterQuitConfirmation() async {
    events.add('restore');
  }
}

class _OpenTransport implements SessionTransport {
  @override
  bool get isClosed => false;

  @override
  void Function()? onClosed;

  @override
  Future<void> close() async {}

  @override
  void resize(TerminalSize size) {}
}
