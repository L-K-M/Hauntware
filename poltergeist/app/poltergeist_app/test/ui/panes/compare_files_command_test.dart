import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/pane_comparison.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/family_hues.dart';
import 'package:poltergeist_app/ui/panes/compare_files_command.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_context_menu.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

class _NoContext extends Fake implements BuildContext {}

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController pane;
  late WorkspaceController workspace;
  late bool available;
  late List<PaneComparison> opened;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    pane = PaneController(paneTabId: 'pane.left', lanes: lanes);
    workspace = WorkspaceController(
      left: testPaneStrip(pane),
      right: testPaneStrip(
        PaneController(paneTabId: 'pane.right', lanes: lanes),
      ),
    );
    available = true;
    opened = [];
  });

  tearDown(() => workspace.dispose());

  Future<void> bindLocal() async {
    lanes.nextLocalChannel = controller_test.FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = const [
        RemoteFileEntry(
          path: '/home/tester/a.txt',
          name: 'a.txt',
          type: RemoteFileType.file,
          size: 3,
        ),
        RemoteFileEntry(
          path: '/home/tester/b.txt',
          name: 'b.txt',
          type: RemoteFileType.file,
          size: 4,
        ),
      ];
    await pane.openLocalHome();
    await pumpEventQueue();
  }

  RegisteredCommand command() => buildCompareFilesCommand(
    workspace: workspace,
    available: () => available,
    open: (_, comparison) => opened.add(comparison),
  );

  test('registers a File menu row beside Preview', () {
    final l10n = AppLocalizationsEn();
    final compare = command();

    expect(compare.id, kFileCompareFilesCommandId);
    expect(compare.label(l10n), 'Compare Files');
    expect(compare.scope, CommandScope.selection);
    expect(compare.hue, FamilyHue.indigo);
    expect(compare.activators, isNull);
    expect(compare.menuPlacement?.menu, AppMenuId.file);
    expect(compare.menuPlacement?.group, 1);
    expect(compare.menuPlacement?.order, 69);
    expect(
      compare.disabledReason!(l10n),
      'Requires one file selected in each pane, or two in the focused pane',
    );
  });

  test('the row context menu offers it after Preview', () {
    final first = kPaneRowContextMenu.first;
    expect(
      first.indexOf(kFileCompareFilesCommandId),
      first.indexOf(kFilePreviewCommandId) + 1,
    );
  });

  test('enablement follows the selection and the shell gate', () async {
    await bindLocal();
    expect(command().enabled(), isFalse);

    pane.setCursorIndex(0);
    expect(command().enabled(), isFalse);

    pane.setCursorIndex(1, update: SelectionUpdate.toggle);
    expect(command().enabled(), isTrue);

    available = false;
    expect(command().enabled(), isFalse);
  });

  test('runs with the selection resolved at run time', () async {
    await bindLocal();
    final compare = command();

    await compare.run(_NoContext());
    expect(opened, isEmpty);

    pane.setCursorIndex(0);
    pane.setCursorIndex(1, update: SelectionUpdate.toggle);
    await compare.run(_NoContext());

    expect(opened, hasLength(1));
    expect(opened.single.request.left.fullPath, '/home/tester/a.txt');
    expect(opened.single.request.right.fullPath, '/home/tester/b.txt');
  });
}
