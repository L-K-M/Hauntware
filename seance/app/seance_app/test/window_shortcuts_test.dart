import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/undo_history.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/adaptive_shell.dart';
import 'package:seance_app/ui/app_menus.dart';
import 'package:seance_app/ui/header_toolbar.dart';
import 'package:seance_app/ui/inspector_page.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The window shortcuts (`windowShortcuts` in app_menus.dart) and the
/// header's pane buttons, driven through the real shell on every platform:
/// the same panes, the same buttons, each platform's chords.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  /// Everything the terminal sent its shell, in order.
  final shellInput = <String>[];

  tearDown(() async {
    state?.dispose();
    state = null;
    await services?.probe.dispose();
    services = null;
    shellInput.clear();
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

  final box = ServerConfig(
    id: 'box',
    label: 'box',
    host: 'box.example.com',
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  Future<void> settle(WidgetTester tester) async {
    // A live terminal animates indefinitely: pump fixed frames.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> startServices(WidgetTester tester) => tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('seance-window-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _pathChannel,
          (call) async => directory!.path,
        );
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(services!);
    await state!.saveServer(box);
  });

  /// The shell with one connected terminal on "box", which holds focus.
  Future<void> boot(WidgetTester tester, TargetPlatform platform) async {
    await startServices(tester);
    final engine = XtermTerminalEngine();
    engine.userInput.listen((bytes) => shellInput.add(utf8.decode(bytes)));
    state!
      ..tabs.add(
        TerminalSession(id: 'a', serverId: 'box', config: box, engine: engine)
          ..session = _OpenSshSession(engine)
          ..connecting = false,
      )
      ..activeTabId = 'a';

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: platform),
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: const AppMenus(child: AdaptiveShell()),
      ),
    );
    await settle(tester);
  }

  /// [AppMenus] over a plain focusable box and a text field, the box
  /// focused: focus outside the terminal and outside any text.
  Future<void> bootPlain(WidgetTester tester, TargetPlatform platform) async {
    await startServices(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: platform),
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: const AppMenus(
          child: Scaffold(
            body: Column(
              children: [
                Focus(autofocus: true, child: SizedBox(height: 40)),
                TextField(key: ValueKey('field')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, [
    List<LogicalKeyboardKey> modifiers = const [],
  ]) async {
    for (final modifier in modifiers) {
      await tester.sendKeyDownEvent(modifier);
    }
    await tester.sendKeyEvent(key);
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
    await settle(tester);
  }

  const ctrl = LogicalKeyboardKey.controlLeft;
  const shift = LogicalKeyboardKey.shiftLeft;
  const alt = LogicalKeyboardKey.altLeft;
  const meta = LogicalKeyboardKey.metaLeft;

  /// A change whose undo and redo only count.
  ({int undone, int redone}) counts = (undone: 0, redone: 0);
  void recordChange(String name) {
    counts = (undone: 0, redone: 0);
    state!.undoHistory.record(
      UndoableChange(
        name: name,
        undo: () async =>
            counts = (undone: counts.undone + 1, redone: counts.redone),
        redo: () async =>
            counts = (undone: counts.undone, redone: counts.redone + 1),
      ),
    );
  }

  bool listShown() =>
      find.byKey(AdaptivePaneLayout.listPaneKey).evaluate().isNotEmpty;
  bool inspectorShown() =>
      find.byKey(AdaptivePaneLayout.utilityPaneKey).evaluate().isNotEmpty;

  group('off Apple platforms', () {
    testWidgets('Ctrl+Alt+S and Ctrl+Alt+I hide and show the panes from the '
        'terminal, and the shell gets nothing', (tester) async {
      await boot(tester, TargetPlatform.linux);
      expect((listShown(), inspectorShown()), (true, true));

      await press(tester, LogicalKeyboardKey.keyS, [ctrl, alt]);
      expect(state!.sidebarVisible, isFalse);
      expect(listShown(), isFalse);
      await press(tester, LogicalKeyboardKey.keyI, [ctrl, alt]);
      expect(state!.inspectorVisible, isFalse);
      expect(inspectorShown(), isFalse);

      await press(tester, LogicalKeyboardKey.keyS, [ctrl, alt]);
      await press(tester, LogicalKeyboardKey.keyI, [ctrl, alt]);
      expect((listShown(), inspectorShown()), (true, true));
      expect(shellInput, isEmpty);

      // AltGr (Ctrl + right Alt on Windows) types ś with S on Polish
      // layouts: not a pane chord.
      await press(tester, LogicalKeyboardKey.keyS, [
        ctrl,
        LogicalKeyboardKey.altRight,
      ]);
      expect(state!.sidebarVisible, isTrue);
    });

    testWidgets('Ctrl+Alt+digit opens that inspector page, bringing the '
        'inspector back', (tester) async {
      await boot(tester, TargetPlatform.linux);
      await press(tester, LogicalKeyboardKey.keyI, [ctrl, alt]);
      expect(inspectorShown(), isFalse);

      await press(tester, LogicalKeyboardKey.digit3, [ctrl, alt]);
      expect(state!.inspectorPage, InspectorPage.snippets);
      expect(inspectorShown(), isTrue);
      await press(tester, LogicalKeyboardKey.digit2, [ctrl, alt]);
      expect(state!.inspectorPage, InspectorPage.git);
      expect(shellInput, isEmpty);
    });

    testWidgets('Ctrl+Z in the terminal stays the shell’s', (tester) async {
      await boot(tester, TargetPlatform.linux);
      recordChange('Pin to top');

      await press(tester, LogicalKeyboardKey.keyZ, [ctrl]);
      expect(shellInput.join(), '\x1a');
      expect(counts.undone, 0);
      expect(state!.undoHistory.undoName, 'Pin to top');
    });

    testWidgets('outside text, Ctrl+Z undoes the last change and says so; '
        'Ctrl+Shift+Z and Ctrl+Y redo it', (tester) async {
      await bootPlain(tester, TargetPlatform.linux);
      recordChange('Pin to top');

      await press(tester, LogicalKeyboardKey.keyZ, [ctrl]);
      expect(counts.undone, 1);
      expect(find.text('Pin to top undone'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyZ, [ctrl, shift]);
      expect(counts.redone, 1);
      await press(tester, LogicalKeyboardKey.keyZ, [ctrl]);
      await press(tester, LogicalKeyboardKey.keyY, [ctrl]);
      expect(counts.redone, 2);
      expect(find.text('Pin to top redone'), findsWidgets);
    });

    testWidgets('a text field keeps Ctrl+Z for its own history', (
      tester,
    ) async {
      await bootPlain(tester, TargetPlatform.linux);
      recordChange('Delete snippet');
      await tester.tap(find.byKey(const ValueKey('field')));
      await tester.pump();

      await press(tester, LogicalKeyboardKey.keyZ, [ctrl]);
      expect(counts.undone, 0);
      expect(state!.undoHistory.undoName, 'Delete snippet');
    });

    testWidgets('an undo the change declines says why, and stays undoable', (
      tester,
    ) async {
      await bootPlain(tester, TargetPlatform.linux);
      state!.undoHistory.record(
        UndoableChange(
          name: 'Duplicate server',
          undo: () async => throw const UndoDeclined('Close its tabs first.'),
          redo: () async {},
        ),
      );

      await press(tester, LogicalKeyboardKey.keyZ, [ctrl]);
      expect(
        find.text('Couldn’t undo “Duplicate server”: Close its tabs first.'),
        findsOneWidget,
      );
      expect(state!.undoHistory.undoName, 'Duplicate server');
    });
  });

  testWidgets('on Apple platforms: ⌃⌘S, ⌥⌘I and ⌥⌘digit from the terminal, '
      'and ⌘Z undoes there too', (tester) async {
    await boot(tester, TargetPlatform.macOS);
    recordChange('Pin to top');

    await press(tester, LogicalKeyboardKey.keyS, [ctrl, meta]);
    expect(listShown(), isFalse);
    await press(tester, LogicalKeyboardKey.keyI, [alt, meta]);
    expect(inspectorShown(), isFalse);
    await press(tester, LogicalKeyboardKey.digit4, [alt, meta]);
    expect(state!.inspectorPage, InspectorPage.assistant);
    expect(inspectorShown(), isTrue);

    // ⌘ never reaches a shell, so the app's history takes ⌘Z.
    await press(tester, LogicalKeyboardKey.keyZ, [meta]);
    expect(counts.undone, 1);
    await press(tester, LogicalKeyboardKey.keyZ, [meta, shift]);
    expect(counts.redone, 1);
    expect(shellInput, isEmpty);
  });

  for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
    testWidgets('${platform.name}: the header and the list band carry the '
        'pane buttons', (tester) async {
      await boot(tester, platform);
      expect(find.byKey(HeaderToolbar.generateCommandKey), findsOneWidget);
      expect(find.byKey(HeaderToolbar.sidebarToggleKey), findsNothing);
      expect(find.byTooltip('Hide sidebar Ctrl+Alt+S'), findsOneWidget);

      await tester.tap(find.byKey(SidebarBand.sidebarToggleKey));
      await settle(tester);
      expect(listShown(), isFalse);
      // With the list gone, the header leads with the button.
      expect(find.byKey(SidebarBand.sidebarToggleKey), findsNothing);
      expect(find.byTooltip('Show sidebar Ctrl+Alt+S'), findsOneWidget);

      await tester.tap(find.byKey(HeaderToolbar.inspectorToggleKey));
      await settle(tester);
      expect(inspectorShown(), isFalse);
      expect(find.byTooltip('Show inspector Ctrl+Alt+I'), findsOneWidget);

      await tester.tap(find.byKey(HeaderToolbar.sidebarToggleKey));
      await tester.tap(find.byKey(HeaderToolbar.inspectorToggleKey));
      await settle(tester);
      expect((listShown(), inspectorShown()), (true, true));
    });
  }

  test('no window chord is a tab chord, or bound twice', () {
    for (final platform in TargetPlatform.values) {
      final chords = [
        for (final shortcut in windowShortcuts(platform))
          shortcut.chord.debugDescribeKeys(),
        for (final shortcut in tabShortcuts(platform))
          shortcut.chord.debugDescribeKeys(),
      ];
      expect(chords.toSet(), hasLength(chords.length), reason: '$platform');
    }
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
