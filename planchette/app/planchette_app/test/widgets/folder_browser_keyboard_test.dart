import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/ghost_fonts.dart' show ghostMonoFontFamily;
import 'package:ghost_ui/ghost_ui.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/services/folder_workspace.dart';
import 'package:planchette_app/widgets/folder_browser.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

class _Files extends LocalFileSystem {
  final listings = <String, List<RemoteFileEntry>>{};
  @override
  Future<String> canonicalize(String path) async => path;
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async =>
      listings[path] ?? [];
}

void main() {
  late _Files files;
  late FolderWorkspace workspace;
  late String root;
  final opened = <String>[];
  setUp(() {
    root = paths.join(Directory.systemTemp.path, 'keyboard-workspace');
    files = _Files();
    files.listings[root] = [
      RemoteFileEntry(
        path: paths.join(root, 'empty'),
        name: 'empty',
        type: RemoteFileType.directory,
      ),
      for (var i = 0; i < 100; i++)
        RemoteFileEntry(
          path: paths.join(root, 'file$i'),
          name: 'file$i',
          type: RemoteFileType.file,
        ),
    ];
    workspace = FolderWorkspace(localFileSystem: files);
    opened.clear();
  });
  tearDown(() => workspace.dispose());

  Future<void> mount(WidgetTester tester, {bool enabled = true}) async {
    await workspace.openLocal(root);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: ListenableBuilder(
              listenable: workspace,
              builder: (_, _) => FolderBrowser(
                workspace: workspace,
                enabled: enabled,
                onToggleSidebar: () {},
                onOpen: (entry) => opened.add(entry.path),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> focus(WidgetTester tester) async {
    final node = tester
        .widgetList<Focus>(find.byType(Focus))
        .firstWhere((focus) => focus.focusNode?.debugLabel == 'Workspace files')
        .focusNode!;
    node.requestFocus();
    await tester.pump();
  }

  String selected(WidgetTester tester) => tester
      .widgetList<GhostFileRow>(find.byType(GhostFileRow))
      .singleWhere((row) => row.selected)
      .item
      .name;

  testWidgets(
    'Up from no cursor selects last and reveals it; Home returns to first',
    (tester) async {
      await mount(tester);
      await focus(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(selected(tester), 'file99');
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(selected(tester), 'empty');
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      expect(selected(tester), isNot('empty'));
      expect(opened, isEmpty);
    },
  );

  testWidgets('Mac open and parent work even when a folder is empty', (
    tester,
  ) async {
    await mount(tester);
    await focus(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(workspace.path, paths.join(root, 'empty'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(workspace.path, root);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('path header draws the bundled mono stack', (tester) async {
    await mount(tester);
    final header = tester.widget<Text>(find.text(workspace.displayPath));
    expect(header.style?.fontFamily, ghostMonoFontFamily);
    expect(header.style?.fontSize, 12);
  });

  testWidgets('disabled browser ignores selection movement', (tester) async {
    await mount(tester, enabled: false);
    await focus(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      tester
          .widgetList<GhostFileRow>(find.byType(GhostFileRow))
          .where((row) => row.selected),
      isEmpty,
    );
    expect(opened, isEmpty);
  });
}
