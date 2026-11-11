import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show GhostCommandRow, GhostUndoableChange, formatShortcutActivator;
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/ui/app_commands.dart';
import 'package:seance_core/seance_core.dart'
    show ProbeService, UpdateChecker, UpdateInfo;

/// An update check whose answer the test scripts and whose calls it records.
class _ScriptedChecker extends UpdateChecker {
  _ScriptedChecker(this.answer);

  final Future<UpdateInfo?> Function(String version) answer;
  final calls = <String>[];

  @override
  Future<UpdateInfo?> check(String currentVersion) {
    calls.add(currentVersion);
    return answer(currentVersion);
  }
}

/// The least [AppState] needs: its settings, the save they call, and the
/// probe service its dispose touches.
class _Services implements AppServices {
  @override
  final AppSettings settings = AppSettings();

  @override
  final ProbeService probe = ProbeService();

  @override
  Future<void> saveSettings() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppState _state() => AppState(_Services());

SeanceCommand _command(List<SeanceCommand> commands, String id) =>
    commands.firstWhere((command) => command.id == id);

/// The command ids in [commands], for the menu-content assertions.
List<String> _ids(List<SeanceCommand> commands) => [
  for (final command in commands) command.id,
];

/// The app's menu and palette model (`seanceCommands` and its adapters):
/// one resolved snapshot for the ☰ menus, the palette and the tests, so
/// rows, shortcuts and enablement cannot drift between them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'macOS lists every menu with its labels, checked rows and enablement',
    () {
      final state = _state();
      addTearDown(state.dispose);
      final commands = seanceCommands(state, TargetPlatform.macOS, wide: true);

      expect(_ids(commands), [
        'file.newTab',
        'file.settings',
        'edit.undo',
        'edit.redo',
        'edit.findInEditor',
        'view.sidebar',
        'view.inspector',
        'view.files',
        'view.context',
        'view.git',
        'view.snippets',
        'view.assistant',
        'view.filterServers',
        'view.commandPalette',
        'terminal.generateCommand',
        'help.keyboardShortcuts',
        'help.checkForUpdates',
      ]);

      expect(_command(commands, 'file.newTab').enabled, isFalse);
      expect(_command(commands, 'edit.undo').label, 'Undo');
      expect(_command(commands, 'edit.undo').enabled, isFalse);
      expect(_command(commands, 'edit.redo').label, 'Redo');
      expect(_command(commands, 'edit.findInEditor').enabled, isFalse);
      expect(_command(commands, 'view.sidebar').label, 'Hide Sidebar');
      expect(_command(commands, 'view.sidebar').checked, isTrue);
      expect(_command(commands, 'view.inspector').label, 'Hide Inspector');
      expect(_command(commands, 'view.inspector').checked, isTrue);
      expect(_command(commands, 'view.files').label, 'Show Files');
      expect(_command(commands, 'view.assistant').label, 'Show Assistant');
      expect(
        _command(commands, 'view.commandPalette').label,
        'Command Palette…',
      );
      expect(
        _command(commands, 'terminal.generateCommand').label,
        'Generate Command…',
      );
      expect(
        _command(commands, 'help.keyboardShortcuts').label,
        'Keyboard Shortcuts',
      );
      expect(
        _command(commands, 'help.checkForUpdates').label,
        'Check for Updates…',
      );
      // macOS keeps AppKit's own About in the application menu.
      expect(commands.where((command) => command.id == 'help.about'), isEmpty);
    },
  );

  test('a recorded change names the Undo and Redo rows and enables them', () {
    final state = _state();
    addTearDown(state.dispose);
    state.undoHistory.record(
      GhostUndoableChange(
        name: 'Pin to top',
        undo: () async {},
        redo: () async {},
      ),
    );

    final commands = seanceCommands(state, TargetPlatform.macOS, wide: true);
    expect(_command(commands, 'edit.undo').label, 'Undo Pin to top');
    expect(_command(commands, 'edit.undo').enabled, isTrue);
    expect(_command(commands, 'edit.redo').label, 'Redo');
    expect(_command(commands, 'edit.redo').enabled, isFalse);
  });

  test('the pane toggles follow the settings and the narrow posture drops '
      'the pane group', () {
    final state = _state();
    addTearDown(state.dispose);
    state.services.settings.sidebarHidden = true;

    final wide = seanceCommands(state, TargetPlatform.macOS, wide: true);
    expect(_command(wide, 'view.sidebar').label, 'Show Sidebar');
    expect(_command(wide, 'view.sidebar').checked, isFalse);

    final narrow = seanceCommands(state, TargetPlatform.macOS, wide: false);
    expect(
      _ids(narrow),
      isNot(containsAll(['view.sidebar', 'view.inspector', 'view.files'])),
    );
    // The narrow posture has no panes, but keeps the commands that do not
    // need them.
    expect(
      _ids(narrow),
      containsAll(['view.filterServers', 'view.commandPalette']),
    );
  });

  test('Linux and Windows carry About Séance; macOS does not', () {
    final state = _state();
    addTearDown(state.dispose);
    expect(
      _ids(seanceCommands(state, TargetPlatform.linux, wide: true)),
      contains('help.about'),
    );
    expect(
      _ids(seanceCommands(state, TargetPlatform.windows, wide: true)),
      contains('help.about'),
    );
    expect(
      _ids(seanceCommands(state, TargetPlatform.macOS, wide: true)),
      isNot(contains('help.about')),
    );
  });

  test('the palette chords are the sibling apps\', per platform', () {
    final state = _state();
    addTearDown(state.dispose);

    final apple = seanceCommands(state, TargetPlatform.macOS, wide: true);
    expect(
      formatShortcutActivator(
        _command(apple, 'view.commandPalette').activators.single,
        TargetPlatform.macOS,
      ),
      '⇧⌘P',
    );
    expect(
      formatShortcutActivator(
        _command(apple, 'help.keyboardShortcuts').activators.single,
        TargetPlatform.macOS,
      ),
      '⌘/',
    );

    final linux = seanceCommands(state, TargetPlatform.linux, wide: true);
    expect(
      formatShortcutActivator(
        _command(linux, 'view.commandPalette').activators.single,
        TargetPlatform.linux,
      ),
      'Ctrl+Shift+P',
    );
    expect(
      formatShortcutActivator(
        _command(linux, 'help.keyboardShortcuts').activators.single,
        TargetPlatform.linux,
      ),
      'Ctrl+/',
    );
  });

  testWidgets('the menus group their rows under the bar titles', (
    tester,
  ) async {
    final state = _state();
    addTearDown(state.dispose);
    final menus = seanceMenus(
      seanceCommands(state, TargetPlatform.macOS, wide: true),
    );

    expect(
      [for (final menu in menus) menu.title],
      ['File', 'Edit', 'View', 'Terminal', 'Help'],
    );
    final view = menus.firstWhere((menu) => menu.title == 'View');
    // The pane toggles, then the inspector pages, then the filter and the
    // palette: three divider-separated groups.
    expect(view.groups, hasLength(3));
    expect(
      view.groups[0]
          .map((row) => (row as GhostCommandRow).command.label)
          .toList(),
      ['Hide Sidebar', 'Hide Inspector'],
    );
  });

  testWidgets('palette rows carry their path, chord and enablement, and '
      'leave out the palette itself', (tester) async {
    final state = _state();
    addTearDown(state.dispose);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(MaterialApp));

    final rows = seancePaletteCommands(
      context,
      state,
      seanceCommands(state, TargetPlatform.macOS, wide: true),
    );
    expect(rows, isNotEmpty);
    expect(rows.where((row) => row.label == 'Command Palette…'), isEmpty);

    final undo = rows.firstWhere((row) => row.label == 'Undo');
    expect(undo.path, 'Edit');
    expect(undo.enabled, isFalse);

    final sidebar = rows.firstWhere((row) => row.label == 'Hide Sidebar');
    expect(sidebar.path, 'View');
    expect(sidebar.enabled, isTrue);
    expect(
      formatShortcutActivator(sidebar.shortcut!, TargetPlatform.macOS),
      '⌃⌘S',
    );
  });

  test('checkNow runs while the launch check is opted out and stores the '
      'release it finds', () async {
    final checker = _ScriptedChecker(
      (_) async => UpdateInfo(
        latestVersion: '1.10.0',
        releasesUrl: Uri.parse('https://example.com/releases'),
      ),
    );
    final state = AppState(_Services(), updateChecker: checker);
    addTearDown(state.dispose);
    state.services.settings.checkForUpdates = false;
    state.appVersion = '1.9.1';

    final info = await state.checkNow('1.9.1');
    expect(checker.calls, ['1.9.1']);
    expect(info?.latestVersion, '1.10.0');
    expect(state.updateInfo?.latestVersion, '1.10.0');
  });

  test(
    'checkNow leaves the banner alone when the check finds nothing',
    () async {
      final checker = _ScriptedChecker((_) async => null);
      final state = AppState(_Services(), updateChecker: checker);
      addTearDown(state.dispose);

      expect(await state.checkNow('1.9.1'), isNull);
      expect(state.updateInfo, isNull);
    },
  );

  testWidgets('the manual check says no newer version was found, never "up to '
      'date"', (tester) async {
    final state = AppState(
      _Services(),
      updateChecker: _ScriptedChecker((_) async => null),
    );
    addTearDown(state.dispose);
    state.appVersion = '1.9.1';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => runCheckForUpdates(context, state),
              child: const Text('Check'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.text(
        'No newer version was found. If you’re offline, try again later.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('up to date'), findsNothing);
  });

  testWidgets('the manual check announces the release and links to it', (
    tester,
  ) async {
    final state = AppState(
      _Services(),
      updateChecker: _ScriptedChecker(
        (_) async => UpdateInfo(
          latestVersion: '1.10.0',
          releasesUrl: Uri.parse('https://example.com/releases'),
        ),
      ),
    );
    addTearDown(state.dispose);
    state.appVersion = '1.9.1';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => runCheckForUpdates(context, state),
              child: const Text('Check'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Séance 1.10.0 is available.'), findsOneWidget);
    expect(find.text('View release'), findsOneWidget);
  });
}
