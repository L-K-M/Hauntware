import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show GhostResizeHandle, formatShortcutActivator;
import 'package:path/path.dart' as paths;
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/services/folder_workspace.dart';
import 'package:planchette_app/widgets/folder_browser.dart';
import 'package:planchette_editor/planchette_editor.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;
import '../services/memory_settings.dart';

class _Files extends LocalFileSystem {
  _Files(this.root);
  final String root;
  @override
  Future<String> canonicalize(String path) async => path;
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async => [
    RemoteFileEntry(
      path: paths.join(root, 'first.txt'),
      name: 'first.txt',
      type: RemoteFileType.file,
    ),
    RemoteFileEntry(
      path: paths.join(root, 'second.txt'),
      name: 'second.txt',
      type: RemoteFileType.file,
    ),
  ];
}

/// A workspace channel over the fake files, so a test can tell a hidden
/// sidebar (channel kept) from a closed workspace (channel dropped).
class _ChannelFiles extends _Files implements PaneChannel {
  _ChannelFiles(super.root);
  int closes = 0;

  @override
  RemoteFileSystem get fs => this;

  @override
  String get homePath => '/home/user';

  @override
  Future<void> close() async => closes++;

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
}

const _server = ServerConfig(
  id: 'server',
  label: 'Server',
  host: 'host',
  username: 'user',
  authMethod: AuthMethod.agent,
  createdAt: 0,
  updatedAt: 0,
);

/// A status stream that never reports. `Stream.empty()`'s subscription
/// never settles its cancel under the fake-async pump, which would leave
/// a closing workspace's channel close unobserved; this one cancels at
/// once.
final class _NeverStatusStream extends Stream<ServerStatus> {
  const _NeverStatusStream();

