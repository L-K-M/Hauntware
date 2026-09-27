import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryDocuments store;
  late FakeDialogs dialogs;
  late DocumentWorkspace workspace;
  final path = testPath('watched.txt');

  setUp(() {
    store = MemoryDocuments();
    dialogs = FakeDialogs();
    workspace = DocumentWorkspace(store: store, dialogs: dialogs);
  });
  tearDown(() => workspace.dispose());

  Future<DocumentTab> open(String text) async {
    store.files[path] = document('watched.txt', text, digest: 'v1');
    await workspace.open(path);
    return workspace.active!;
  }

  void changeOnDisk(String text, {String digest = 'v2'}) =>
      store.files[path] = document('watched.txt', text, digest: digest);

  test(
    'a tab without edits takes the new version and keeps its caret',
    () async {
      final tab = await open('one\ntwo\n');
      tab.editor.text.selection = const TextSelection.collapsed(offset: 5);
      changeOnDisk('one\ntwo\nthree\n');
      await workspace.checkDisk();
      expect(tab.editor.text.text, 'one\ntwo\nthree\n');
      expect(tab.editor.isDirty, isFalse);
      expect(
        tab.editor.text.selection,
        const TextSelection.collapsed(offset: 5),
      );
      expect(tab.baseline!.sha256, 'v2');
      expect(tab.disk, DiskState.current);
    },
  );

  test('a tab with edits shows a notice and keeps the edits', () async {
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    changeOnDisk('theirs');
    await workspace.checkDisk();
    expect(tab.disk, DiskState.changed);
    expect(tab.editor.text.text, 'mine');

    await workspace.reloadFromDisk(tab);
    expect(tab.editor.text.text, 'theirs');
    expect(tab.editor.isDirty, isFalse);
    expect(tab.disk, DiskState.current);
  });

  test('Keep Mine lets the next save replace the outside change', () async {
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    changeOnDisk('theirs');
    await workspace.checkDisk();
    workspace.keepMine(tab);
    expect(tab.disk, DiskState.current);
    expect(await workspace.save(tab), isTrue);
    expect(store.files[path]!.text, 'mine');
    expect(store.writes.last.digest, 'v2');
  });

  test('a save conflict turns into the notice instead of a dead end', () async {
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    changeOnDisk('theirs');
    expect(await workspace.save(tab), isFalse);
    expect(tab.disk, DiskState.changed);
    expect(workspace.error, isNull);
    expect(store.files[path]!.text, 'theirs');
  });

  test('a deleted file is flagged and saving creates it again', () async {
    final tab = await open('original');
    store.files.remove(path);
    await workspace.checkDisk();
    expect(tab.disk, DiskState.missing);
    expect(await workspace.save(tab), isTrue);
    expect(store.writes.last.digest, isNull);
    expect(store.files[path]!.text, 'original');
    expect(tab.disk, DiskState.current);
  });

  test('Revert asks only when there are edits to lose', () async {
    final tab = await open('saved');
    changeOnDisk('newer');
    expect(await workspace.revert(tab), isTrue);
    expect(dialogs.revertsAsked, isEmpty);
    expect(tab.editor.text.text, 'newer');

    tab.editor.text.text = 'edited';
    dialogs.revert = false;
    expect(await workspace.revert(tab), isFalse);
    expect(tab.editor.text.text, 'edited');
    dialogs.revert = true;
    expect(await workspace.revert(tab), isTrue);
    expect(tab.editor.text.text, 'newer');
    expect(dialogs.revertsAsked, ['watched.txt', 'watched.txt']);
  });

  test('untitled documents cannot be reverted', () async {
    final tab = workspace.newDocument()!;
    expect(await workspace.revert(tab), isFalse);
  });

  test('unchanged file stamps skip rehashing', () async {
    await open('stable');
    await workspace.checkDisk();
    final hashed = store.digests;
    await workspace.checkDisk();
    await workspace.checkDisk();
    expect(store.digests, hashed);
    expect(store.stamps, greaterThanOrEqualTo(3));
  });
}
