import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/services/folder_workspace.dart';
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
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(
        workspace: workspace,
        settings: testSettings(),
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
}
