import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;

void main() {
  testWidgets('the notice reloads an outside change, and undo restores edits', (
    tester,
  ) async {
    final store = MemoryDocuments();
    final workspace = DocumentWorkspace(store: store, dialogs: FakeDialogs());
    addTearDown(workspace.dispose);
    final path = testPath('notice.txt');
    store.files[path] = document('notice.txt', 'original', digest: 'v1');
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, themeMode: ThemeMode.light),
    );
    await tester.runAsync(() => workspace.open(path));
    await tester.pumpAndSettle();
    final tab = workspace.active!;

    tab.editor.text.text = 'mine';
    await tester.pump(const Duration(milliseconds: 600));
    store.files[path] = document('notice.txt', 'theirs', digest: 'v2');
    await tester.runAsync(workspace.checkDisk);
    await tester.pumpAndSettle();
    expect(find.textContaining('changed on disk'), findsOneWidget);
    expect(find.text('Keep Mine'), findsOneWidget);

    await tester.tap(find.text('Reload'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(tab.editor.text.text, 'theirs');
    expect(find.textContaining('changed on disk'), findsNothing);

    await tester.pump(const Duration(milliseconds: 600));
    tab.editor.undoController.undo();
    await tester.pump();
    expect(tab.editor.text.text, 'mine');
    expect(tab.editor.isDirty, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
