import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/editor_document.dart';
import 'package:seance_app/services/external_file_opener.dart';
import 'package:seance_app/services/remote_files_controller.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/files_pane.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

import 'support/system_open_recorder.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _home = '/home/test';

/// The files pane's desktop posture renders the shared dense rows
/// (D32 §6): a column header over fixed-extent [GhostFileRow]s with
/// pointer-down selection, Ctrl/Shift multi-select, a keyboard cursor,
/// and the verb menu on right-click/Menu/Shift+F10. Touch posture keeps
/// the comfortable [GhostFileCompactRow]s.
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

  const server = ServerConfig(
    id: 'box',
    label: 'box',
    host: 'box.example.com',
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  /// The files pane over a connected session backed by [remote].
  Future<RemoteFilesController> pumpFilesPane(
    WidgetTester tester,
    _ListFileSystem remote, {
    double textScale = 1,
    double? paneWidth,
  }) async {
    late final RemoteFilesController files;
    final session = TerminalSession(
      id: 'tab',
      serverId: server.id,
      config: server,
      engine: XtermTerminalEngine(),
    );
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-desktop-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _pathChannel,
            (call) async => directory!.path,
          );
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      await state!.saveServer(server);
      files = RemoteFilesController(
        () async => remote,
        shellDirectory: session.engine.workingDirectory,
        managedFileStore: services!.managedRemoteFiles,
        serverId: session.serverId,
        editSessionId: session.editSessionId,
      );
      await files.initialize();
    });
    session
      ..session = _OpenSshSession(session.engine)
      ..files = files
      ..connecting = false;
    state!
      ..tabs.add(session)
      ..activeTabId = session.id;

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: AppScope(state: state!, child: child!),
        ),
        home: Scaffold(
          body: paneWidth == null
              ? const FilesPane()
              : Row(
                  children: [
                    SizedBox(width: paneWidth, child: const FilesPane()),
                    Expanded(
                      child: Column(
                        children: [
                          const Expanded(child: SizedBox.shrink()),
                          SessionStatusBar(session: session),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
    await tester.pump();
    return files;
  }

  /// Pumps until [done]: a checkout writes real files, so its I/O lands
  /// between frames while the fake clock runs for the timers it waits on.
  /// Bounded by wall time, not frames: a loaded machine took over 4 s to
  /// check out a 4 MB file.
  Future<void> settleCheckout(WidgetTester tester, bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue, reason: 'the checkout did not settle in 30 s');
  }

  /// Two presses with no frame between them: the pane times the
  /// double-click against the wall clock, which a loaded machine could
  /// otherwise stretch past the window.
  Future<void> doubleClick(WidgetTester tester, String name) async {
    await tester.tap(find.text(name));
    await tester.tap(find.text(name));
    await tester.pump();
  }

  /// A test pinned to [platform] — the pane picks its posture from
  /// `Theme.of(context).platform`. The binding requires the override
  /// reset inside the test body, before its invariant check runs.
  void platformTest(
    String description,
    TargetPlatform platform,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    for (final scale in [1.0, 2.0, 4.0]) {
      platformTest(
        'directory-follow footer aligns on $platform at $scale×',
        platform,
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(1600, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await pumpFilesPane(
            tester,
            _ListFileSystem(),
            textScale: scale,
            paneWidth: scale == 1 ? 240 : 1000,
          );

          final footer = find.byKey(const ValueKey('files.footer'));
          expect(footer, findsOneWidget);
          final filesRect = tester.getRect(footer);
          final terminalRect = tester.getRect(find.byType(SessionStatusBar));
          expect(filesRect.height, terminalRect.height);
          expect(filesRect.top, terminalRect.top);
          expect(
            filesRect.bottom,
            tester.getRect(find.byType(FilesPane)).bottom,
          );
          expect(
            find.descendant(of: footer, matching: find.byType(Checkbox)),
            findsOneWidget,
          );
          expect(find.byType(Switch), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  platformTest(
    'directory-follow checkbox and label toggle following',
    TargetPlatform.linux,
    (tester) async {
      final files = await pumpFilesPane(tester, _ListFileSystem());
      final checkbox = find.byType(Checkbox);
      expect(tester.widget<Checkbox>(checkbox).value, isTrue);
      expect(
        find.byTooltip('Waiting for directory metadata from the remote shell'),
        findsOneWidget,
      );

      await tester.tap(checkbox);
      await tester.pump();
      expect(files.followTerminal, isFalse);
      expect(tester.widget<Checkbox>(checkbox).value, isFalse);
      expect(find.byIcon(Icons.info_outline), findsNothing);

      await tester.tap(find.text('Follow terminal directory'));
      await tester.pump();
      expect(files.followTerminal, isTrue);
      expect(tester.widget<Checkbox>(checkbox).value, isTrue);
    },
  );

  Future<void> openNewFile(WidgetTester tester) async {
    await tester.tap(find.byTooltip('File actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New file…'));
    await tester.pumpAndSettle();
  }

  Finder nameField() => find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(TextField),
  );

  for (final platform in [TargetPlatform.linux, TargetPlatform.android]) {
    platformTest(
      'New file creates an empty file in the displayed directory on $platform',
      platform,
      (tester) async {
        final remote = _ListFileSystem();
        final files = await pumpFilesPane(tester, remote);
        files.setFollowTerminal(false);
        await files.navigate('$_home/docs');
        await tester.pump();

        await openNewFile(tester);
        await tester.enterText(nameField(), 'notes.txt');
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        expect(remote.uploaded['$_home/docs/notes.txt'], isEmpty);
        expect(remote.overwrites, [false]);
        expect(files.entries.single.name, 'notes.txt');
        expect(files.entries.single.size, 0);
        expect(
          find.descendant(
            of: find.byWidgetPredicate(
              (widget) =>
                  widget is GhostFileRow || widget is GhostFileCompactRow,
            ),
            matching: find.text('notes.txt'),
          ),
          findsOneWidget,
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('files.footer'))).bottom,
          tester.getRect(find.byType(FilesPane)).bottom,
        );
      },
    );
  }

  platformTest(
    'New file keeps its target if the browser moves while naming it',
    TargetPlatform.linux,
    (tester) async {
      final remote = _ListFileSystem();
      final files = await pumpFilesPane(tester, remote);
      await openNewFile(tester);
      await files.navigate('$_home/docs');
      await tester.pump();

      await tester.enterText(nameField(), 'notes.txt');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(remote.uploaded.keys, ['$_home/notes.txt']);
      expect(remote.uploaded['$_home/notes.txt'], isEmpty);
      expect(files.currentPath, '$_home/docs');
      expect(files.entries, isEmpty);
    },
  );

  platformTest(
    'New file rejects invalid names and cancel creates nothing',
    TargetPlatform.linux,
    (tester) async {
      final remote = _ListFileSystem();
      await pumpFilesPane(tester, remote);
      await openNewFile(tester);

      for (final name in ['', '..', 'folder/file.txt']) {
        await tester.enterText(nameField(), name);
        await tester.tap(find.text('Create'));
        await tester.pump();
        expect(find.text('Enter one valid name.'), findsOneWidget);
        expect(remote.uploaded, isEmpty);
      }

      await tester.enterText(nameField(), 'cancelled.txt');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(remote.uploaded, isEmpty);
      expect(remote.overwrites, isEmpty);
    },
  );

  platformTest(
    'New file reports a conflict without replacing an existing file',
    TargetPlatform.linux,
    (tester) async {
      final remote = _ListFileSystem();
      final files = await pumpFilesPane(tester, remote);
      await openNewFile(tester);
      await tester.enterText(nameField(), 'a.txt');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(remote.uploaded, isEmpty);
      expect(remote.overwrites, [false]);
      expect(
        files.entries.singleWhere((entry) => entry.name == 'a.txt').size,
        10,
      );
      expect(
        find.text('A remote item named "a.txt" already exists.'),
        findsWidgets,
      );
    },
  );

  platformTest(
    'desktop lists dense shared rows under the column header',
    TargetPlatform.linux,
    (tester) async {
      await pumpFilesPane(tester, _ListFileSystem());
      expect(find.byType(GhostFileColumnHeader), findsOneWidget);
      expect(find.byType(GhostFileRow), findsNWidgets(4));
      expect(find.byType(GhostFileCompactRow), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Date Modified'), findsOneWidget);
    },
  );

  platformTest(
    'a tap selects, Ctrl-tap toggles, Shift-tap ranges',
    TargetPlatform.linux,
    (tester) async {
      final files = await pumpFilesPane(tester, _ListFileSystem());

      await tester.tap(find.text('a.txt'));
      await tester.pump();
      expect(files.selectedPaths, {'$_home/a.txt'});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('b.bin'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(files.selectedPaths, {'$_home/a.txt', '$_home/b.bin'});

      // Ctrl-tap on a selected row takes it back out.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('a.txt'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(files.selectedPaths, {'$_home/b.bin'});

      // A plain press re-anchors, then Shift extends the contiguous run.
      await tester.tap(find.text('a.txt'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('z.txt'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(files.selectedPaths, {
        '$_home/a.txt',
        '$_home/b.bin',
        '$_home/z.txt',
      });
    },
  );

  platformTest('a double-click on a directory opens it', TargetPlatform.linux, (
    tester,
  ) async {
    final files = await pumpFilesPane(tester, _ListFileSystem());

    await tester.tap(find.text('docs'));
    await tester.pump();
    expect(files.currentPath, _home);
    expect(files.selectedPaths, {'$_home/docs'});

    await tester.tap(find.text('docs'));
    await tester.pump();
    await tester.runAsync(() async {});
    await tester.pump();
    expect(files.currentPath, '$_home/docs');
  });

  platformTest(
    'a double-click on a file opens it in a built-in editor tab',
    TargetPlatform.linux,
    (tester) async {
      final files = await pumpFilesPane(tester, _ListFileSystem());

      await doubleClick(tester, 'a.txt');
      await settleCheckout(tester, () => state!.activeTab is EditorTab);

      final editor = state!.activeTab;
      expect(editor, isA<EditorTab>());
      expect((editor! as EditorTab).remotePath, '$_home/a.txt');
      expect(state!.tabs, hasLength(2));

      await tester.runAsync(() => files.removeLocalCopy('$_home/a.txt'));
    },
  );

  platformTest(
    'a double-click gives a binary file to the system\'s default app',
    TargetPlatform.linux,
    (tester) async {
      final opened = recordSystemOpens();
      final files = await pumpFilesPane(tester, _ListFileSystem());

      await doubleClick(tester, 'b.bin');
      await settleCheckout(tester, () => opened.isNotEmpty);

      expect(opened, [endsWith('b.bin')]);
      expect(state!.tabs, hasLength(1));

      await tester.runAsync(() => files.removeLocalCopy('$_home/b.bin'));
    },
  );

  platformTest(
    'a double-click gives a file over 4 MB to the system\'s default app',
    TargetPlatform.linux,
    (tester) async {
      final opened = recordSystemOpens();
      final files = await pumpFilesPane(
        tester,
        _ListFileSystem(
          extra: [
            const RemoteFileEntry(
              path: '$_home/big.log',
              name: 'big.log',
              type: RemoteFileType.file,
              size: builtInEditorMaximumBytes + 1,
            ),
          ],
        ),
      );

      await doubleClick(tester, 'big.log');
      await settleCheckout(tester, () => opened.isNotEmpty);

      expect(opened, [endsWith('big.log')]);
      expect(state!.tabs, hasLength(1));
      expect(find.textContaining('4 MB'), findsNothing);

      await tester.runAsync(() => files.removeLocalCopy('$_home/big.log'));
    },
  );

  platformTest(
    'a double-click never hands a program to the system\'s default app',
    TargetPlatform.linux,
    (tester) async {
      final opened = recordSystemOpens();
      final files = await pumpFilesPane(
        tester,
        _ListFileSystem(
          extra: [
            const RemoteFileEntry(
              path: '$_home/tool.jar',
              name: 'tool.jar',
              type: RemoteFileType.file,
              size: 64,
            ),
          ],
        ),
      );

      // Binary, so the built-in editor refuses it; Linux runs a jar.
      await doubleClick(tester, 'tool.jar');
      await settleCheckout(
        tester,
        () =>
            find.textContaining('could run as a program').evaluate().isNotEmpty,
      );

      expect(
        find.textContaining('“tool.jar” could run as a program'),
        findsOneWidget,
      );
      expect(opened, isEmpty);
      expect(state!.tabs, hasLength(1));

      await tester.runAsync(() => files.removeLocalCopy('$_home/tool.jar'));
    },
  );

  platformTest(
    'System default refuses a program before downloading it',
    TargetPlatform.linux,
    (tester) async {
      final opened = recordSystemOpens();
      final files = await pumpFilesPane(
        tester,
        _ListFileSystem(
          extra: [
            RemoteFileEntry(
              path: '$_home/$_hostProgram',
              name: _hostProgram,
              type: RemoteFileType.file,
              size: 64,
            ),
          ],
        ),
      );
      services!.settings.editorRegistry.defaultEditorId =
          EditorRegistry.systemDefaultId;

      await doubleClick(tester, _hostProgram);
      await settleCheckout(
        tester,
        () =>
            find.textContaining('could run as a program').evaluate().isNotEmpty,
      );

      expect(
        find.textContaining('“$_hostProgram” could run as a program'),
        findsOneWidget,
      );
      expect(opened, isEmpty);
      expect(files.localCopies, isEmpty);
    },
  );

  platformTest(
    'Open with System default refuses a program before downloading it',
    TargetPlatform.linux,
    (tester) async {
      final opened = recordSystemOpens();
      final files = await pumpFilesPane(
        tester,
        _ListFileSystem(
          extra: [
            RemoteFileEntry(
              path: '$_home/$_hostProgram',
              name: _hostProgram,
              type: RemoteFileType.file,
              size: 64,
            ),
          ],
        ),
      );

      await tester.tap(find.text(_hostProgram), buttons: kSecondaryMouseButton);
      await tester.pump();
      // Past the menu's entrance: a tap during it dismisses the menu.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Open with System default'));
      await settleCheckout(
        tester,
        () =>
            find.textContaining('could run as a program').evaluate().isNotEmpty,
      );

      expect(
        find.textContaining('“$_hostProgram” could run as a program'),
        findsOneWidget,
      );
      expect(opened, isEmpty);
      expect(files.localCopies, isEmpty);
    },
  );

  platformTest(
    'arrows move the cursor and select; Enter opens',
    TargetPlatform.linux,
    (tester) async {
      final files = await pumpFilesPane(tester, _ListFileSystem());

      // The press arms the listing's focus and puts the cursor on a.txt.
      await tester.tap(find.text('a.txt'));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(files.selectedPaths, {'$_home/b.bin'});

      // Shift+arrow extends from the anchor (b.bin, the last plain
      // press) instead of single-selecting — up covers a.txt, back down
      // collapses to the anchor again.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(files.selectedPaths, {'$_home/a.txt', '$_home/b.bin'});
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(files.selectedPaths, {'$_home/b.bin'});

      // Enter opens the cursor row: two arrows up land it on docs.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.runAsync(() async {});
      await tester.pump();
      expect(files.currentPath, '$_home/docs');
    },
  );

  platformTest('Ctrl+A selects all and Escape clears', TargetPlatform.linux, (
    tester,
  ) async {
    final files = await pumpFilesPane(tester, _ListFileSystem());

    await tester.tap(find.text('a.txt'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(files.selectedPaths, hasLength(4));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(files.selectedPaths, isEmpty);
  });

  platformTest(
    'a right-click selects the row and shows its verbs',
    TargetPlatform.linux,
    (tester) async {
      final files = await pumpFilesPane(tester, _ListFileSystem());

      await tester.tap(find.text('a.txt'), buttons: kSecondaryMouseButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(files.selectedPaths, {'$_home/a.txt'});
      expect(find.text('Open locally'), findsOneWidget);
      expect(find.text('Copy remote path'), findsOneWidget);
      expect(find.text('Rename…'), findsOneWidget);
      expect(find.text('Delete…'), findsOneWidget);

      await tester.tapAt(const Offset(8, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    },
  );

  platformTest(
    'the Menu key and Shift+F10 open the cursor row\'s verbs',
    TargetPlatform.linux,
    (tester) async {
      await pumpFilesPane(tester, _ListFileSystem());

      await tester.tap(find.text('a.txt'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Open locally'), findsOneWidget);
      await tester.tapAt(const Offset(8, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Open locally'), findsOneWidget);
      await tester.tapAt(const Offset(8, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    },
  );

  platformTest(
    'the row\'s ⋮ action opens the same verbs',
    TargetPlatform.linux,
    (tester) async {
      await pumpFilesPane(tester, _ListFileSystem());

      await tester.tap(
        find.descendant(
          of: find.byType(GhostFileRow).first,
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Open'), findsWidgets);
      expect(find.text('Delete…'), findsOneWidget);

      await tester.tapAt(const Offset(8, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    },
  );

  platformTest(
    'a column-header tap sorts and a second reverses',
    TargetPlatform.linux,
    (tester) async {
      final files = await pumpFilesPane(tester, _ListFileSystem());
      expect(files.sortField, RemoteSortField.name);

      await tester.tap(find.text('Size'));
      await tester.pump();
      expect(files.sortField, RemoteSortField.size);
      expect(files.sortDirection, RemoteSortDirection.ascending);

      await tester.tap(find.text('Size'));
      await tester.pump();
      expect(files.sortDirection, RemoteSortDirection.descending);
    },
  );

  platformTest(
    'touch posture keeps the comfortable rows',
    TargetPlatform.android,
    (tester) async {
      final files = await pumpFilesPane(tester, _ListFileSystem());
      expect(find.byType(GhostFileCompactRow), findsNWidgets(4));
      expect(find.byType(GhostFileRow), findsNothing);
      expect(find.byType(GhostFileColumnHeader), findsNothing);

      // Long-press selects; a tap on a directory then opens it.
      await tester.longPress(find.text('a.txt'));
      await tester.pump();
      expect(files.selectedPaths, {'$_home/a.txt'});
      await tester.tap(find.text('a.txt'));
      await tester.pump();
      expect(files.selectedPaths, isEmpty);

      await tester.tap(find.text('docs'));
      await tester.pump();
      await tester.runAsync(() async {});
      await tester.pump();
      expect(files.currentPath, '$_home/docs');
    },
  );

  platformTest(
    'a held arrow repeats while held action keys do not',
    TargetPlatform.linux,
    (tester) async {
      final files = await pumpFilesPane(tester, _ListFileSystem());

      await tester.tap(find.text('a.txt'));
      await tester.pump();

      // A held arrow keeps stepping: the key-down and two repeats walk
      // the cursor from a.txt to z.txt.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(files.selectedPaths, {'$_home/z.txt'});

      // A held action key fires once: Space's down toggles z.txt off
      // and its repeat must not toggle it back on.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(files.selectedPaths, isEmpty);
    },
  );
}

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

/// A text file this test host's default app would run as a program. The
/// launch rules follow the real host OS, not the target platform a test
/// pins, so the name must too.
final _hostProgram = switch (currentEditorHostPlatform!) {
  EditorHostPlatform.linux => 'app.desktop',
  EditorHostPlatform.macos => 'run.command',
  EditorHostPlatform.windows => 'run.cmd',
};

/// Names whose download is NUL bytes rather than text.
final _binaryNames = RegExp(r'\.(bin|jar)$');

/// `/home/test` holding a directory and three files, plus [extra];
/// `docs` lists empty. A `.bin` or `.jar` file downloads as NUL bytes,
/// anything else as text.
class _ListFileSystem implements RemoteFileSystem {
  _ListFileSystem({List<RemoteFileEntry> extra = const []}) {
    _entries[_home]!.addAll(extra);
  }

  final _entries = <String, List<RemoteFileEntry>>{
    _home: [
      RemoteFileEntry(
        path: '$_home/docs',
        name: 'docs',
        type: RemoteFileType.directory,
        modifiedAt: DateTime(2026, 1, 2, 3, 4),
      ),
      RemoteFileEntry(
        path: '$_home/a.txt',
        name: 'a.txt',
        type: RemoteFileType.file,
        size: 10,
        modifiedAt: DateTime(2026, 1, 2, 3, 4),
      ),
      RemoteFileEntry(
        path: '$_home/b.bin',
        name: 'b.bin',
        type: RemoteFileType.file,
        size: 2048,
      ),
      RemoteFileEntry(
        path: '$_home/z.txt',
        name: 'z.txt',
        type: RemoteFileType.file,
        size: 5,
      ),
    ],
    '$_home/docs': [],
  };

  final uploaded = <String, List<int>>{};
  final overwrites = <bool>[];

  @override
  Future<String> canonicalize(String path) async => path == '.' ? _home : path;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async =>
      _entries[path] ?? const [];

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    overwrites.add(overwrite);
    final entries = _entries[remoteParent(path)]!;
    if (!overwrite && entries.any((entry) => entry.path == path)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'upload',
        path: path,
        message:
            'A remote item named "${remoteBasename(path)}" already exists.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in content) {
      bytes.addAll(chunk);
    }
    uploaded[path] = bytes;
    final entry = RemoteFileEntry(
      path: path,
      name: remoteBasename(path),
      type: RemoteFileType.file,
      size: bytes.length,
    );
    entries.add(entry);
    return entry;
  }

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    final entry = await stat(path);
    destination.add(
      List.filled(entry.size ?? 0, _binaryNames.hasMatch(path) ? 0 : 0x61),
    );
    return entry;
  }

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    for (final entries in _entries.values) {
      for (final entry in entries) {
        if (entry.path == path) return entry;
      }
    }
    throw RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'inspect',
      path: path,
      message: 'Not found',
    );
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
