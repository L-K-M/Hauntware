import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryDocuments store;
  late DocumentWorkspace workspace;
  late int notifications;
  setUp(() {
    store = MemoryDocuments();
    workspace = DocumentWorkspace(store: store, dialogs: FakeDialogs());
    notifications = 0;
  });
  tearDown(() => workspace.dispose());

  test('typing and caret moves notify only when the dirty state changes', () {
    final tab = workspace.newDocument()!;
    workspace.addListener(() => notifications++);

    tab.editor.text.text = 'a';
    expect(notifications, 1, reason: 'the tab became dirty');

    tab.editor.text.text = 'ab';
    tab.editor.text.selection = const TextSelection.collapsed(offset: 1);
    tab.editor.text.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 2,
    );
    expect(
      notifications,
      1,
      reason: 'still dirty; the shell draws nothing new',
    );

    tab.editor.text.text = '';
    expect(notifications, 2, reason: 'clean again');
  });

  test('background edits still update their own tab state', () {
    final first = workspace.newDocument()!;
    workspace.newDocument();
    workspace.addListener(() => notifications++);
    first.editor.text.text = 'edited while inactive';
    expect(notifications, 1);
    expect(first.editor.isDirty, isTrue);
  });

  test('a completed save and a loaded path notify the shell', () async {
    store.files[testPath('a.txt')] = document('a.txt', 'on disk');
    workspace.addListener(() => notifications++);
    await workspace.open(testPath('a.txt'));
    final tab = workspace.active!;
    expect(tab.path, testPath('a.txt'));
    expect(workspace.windowTitle, 'a.txt — Planchette');

    tab.editor.text.text = 'changed';
    expect(workspace.windowTitle, '● a.txt — Planchette');
    final before = notifications;
    expect(await workspace.save(tab), isTrue);
    expect(notifications, greaterThan(before));
    expect(workspace.windowTitle, 'a.txt — Planchette');
  });
}