  @override
  StreamSubscription<ServerStatus> listen(
    void Function(ServerStatus event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const _NeverStatusSubscription();
}

final class _NeverStatusSubscription
    implements StreamSubscription<ServerStatus> {
  const _NeverStatusSubscription();

  @override
  Future<void> cancel() => Future<void>.value();
  @override
  void onData(void Function(ServerStatus data)? handleData) {}
  @override
  void onError(Function? handleError) {}
  @override
  void onDone(void Function()? handleDone) {}
  @override
  void pause([Future<void>? resumeSignal]) {}
  @override
  void resume() {}
  @override
  bool get isPaused => false;
  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue);
}

/// The toggle buttons' tooltip for [action] ('Hide'/'Show') on [platform].
String _sidebarTooltip(String action, TargetPlatform platform) =>
    '$action sidebar '
    '${formatShortcutActivator(sidebarShortcut(platform), platform)}';

/// Puts keyboard focus on the split view's resize handle.
Future<void> focusResizeHandle(WidgetTester tester) async {
  final context = tester.element(
    find.descendant(
      of: find.byKey(const ValueKey('workspace-divider')),
      matching: find.byType(MouseRegion),
    ),
  );
  Focus.of(context).requestFocus();
  await tester.pump();
}

/// Presses S with [modifiers] held, as a chord would arrive.
Future<void> pressS(
  WidgetTester tester,
  List<LogicalKeyboardKey> modifiers,
) async {
  for (final key in modifiers) {
    await tester.sendKeyDownEvent(key);
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
  for (final key in modifiers.reversed) {
    await tester.sendKeyUpEvent(key);
  }
  await tester.pumpAndSettle();
}

void main() {
  late DocumentWorkspace workspace;
  late String root;
  setUp(() {
    root = testPath('project');
    final store = MemoryDocuments();
    for (final name in ['first.txt', 'second.txt']) {
      store.files[paths.join(root, name)] = document('project/$name', name);
    }
    workspace = DocumentWorkspace(
      store: store,
      dialogs: FakeDialogs(),
      folders: FolderWorkspace(localFileSystem: _Files(root)),
    );
  });
  tearDown(() => workspace.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Future<String?> Function()? pickFolder,
    DocumentWorkspace? into,
    SettingsController? settings,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(
        workspace: into ?? workspace,
        settings: settings ?? testSettings(),
        pickFolder: pickFolder,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'direct file stays single-pane; containing folder adds a browser',
    (tester) async {
      await workspace.open(paths.join(root, 'first.txt'));
      final editor = workspace.active!.editor;
      editor.text.text = 'keep my edits';
      await mount(tester);
      expect(find.byKey(const ValueKey('folder-browser')), findsNothing);
      await tester.tap(find.text('File').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Containing Folder'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('folder-browser')), findsOneWidget);
      expect(workspace.active!.editor, same(editor));
      expect(editor.text.text, 'keep my edits');

      await tester.tap(find.byKey(ValueKey(paths.join(root, 'second.txt'))));
      await tester.pumpAndSettle();
      expect(workspace.documents, hasLength(2));
      expect(workspace.active!.editor.text.text, 'second.txt');
      expect(editor.text.text, 'keep my edits');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Open Folder shortcut and close retain document editing state',
    (tester) async {
      await workspace.open(paths.join(root, 'first.txt'));
      final editor = workspace.active!.editor;
      await mount(tester, pickFolder: () async => root);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(workspace.folders.root, root);
      expect(find.byKey(const ValueKey('folder-browser')), findsOneWidget);

      final before = tester.getSize(find.byType(PlanchetteEditor)).width;
      await tester.drag(
        find.byKey(const ValueKey('workspace-divider')),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(PlanchetteEditor)).width,
        lessThan(before),
      );
      await tester.tap(find.byTooltip('Close folder workspace'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('folder-browser')), findsNothing);
      expect(workspace.active!.editor, same(editor));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  group('sidebar', () {
    testWidgets(
      'the View menu hides and shows the sidebar without closing the workspace',
      (tester) async {
        await workspace.open(paths.join(root, 'first.txt'));
        final editor = workspace.active!.editor;
        editor.text.text = 'keep my edits';
        await workspace.folders.openLocal(root);
        await mount(tester);
        expect(find.byKey(const ValueKey('folder-browser')), findsOneWidget);

        await tester.tap(find.text('View'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hide Sidebar'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('folder-browser')), findsNothing);
        // Hidden is not closed: the workspace, its root and the editor all
        // stay, so showing it again costs nothing.
        expect(workspace.folders.isOpen, isTrue);
        expect(workspace.folders.root, root);
        expect(find.byType(PlanchetteEditor), findsOneWidget);
        expect(editor.text.text, 'keep my edits');

        await tester.tap(find.text('View'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show Sidebar'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('folder-browser')), findsOneWidget);
        expect(workspace.active!.editor, same(editor));
        expect(editor.text.text, 'keep my edits');
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.windows,
      }),
    );

    testWidgets(
      'the chord toggles the sidebar; AltGr, the Ctrl+right-Alt report, does not',
      (tester) async {
        await workspace.folders.openLocal(root);
        await mount(tester);

        await pressS(tester, [
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.altLeft,
        ]);
        expect(find.byKey(const ValueKey('folder-browser')), findsNothing);
        expect(workspace.folders.isOpen, isTrue);

        // Windows reports AltGr as Ctrl + right Alt; the chord stands down
        // so the keystroke keeps typing what it types.
        await pressS(tester, [
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.altRight,
        ]);
        expect(find.byKey(const ValueKey('folder-browser')), findsNothing);
        expect(workspace.folders.isOpen, isTrue);

        await pressS(tester, [
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.altLeft,
        ]);
        expect(find.byKey(const ValueKey('folder-browser')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.windows,
      }),
    );

    testWidgets('⌃⌘S toggles the sidebar on macOS', (tester) async {
      await workspace.folders.openLocal(root);
      await mount(tester);
      await pressS(tester, [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]);
      expect(find.byKey(const ValueKey('folder-browser')), findsNothing);
      expect(workspace.folders.isOpen, isTrue);
      await pressS(tester, [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]);
      expect(find.byKey(const ValueKey('folder-browser')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets(
      'the browser header button hides, the tab strip button shows',
      (tester) async {
        final platform = debugDefaultTargetPlatformOverride!;
        final hide = _sidebarTooltip('Hide', platform);
        final show = _sidebarTooltip('Show', platform);
        await workspace.folders.openLocal(root);
        await mount(tester);
        expect(find.byTooltip(hide), findsOneWidget);
        await tester.tap(find.byTooltip(hide));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('folder-browser')), findsNothing);
        expect(find.byTooltip(show), findsOneWidget);
        expect(find.byTooltip(hide), findsNothing);
        await tester.tap(find.byTooltip(show));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('folder-browser')), findsOneWidget);
        // With no folder workspace there is nothing to show or hide.
        await tester.tap(find.byTooltip('Close folder workspace'));
        await tester.pumpAndSettle();
        expect(find.byTooltip(show), findsNothing);
        expect(find.byTooltip(hide), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }),
    );

    testWidgets(
      'a hidden remote workspace keeps its channel; closing drops it',
      (tester) async {
        final files = _ChannelFiles(root);
        final remote = DocumentWorkspace(
          store: MemoryDocuments(),
          dialogs: FakeDialogs(),
          folders: FolderWorkspace(localFileSystem: files),
        );
        addTearDown(remote.dispose);
        await remote.folders.openRemote(
          _server,
          files,
          const _NeverStatusStream(),
          root: '/home/user/sites',
        );
        await mount(tester, into: remote);
        expect(find.byKey(const ValueKey('folder-browser')), findsOneWidget);

        await tester.tap(find.text('View'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hide Sidebar'));
        await tester.pumpAndSettle();
        expect(files.closes, 0);
        expect(remote.folders.isOpen, isTrue);
        expect(remote.folders.server, same(_server));

        await tester.tap(find.text('File'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Close Folder Workspace'));
        await tester.pumpAndSettle();
        expect(files.closes, 1);
        expect(remote.folders.isOpen, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.windows,
      }),
    );

    testWidgets(
      'arrow keys resize the sidebar and settle the width into settings',
      (tester) async {
        final store = MemorySettings();
        final settings = SettingsController(store: store);
        addTearDown(settings.dispose);
        await workspace.folders.openLocal(root);
        await mount(tester, settings: settings);
        final browser = find.byKey(const ValueKey('folder-browser'));
        expect(tester.getSize(browser).width, 300);

        await focusResizeHandle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(tester.getSize(browser).width, 332);
        await settings.flush();
        expect(settings.value.sidebarWidth, 332);
        // The drag path settles the same way, through the same callback.
        await tester.drag(
          find.byKey(const ValueKey('workspace-divider')),
          const Offset(-40, 0),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(browser).width, lessThan(332));
        await settings.flush();
        expect(settings.value.sidebarWidth, lessThan(332));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.windows,
      }),
    );

    testWidgets(
      'the split view clamps steps to the window and to the browser minimum',
      (tester) async {
        // Inert panes: the editor's real status bar overflows below its
        // own minimum, which is the editor's affair, not the split's.
        final settled = <double>[];
        await tester.binding.setSurfaceSize(const Size(700, 400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: WorkspaceSplitView(
              browser: const SizedBox.expand(key: ValueKey('split-browser')),
              editor: const SizedBox.expand(),
              initialBrowserWidth: 300,
              onBrowserWidthSettled: settled.add,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final browser = find.byKey(const ValueKey('split-browser'));
        expect(tester.getSize(browser).width, 300);

        await focusResizeHandle(tester);
        for (var i = 0; i < 20; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
        }
        await tester.pumpAndSettle();
        // 700 - 240 editor reserve - 1 seam.
        expect(tester.getSize(browser).width, 459);
        expect(settled.last, 459);

        for (var i = 0; i < 35; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(tester.getSize(browser).width, 160);
        expect(settled.last, 160);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({TargetPlatform.linux}),
    );

    testWidgets('the first resize step starts from the visible width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(700, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final settled = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspaceSplitView(
            browser: const SizedBox.expand(key: ValueKey('split-browser')),
            editor: const SizedBox.expand(),
            initialBrowserWidth: 800,
            onBrowserWidthSettled: settled.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final browser = find.byKey(const ValueKey('split-browser'));
      expect(tester.getSize(browser).width, 459);

      await focusResizeHandle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(tester.getSize(browser).width, 443);
      expect(settled, [443]);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('a narrow window stacks the browser without a handle', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(380, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspaceSplitView(
            browser: const SizedBox.expand(key: ValueKey('split-browser')),
            editor: const SizedBox.expand(key: ValueKey('split-editor')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GhostResizeHandle), findsNothing);
      expect(find.byKey(const ValueKey('split-browser')), findsOneWidget);
      expect(find.byKey(const ValueKey('split-editor')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('sidebar visibility and width persist into a new window', (
      tester,
    ) async {
      final store = MemorySettings();
      final first = SettingsController(store: store);
      addTearDown(first.dispose);
      await workspace.folders.openLocal(root);
      await mount(tester, settings: first);

      await focusResizeHandle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip(_sidebarTooltip('Hide', TargetPlatform.linux)),
      );
      await tester.pumpAndSettle();
      await first.flush();

      // A relaunch reads what the session left: hidden, and the width
      // the resize settled on.
      final revived = SettingsController(store: store);
      addTearDown(revived.dispose);
      await revived.load();
      expect(revived.value.sidebarVisible, isFalse);
      expect(revived.value.sidebarWidth, 332);

      final fresh = DocumentWorkspace(
        store: MemoryDocuments(),
        dialogs: FakeDialogs(),
        folders: FolderWorkspace(localFileSystem: _Files(root)),
      );
      addTearDown(fresh.dispose);
      await fresh.folders.openLocal(root);
      await tester.pumpWidget(
        PlanchetteApp(workspace: fresh, settings: revived),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('folder-browser')), findsNothing);

      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show Sidebar'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('folder-browser'))).width,
        332,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
  });
}
