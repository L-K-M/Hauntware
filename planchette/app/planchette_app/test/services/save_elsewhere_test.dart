import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_core/planchette_core.dart';

import 'document_workspace_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryDocuments store;
  late FakeDialogs dialogs;
  late DocumentWorkspace workspace;

  setUp(() {
    store = MemoryDocuments();
    dialogs = FakeDialogs();
    workspace = DocumentWorkspace(store: store, dialogs: dialogs);
  });
  tearDown(() => workspace.dispose());

  const refused = TextDocumentFolderNotWritableException(
    'A temporary file could not be created beside the document. Check that '
    'its folder is writable.',
    folder: '/locked',
  );

  Future<DocumentTab> editedTab() async {
    store.files[testPath('notes.txt')] = document('notes.txt', 'one');
    await workspace.open(testPath('notes.txt'));
    final tab = workspace.active!;
    tab.editor.text.text = 'two';
    store.writeFailures[testPath('notes.txt')] = refused;
    return tab;
  }

  test('a folder that refuses the save offers Save As elsewhere', () async {
    final tab = await editedTab();
    dialogs.saveElsewhere = true;
    dialogs.savePath = testPath('elsewhere.txt');

    expect(await workspace.save(tab), isTrue);

    expect(dialogs.saveElsewhereAsked, [('notes.txt', '/locked')]);
    expect(store.files[testPath('elsewhere.txt')]?.text, 'two');
    expect(store.files[testPath('notes.txt')]?.text, 'one');
    expect(tab.path, testPath('elsewhere.txt'));
    expect(tab.hasUnsavedChanges, isFalse);
    expect(workspace.error, isNull);
  });

  test('declining the offer reports the refusal and keeps the edit', () async {
    final tab = await editedTab();

    expect(await workspace.save(tab), isFalse);

    expect(dialogs.saveElsewhereAsked, hasLength(1));
    expect(workspace.error, contains('Check that its folder is writable'));
    expect(tab.path, testPath('notes.txt'));
    expect(tab.hasUnsavedChanges, isTrue);
  });

  test('other save failures are reported without the offer', () async {
    final tab = await editedTab();
    store.writeFailures[testPath('notes.txt')] = const TextDocumentException(
      'The disk is full.',
    );

    expect(await workspace.save(tab), isFalse);

    expect(dialogs.saveElsewhereAsked, isEmpty);
    expect(workspace.error, contains('The disk is full.'));
  });
}
