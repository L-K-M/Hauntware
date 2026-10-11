import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_file_ops.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/batch_rename_command.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_context_menu.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_app_transfer_queue.dart';
import '../../support/test_panes.dart';

class _NoContext extends Fake implements BuildContext {}

RemoteFileEntry _file(String name, {String folder = '/home/tester'}) =>
    RemoteFileEntry(
      path: '$folder/$name',
      name: name,
      type: RemoteFileType.file,
      size: 3,
    );

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController pane;
  late PaneController other;
  late WorkspaceController workspace;
  late bool available;
  late List<PaneController> opened;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    pane = PaneController(paneTabId: 'pane.left', lanes: lanes);
    other = PaneController(paneTabId: 'pane.right', lanes: lanes);
    workspace = WorkspaceController(
      left: testPaneStrip(pane),
      right: testPaneStrip(other),
    );
    available = true;
    opened = [];
  });

  tearDown(() => workspace.dispose());

  Future<void> bind() async {
    lanes.nextLocalChannel = controller_test.FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_file('a.txt'), _file('b.txt')];
    await pane.openLocalHome();
    await pumpEventQueue();
    lanes.nextLocalChannel = controller_test.FakePaneChannel('/tmp')
      ..listings['/tmp'] = const [];
    await other.openLocalAt('/tmp');
    await pumpEventQueue();
  }

  void selectBoth() {
    pane.setCursorIndex(0);
    pane.setCursorIndex(1, update: SelectionUpdate.toggle);
  }

  RegisteredCommand command() => buildBatchRenameCommand(
    workspace: workspace,
    available: () => available,
    open: (_, pane) => opened.add(pane),
  );

  test('registers a File menu row between Rename and Duplicate', () {
    final l10n = AppLocalizationsEn();
    final rename = command();
    expect(rename.id, kFileBatchRenameCommandId);
    expect(rename.label(l10n), 'Rename Items…');
    expect(rename.scope, CommandScope.selection);
    expect(rename.activators, isNull);
    expect(rename.menuPlacement?.menu, AppMenuId.file);
    expect(rename.menuPlacement?.group, 2);
    expect(rename.menuPlacement?.order, 71);
  });

  test('the row context menu offers it right after Rename', () {
    final section = kPaneRowContextMenu.firstWhere(
      (section) => section.contains(kFileRenameCommandId),
    );
    expect(
      section.indexOf(kFileBatchRenameCommandId),
      section.indexOf(kFileRenameCommandId) + 1,
    );
  });

  test('enablement and reasons follow the selection and the gates', () async {
    final l10n = AppLocalizationsEn();
    expect(command().enabled(), isFalse);
    expect(command().disabledReason!(l10n), 'Requires a browsed folder');

    await bind();
    workspace.setActivePane(workspace.left);
    pane.setCursorIndex(0);
    expect(command().enabled(), isFalse);
    expect(
      command().disabledReason!(l10n),
      'Select two or more items. To rename one item, use Rename.',
    );

    selectBoth();
    expect(command().enabled(), isTrue);

    available = false;
    expect(command().enabled(), isFalse);
    expect(
      command().disabledReason!(l10n),
      'Unavailable while another command is running',
    );
    available = true;

    pane.startRename();
    expect(command().enabled(), isFalse);
    expect(
      command().disabledReason!(l10n),
      'Finish the open rename or permissions change first.',
    );
  });

  test('runs on the tab active at run time', () async {
    await bind();
    workspace.setActivePane(workspace.left);
    selectBoth();
    await command().run(_NoContext());
    expect(opened, [same(pane)]);
  });

  test('an open Rename Items closes the file verbs on its rows', () async {
    await bind();
    workspace.setActivePane(workspace.left);
    selectBoth();
    final queue = FakeAppTransferQueue();
    addTearDown(queue.close);
    final fileOps = PaneFileOps(queue);
    final shell = buildShellCommands(
      workspace: workspace,
      dropDelegate: () => null,
      openConnect: () async {},
      allCommands: () => const [],
      openUrl: (_) async {},
      fileOps: () => fileOps,
      reportFailure: (_) {},
      locationLabel: (_) => '',
    );
    RegisteredCommand shellCommand(String id) =>
        shell.singleWhere((candidate) => candidate.id == id);

    final gated = [
      kFileDeleteCommandId,
      kFileDeletePermanentlyCommandId,
      kFileDuplicateCommandId,
    ];
    for (final id in gated) {
      expect(shellCommand(id).enabled(), isTrue, reason: id);
    }

    expect(pane.startBatchRename(), isTrue);
    for (final id in gated) {
      expect(shellCommand(id).enabled(), isFalse, reason: id);
    }

    pane.closeBatchRename();
    for (final id in gated) {
      expect(shellCommand(id).enabled(), isTrue, reason: id);
    }
  });

  test('inline Rename waits while Rename Items is open', () async {
    final l10n = AppLocalizationsEn();
    await bind();
    workspace.setActivePane(workspace.left);
    selectBoth();
    RegisteredCommand rename() => buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    ).firstWhere((c) => c.id == kFileRenameCommandId);
    expect(rename().enabled(), isTrue);

    pane.startBatchRename();
    expect(rename().enabled(), isFalse);
    expect(
      rename().disabledReason!(l10n),
      'Finish the open rename or permissions change first.',
    );
  });
}
