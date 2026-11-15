// P4-21 (decision Q5): Edit ▸ Cut, Copy and Paste over the app-internal
// file clipboard, their chords and context-menu rows, the dimmed cut
// rows, and the Edit ▸ Undo entries the file operations record — through
// the registered commands, real pane controllers and the scripted queue.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart' show GhostUndoHistory;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/file_clipboard.dart';
import 'package:poltergeist_app/services/file_operations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_app/services/pane_file_ops.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/menus/edit_history_commands.dart';
import 'package:poltergeist_app/ui/panes/file_clipboard_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart'
    show FakePaneChannel, FakePaneLanes;
import '../../support/fake_app_transfer_queue.dart';
import '../../support/test_panes.dart';

RemoteFileEntry _file(String dir, String name) => RemoteFileEntry(
  path: '$dir/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakePaneLanes lanes;
  late PaneController left;
  late PaneController right;
  late PaneTabsController leftStrip;
  late WorkspaceController workspace;
  late FakeAppTransferQueue queue;
  late GhostUndoHistory history;
  late FileClipboard clipboard;
  late FileOperations operations;
  late List<RegisteredCommand> commands;
  late FakePaneChannel leftChannel;
  late FakePaneChannel rightChannel;
  late FocusNode leftNode;

  setUp(() async {
    lanes = FakePaneLanes();
    left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    leftStrip = testPaneStrip(left);
    workspace = WorkspaceController(
      left: leftStrip,
      right: testPaneStrip(right),
    );
    queue = FakeAppTransferQueue();
    history = GhostUndoHistory();
    clipboard = FileClipboard();
    leftNode = FocusNode();
    final l10n = lookupAppLocalizations(const Locale('en'));
    operations = FileOperations(
      history: history,
      clipboard: clipboard,
      delegate: () => PaneDropDelegate(queue: queue),
      hostChannel: (host) => fileHostChannelIn(workspace, host),
      confirmCopyUndo: (_, _) async => true,
      hostLabel: (_) => 'this Mac',
      strings: () => l10n,
    );
    final ops = PaneFileOps(queue);
    commands = [
      ...buildEditHistoryCommands(
        history: history,
        blockedUndoName: () => operations.blockedUndoName,
      ),
      ...buildFileClipboardCommands(
        workspace: workspace,
        clipboard: clipboard,
        operations: operations,
        reportFailure: (error) => fail('$error'),
      ),
      ...buildShellCommands(
        workspace: workspace,
        dropDelegate: () => PaneDropDelegate(queue: queue),
        openConnect: () async {},
        allCommands: () => commands,
        openUrl: (_) async {},
        fileOps: () => ops,
        fileOperations: operations,
        reportFailure: (error) => fail('$error'),
        locationLabel: (_) => 'this Mac',
      ),
    ];

    leftChannel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [
        _file('/home/tester', 'a.txt'),
        _file('/home/tester', 'b.txt'),
      ];
    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();
    rightChannel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_file('/home/tester', 'b.txt')]
      ..listings['/srv/drop'] = [_file('/srv/drop', 'old.txt')];
    lanes.nextLocalChannel = rightChannel;
    await right.openLocalHome();
    right.navigate('/srv/drop');
    await _settle();
  });

  tearDown(() async {
    workspace.dispose();
    leftNode.dispose();
    await queue.close();
  });

  RegisteredCommand command(String id) =>
      commands.singleWhere((command) => command.id == id);

  AppLocalizations l10n() => lookupAppLocalizations(const Locale('en'));

  void select(PaneController pane, int index) =>
      pane.setCursorIndex(index, update: SelectionUpdate.toggle);

  /// Runs [id] with a mounted context, as the shell's runner does.
  Future<void> run(WidgetTester tester, String id) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await command(id).run(context);
    await tester.pump();
  }

  test('the chords are the platform\'s Cut, Copy and Paste', () {
    final expected = {
      kEditCutFilesCommandId: LogicalKeyboardKey.keyX,
      kEditCopyFilesCommandId: LogicalKeyboardKey.keyC,
      kEditPasteFilesCommandId: LogicalKeyboardKey.keyV,
    };
    for (final MapEntry(key: id, value: key) in expected.entries) {
      String describe(TargetPlatform platform) => [
        for (final activator in command(id).activators!(platform))
          if (activator case final SingleActivator single)
            '${single.trigger.keyLabel}'
                '${single.meta ? '+meta' : ''}'
                '${single.control ? '+control' : ''}',
      ].join(',');
      expect(describe(TargetPlatform.macOS), '${key.keyLabel}+meta');
      for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
        expect(describe(platform), '${key.keyLabel}+control');
      }
      expect(command(id).menuPlacement!.menu, AppMenuId.edit);
    }
  });

  test('Cut and Copy need a selection; Paste needs a clipboard', () {
    expect(command(kEditCopyFilesCommandId).enabled(), isFalse);
    expect(command(kEditPasteFilesCommandId).enabled(), isFalse);
    expect(
      command(kEditPasteFilesCommandId).disabledReason!(l10n()),
      'Copy or cut items first.',
    );

    select(left, 0);
    expect(command(kEditCutFilesCommandId).enabled(), isTrue);
    expect(command(kEditCopyFilesCommandId).enabled(), isTrue);
  });

  testWidgets('Copy in one pane and Paste in the other queues the copy', (
    tester,
  ) async {
    select(left, 0);
    await run(tester, kEditCopyFilesCommandId);
    expect(clipboard.content!.rootPaths, ['/home/tester/a.txt']);
    expect(clipboard.content!.mode, FileClipboardMode.copy);

    workspace.setActivePane(workspace.right);
    expect(command(kEditPasteFilesCommandId).enabled(), isTrue);
    await run(tester, kEditPasteFilesCommandId);
    await tester.runAsync(_settle);

    final spec = queue.enqueuedSpecs.single;
    expect(spec.operation, TransferOperation.copy);
    expect(spec.rootPaths, ['/home/tester/a.txt']);
    expect(spec.destinationDir, '/srv/drop');
    // The destination's names were read through the pane's own channel.
    expect(rightChannel.listCalls, contains('/srv/drop'));
    expect(command(kEditUndoCommandId).label(l10n()), 'Undo Copy');
    // A copy can be pasted again.
    expect(command(kEditPasteFilesCommandId).enabled(), isTrue);
  });

  testWidgets('Paste is refused into the folder a cut item is in', (
    tester,
  ) async {
    select(left, 0);
    await run(tester, kEditCutFilesCommandId);

    expect(command(kEditPasteFilesCommandId).enabled(), isFalse);
    expect(
      command(kEditPasteFilesCommandId).disabledReason!(l10n()),
      "These items can't be pasted into this folder.",
    );
  });

  testWidgets('a cut row is dimmed until the paste', (tester) async {
    select(left, 1);
    await run(tester, kEditCutFilesCommandId);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: FileClipboardScope(
            clipboard: clipboard,
            child: PaneView(
              controller: left,
              pane: leftStrip,
              workspace: workspace,
              focusNode: leftNode,
              onSwapFocus: () {},
              onCancelRecovery: () {},
              commands: commands,
              onRunCommand: (command) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    double opacityOf(String name) {
      final opacity = find.ancestor(
        of: find.text(name),
        matching: find.byType(Opacity),
      );
      if (opacity.evaluate().isEmpty) return 1;
      return tester.widget<Opacity>(opacity.first).opacity;
    }

    expect(opacityOf('b.txt'), kCutRowOpacity);
    expect(opacityOf('a.txt'), 1);

    clipboard.clear();
    await tester.pump();
    expect(opacityOf('b.txt'), 1);
  });

  testWidgets('the row menu offers Cut, Copy and Paste; the empty-area menu '
      'Paste', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PaneView(
            controller: left,
            pane: leftStrip,
            workspace: workspace,
            focusNode: leftNode,
            onSwapFocus: () {},
            onCancelRecovery: () {},
            commands: commands,
            onRunCommand: (command) async {},
          ),
        ),
      ),
    );
    await tester.pump();

    Future<void> rightClick(Offset at) async {
      final gesture = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await rightClick(tester.getCenter(find.text('a.txt')));
    for (final id in [
      kEditCutFilesCommandId,
      kEditCopyFilesCommandId,
      kEditPasteFilesCommandId,
    ]) {
      expect(find.byKey(ValueKey('pane.context.$id')), findsOneWidget);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await rightClick(const Offset(600, 700));
    expect(
      find.byKey(const ValueKey('pane.context.$kEditPasteFilesCommandId')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('pane.context.$kEditCutFilesCommandId')),
      findsNothing,
    );
  });

  test('the clipboard chords stay with a focused text field', () {
    final cut = command(kEditCutFilesCommandId);
    expect(
      keyMayRunFrom(
        cut,
        const SingleActivator(LogicalKeyboardKey.keyX, control: true),
        null,
      ),
      isTrue,
    );
  });

  testWidgets('a local Move to Trash records Undo Move to Trash', (
    tester,
  ) async {
    select(left, 0);
    await run(tester, kFileDeleteCommandId);
    await tester.runAsync(_settle);

    expect(queue.enqueuedDeletes.single.disposition, DeleteDisposition.trash);
    expect(command(kEditUndoCommandId).label(l10n()), 'Undo Move to Trash');
    expect(command(kEditUndoCommandId).enabled(), isTrue);
  });

  test('a delete that cannot be undone says so in the menu', () {
    operations.recordIrreversibleDelete();

    final undo = command(kEditUndoCommandId);
    expect(undo.label(l10n()), "Can't Undo Delete");
    expect(undo.enabled(), isFalse);
    expect(
      undo.disabledReason!(l10n()),
      "Items deleted on a server, or deleted immediately, can't be restored.",
    );
  });

  test('an inline rename reports itself for Undo', () async {
    final renames = <(String, String)>[];
    left.onEntryRenamed = (location, from, to) => renames.add((from, to));
    left.setCursorIndex(0);
    left.startRename();
    await left.submitRename('c.txt');
    await _settle();

    expect(leftChannel.renameCalls.single, (
      '/home/tester/a.txt',
      '/home/tester/c.txt',
    ));
    expect(renames.single, ('/home/tester/a.txt', '/home/tester/c.txt'));
  });

  test('Undo of a same-host rename goes through a live tab', () async {
    operations.recordRename(
      const LocalFsLocation(),
      '/home/tester/a.txt',
      '/home/tester/c.txt',
    );

    await history.undo();

    expect(leftChannel.renameCalls.single, (
      '/home/tester/c.txt',
      '/home/tester/a.txt',
    ));
  });
}
