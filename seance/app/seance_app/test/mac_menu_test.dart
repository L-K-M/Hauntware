import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart' show GhostUndoableChange;
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart' show AppScope, navigatorKey;
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/adaptive_shell.dart';
import 'package:seance_app/ui/app_menus.dart';
import 'package:seance_app/ui/built_in_text_editor.dart';
import 'package:seance_app/ui/server_list_density.dart';
import 'package:seance_core/seance_core.dart' show ServerConfig;

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The Dart half of the native macOS menu (MainFlutterWindow.swift): what
/// its items do when they call in, and what Dart tells it back. The native
/// half has no test host on Linux; the channel is the contract between
/// them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    await services?.probe.dispose();
    messenger
      ..setMockMethodCallHandler(_pathChannel, null)
      ..setMockMethodCallHandler(macMenuChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    state = null;
    services = null;
    directory = null;
  });

  Future<void> boot(WidgetTester tester) => tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('seance-mac-menu-');
    messenger.setMockMethodCallHandler(
      _pathChannel,
      (call) async => directory!.path,
    );
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(services!);
  });

  /// A call as the native menu item makes it.
  Future<void> fromNative(WidgetTester tester, String method) =>
      tester.runAsync(
        () => messenger.handlePlatformMessage(
          macMenuChannel.name,
          macMenuChannel.codec.encodeMethodCall(MethodCall(method)),
          (_) {},
        ),
      );

  testWidgets('View ▸ the density item flips the density, and its title '
      'always names the other choice', (tester) async {
    await boot(tester);
    final sent = <MethodCall>[];
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async {
      sent.add(call);
      return null;
    });

    installMacMenu(state!);
    // Titled before the menu can be opened: comfortable is the default.
    expect(sent, [
      isMethodCall(
        'setServerListDensityTitle',
        arguments: 'Use Compact Sidebar Rows',
      ),
    ]);

    await fromNative(tester, 'toggleServerListDensity');
    expect(state!.serverListDensity, ServerListDensity.compact);
    expect(
      services!.settings.serverListDensity,
      ServerListDensity.compact,
      reason: 'the menu persists the choice like the switches do',
    );
    expect(
      sent.last,
      isMethodCall(
        'setServerListDensityTitle',
        arguments: 'Use Comfortable Sidebar Rows',
      ),
    );

    // A switch elsewhere retitles it too; anything else the state says
    // does not.
    await tester.runAsync(
      () => state!.setServerListDensity(ServerListDensity.comfortable),
    );
    expect(
      sent.last,
      isMethodCall(
        'setServerListDensityTitle',
        arguments: 'Use Compact Sidebar Rows',
      ),
    );
    final count = sent.length;
    state!.notifyListeners();
    expect(sent, hasLength(count));
  });

  EditorTab editorTab({String id = 'motd-editor'}) => EditorTab(
    id: id,
    serverId: 'alpha',
    config: ServerConfig(
      id: 'alpha',
      label: 'alpha',
      host: 'alpha.example.com',
      username: 'deploy',
      createdAt: 1,
      updatedAt: 1,
    ),
    remotePath: '/etc/motd',
    localPath: 'motd',
    ownerEditSessionId: 'edit-session',
  );

  testWidgets('the native editor flag follows the mounted editor, not just '
      'the active tab', (tester) async {
    await boot(tester);
    final sent = <MethodCall>[];
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async {
      sent.add(call);
      return null;
    });
    installMacMenu(state!);

    final editor = editorTab();
    state!.tabs.add(editor);
    state!.focusTab(editor.id);
    await tester.pump();
    // The tab is active but its editor is not mounted: Save and Find… must
    // stay disabled.
    expect(
      sent,
      isNot(contains(isMethodCall('setEditorActive', arguments: true))),
    );

    final file = File('${directory!.path}/motd');
    await tester.runAsync(() => file.writeAsString('one\n'));
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          key: editor.editorKey,
          file: file,
          remotePath: editor.remotePath,
          initialText: 'one\n',
          mountRevision: state!.editorMountRevision,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(sent, contains(isMethodCall('setEditorActive', arguments: true)));

    // Focusing a second editor whose own editor is not mounted clears the
    // flag, even though the first editor is still mounted.
    final second = editorTab(id: 'second-editor');
    state!.tabs.add(second);
    state!.focusTab(second.id);
    await tester.pump();
    expect(sent.last, isMethodCall('setEditorActive', arguments: false));

    // Focusing the first editor again restores it: its editor is mounted.
    state!.focusTab(editor.id);
    await tester.pump();
    expect(sent.last, isMethodCall('setEditorActive', arguments: true));

    // Unmounting the active editor clears the flag without touching the
    // active tab.
    final beforeUnmount = sent.length;
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(sent.length, greaterThan(beforeUnmount));
    expect(
      sent[beforeUnmount],
      isMethodCall('setEditorActive', arguments: false),
    );

    await tester.runAsync(() async {
      state!.undoHistory.record(
        GhostUndoableChange(
          name: 'Pin to top',
          undo: () async {},
          redo: () async {},
        ),
      );
    });
    await tester.pump();
    expect(
      sent,
      contains(
        isMethodCall('setUndoItem', arguments: {
          'title': 'Undo Pin to top',
          'enabled': true,
        }),
      ),
    );
    expect(
      sent,
      contains(
        isMethodCall('setRedoItem', arguments: {
          'title': 'Redo',
          'enabled': false,
        }),
      ),
    );
  });

  testWidgets('editSave and editFind reach the mounted editor', (
    tester,
  ) async {
    await boot(tester);
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async => null);
    installMacMenu(state!);
    final editor = editorTab();
    state!.tabs.add(editor);
    state!.focusTab(editor.id);
    final file = File('${directory!.path}/motd');
    await tester.runAsync(() => file.writeAsString('one\n'));
    String? savedText;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          key: editor.editorKey,
          file: file,
          remotePath: editor.remotePath,
          initialText: 'one\n',
          saveDocument: (_, text) async => savedText = text,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await fromNative(tester, 'editSave');
    await tester.pump();
    expect(savedText, 'one\n');

    await fromNative(tester, 'editFind');
    await tester.pumpAndSettle();
    expect(find.text('Find in file'), findsOneWidget);
  });

  testWidgets('editSave and editFind no-op without an editor tab', (
    tester,
  ) async {
    await boot(tester);
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async => null);
    installMacMenu(state!);

    await fromNative(tester, 'editSave');
    await fromNative(tester, 'editFind');
  });

  testWidgets('the native palette, shortcut and update items open their '
      'surfaces', (tester) async {
    await boot(tester);
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async => null);
    installMacMenu(state!);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();

    await fromNative(tester, 'keyboardShortcuts');
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsWidgets);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await fromNative(tester, 'commandPalette');
    await tester.pumpAndSettle();
    expect(find.text('Type a command'), findsOneWidget);

    await fromNative(tester, 'checkForUpdates');
    await tester.pump();
    expect(
      find.text(
        'No newer version was found. If you’re offline, try again later.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the native palette command follows the shell posture', (
    tester,
  ) async {
    await boot(tester);
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async => null);
    installMacMenu(state!);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: SeanceTheme.light(platform: TargetPlatform.macOS),
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: const AdaptiveShell(),
      ),
    );
    await tester.pumpAndSettle();

    await fromNative(tester, 'commandPalette');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('planchette.palette.query')),
      findsOneWidget,
    );
    // The native handler's context is the root navigator, above the layout;
    // the palette must still follow the shell's narrow posture.
    expect(find.text('Hide Sidebar'), findsNothing);
    expect(find.text('Filter Servers'), findsOneWidget);
  });

  testWidgets('editUndo steps the history, or yields to a focused field', (
    tester,
  ) async {
    await boot(tester);
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async => null);
    installMacMenu(state!);
    var undone = 0;
    GhostUndoableChange change(String name) => GhostUndoableChange(
      name: name,
      undo: () async => undone++,
      redo: () async {},
    );
    state!.undoHistory.record(change('Pin to top'));
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: TextField()),
      ),
    );
    await tester.pumpAndSettle();

    await fromNative(tester, 'editUndo');
    await tester.pump();
    expect(undone, 1);
    expect(find.text('Pin to top undone'), findsOneWidget);

    state!.undoHistory.record(change('Pin to top'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'typed');
    await tester.pump();
    await fromNative(tester, 'editUndo');
    await tester.pump();
    expect(undone, 1, reason: 'the field kept the step for its own history');
  });
}
