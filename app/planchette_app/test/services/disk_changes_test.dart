import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/services/document_store.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;

// Adapted from #26: noticing files that other programs change or remove.
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

  test('a tab without edits takes the new version in place', () async {
    final tab = await open('one\ntwo\n');
    tab.editor.text.selection = const TextSelection.collapsed(offset: 5);
    final generation = tab.editor.installGeneration;
    changeOnDisk('one\ntwo\nthree\n');

    store.loadGate = Completer<void>();
    final checking = workspace.checkDisk();
    await pumpEventQueue();
    // Locked while the file is read, like a revert: typing now would be
    // replaced by the text on its way in.
    expect(tab.busy, isTrue);
    expect(tab.editor.editingLocked, isTrue);
    store.loadGate!.complete();
    await checking;

    expect(tab.editor.text.text, 'one\ntwo\nthree\n');
    expect(tab.editor.isDirty, isFalse);
    expect(tab.editor.text.selection, const TextSelection.collapsed(offset: 5));
    // An install, so the view starts a fresh undo history.
    expect(tab.editor.installGeneration, generation + 1);
    expect(tab.baseline!.sha256, 'v2');
    expect(tab.disk, DiskState.current);
    expect(tab.editor.editingLocked, isFalse);
    expect(dialogs.revertAsked, isFalse);
  });

  test('a shorter new version keeps the selection inside the text', () async {
    final tab = await open('one\ntwo\nthree\n');
    tab.editor.text.selection = const TextSelection(
      baseOffset: 4,
      extentOffset: 13,
    );
    changeOnDisk('one\n');
    await workspace.checkDisk();
    expect(tab.editor.text.text, 'one\n');
    final selection = tab.editor.text.selection;
    expect(selection.isValid, isTrue);
    expect(selection.start, inInclusiveRange(0, 4));
    expect(selection.end, inInclusiveRange(0, 4));
  });

  test('Keep Mine waits while the editor is busy', () async {
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    changeOnDisk('theirs');
    await workspace.checkDisk();
    store.loadGate = Completer<void>();
    final reloading = tab.editor.reload();
    await pumpEventQueue();
    expect(tab.editor.isBusy, isTrue);
    // A loading editor reads as clean, which is what refuses it here; saves
    // hold the workspace's own busy flag.
    workspace.keepMine(tab);
    expect(tab.disk, DiskState.changed);
    expect(tab.baseline!.sha256, 'v1');
    store.loadGate!.complete();
    await reloading;
  });

  test('a tab with edits shows a notice and keeps the edits', () async {
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    changeOnDisk('theirs');
    await workspace.checkDisk();
    expect(tab.disk, DiskState.changed);
    expect(tab.editor.text.text, 'mine');
    expect(tab.editor.isDirty, isTrue);

    // Reload is the user's choice already, so it does not ask again.
    expect(await workspace.reloadFromDisk(tab), isTrue);
    expect(dialogs.revertAsked, isFalse);
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
    expect(tab.editor.isDirty, isTrue);
    expect(await workspace.save(tab), isTrue);
    expect(store.files[path]!.text, 'mine');
    expect(store.writes.last.digest, 'v2');
  });

  test('a change after Keep Mine is still caught', () async {
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    changeOnDisk('theirs');
    await workspace.checkDisk();
    workspace.keepMine(tab);

    changeOnDisk('theirs again', digest: 'v3');
    expect(await workspace.save(tab), isFalse);
    expect(store.files[path]!.text, 'theirs again');
    expect(tab.disk, DiskState.changed);
    expect(workspace.error, isNull);

    await workspace.checkDisk();
    expect(tab.disk, DiskState.changed);
    workspace.keepMine(tab);
    expect(await workspace.save(tab), isTrue);
    expect(store.writes.last.digest, 'v3');
    expect(store.files[path]!.text, 'mine');
  });

  test('Keep Mine is refused for a tab without edits', () async {
    // Nothing would mark the old text unsaved, so the next save or quit
    // would leave the other version on disk while the tab shows another.
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    changeOnDisk('theirs');
    await workspace.checkDisk();
    tab.editor.text.text = 'original';
    workspace.keepMine(tab);
    expect(tab.disk, DiskState.changed);
    expect(tab.baseline!.sha256, 'v1');
  });

  test('a save conflict turns into the notice instead of a dead end', () async {
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    changeOnDisk('theirs');
    expect(await workspace.save(tab), isFalse);
    expect(tab.disk, DiskState.changed);
    expect(workspace.error, isNull);
    expect(store.files[path]!.text, 'theirs');
    expect(tab.editor.text.text, 'mine');
  });

  test('Save All names a document that changed on disk', () async {
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    store.files[testPath('other.txt')] = document('other.txt', 'other');
    await workspace.open(testPath('other.txt'));
    workspace.active!.editor.text.text = 'other edited';
    changeOnDisk('theirs');

    expect(await workspace.saveAll(), isFalse);
    expect(tab.disk, DiskState.changed);
    expect(
      workspace.error,
      'Saved 1 of 2. Could not save: watched.txt (it changed on disk).',
    );
    // Still unsaved, so a quit asks about it.
    expect(tab.editor.isDirty, isTrue);
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

  test(
    'a save to a missing file that reappeared never overwrites it',
    () async {
      final tab = await open('original');
      tab.editor.text.text = 'mine';
      store.files.remove(path);
      await workspace.checkDisk();
      expect(tab.disk, DiskState.missing);

      changeOnDisk('restored by a sync client', digest: 'v3');
      // Recreating uses exclusive creation, so it refuses the new file and
      // the notice turns into a conflict instead of a silent overwrite.
      expect(await workspace.save(tab), isFalse);
      expect(store.files[path]!.text, 'restored by a sync client');
      expect(tab.disk, DiskState.changed);
      expect(workspace.error, isNull);
    },
  );

  test('an unrelated save failure stays visible behind a notice', () async {
    final tab = await open('original');
    store.files.remove(path);
    await workspace.checkDisk();
    expect(tab.disk, DiskState.missing);

    store.writeError = const FileSystemException('Permission denied');
    expect(await workspace.save(tab), isFalse);
    expect(tab.disk, DiskState.missing);
    expect(workspace.error, contains('Permission denied'));
  });

  test('a file moved away and back clears its notice', () async {
    final tab = await open('original');
    await workspace.checkDisk();
    final original = store.files.remove(path)!;
    await workspace.checkDisk();
    expect(tab.disk, DiskState.missing);

    // Moving it back keeps its modification time and size.
    store.files[path] = original;
    await workspace.checkDisk();
    expect(tab.disk, DiskState.current);
    tab.editor.text.text = 'edited';
    expect(await workspace.save(tab), isTrue);
    expect(store.files[path]!.text, 'edited');
    expect(store.writes.last.digest, 'v1');
  });

  test('unchanged file stamps skip hashing', () async {
    await open('stable');
    await workspace.checkDisk();
    final hashed = store.digests;
    final stamped = store.stamps;
    await workspace.checkDisk();
    await workspace.checkDisk();
    expect(store.digests, hashed);
    expect(store.stamps, stamped + 2);

    changeOnDisk('stable', digest: 'touched');
    await workspace.checkDisk();
    expect(store.digests, greaterThan(hashed));
  });

  test('an unreadable file is reported once per state', () async {
    final tab = await open('original');
    store.digestFailures[path] = const FileSystemException('Permission denied');
    await workspace.checkDisk();
    expect(workspace.error, contains('Permission denied'));
    expect(workspace.error, contains('watched.txt'));
    expect(tab.disk, DiskState.current);

    // Every window focus checks again; the same failure stays dismissed.
    workspace.clearError();
    await workspace.checkDisk();
    await workspace.checkDisk();
    expect(workspace.error, isNull);

    // A new state of the file is worth a new report.
    changeOnDisk('theirs');
    await workspace.checkDisk();
    expect(workspace.error, contains('Permission denied'));

    // Readable again: the report is no longer true.
    store.digestFailures.clear();
    await workspace.checkDisk();
    expect(workspace.error, isNull);
    expect(tab.editor.text.text, 'theirs');
  });

  test('a new version that cannot be loaded is reported once', () async {
    final tab = await open('original');
    changeOnDisk('theirs');
    store.loadFailures[path] = const FileSystemException('File is too large');
    await workspace.checkDisk();
    // The buffer no longer matches the file, so the notice says so and
    // offers Reload once the file can be read.
    expect(tab.editor.text.text, 'original');
    expect(tab.disk, DiskState.changed);
    expect(workspace.error, contains('File is too large'));

    workspace.clearError();
    await workspace.checkDisk();
    expect(workspace.error, isNull);

    store.loadFailures.clear();
    expect(await workspace.reloadFromDisk(tab), isTrue);
    expect(tab.editor.text.text, 'theirs');
    expect(tab.disk, DiskState.current);
  });

  test('a busy tab is skipped until it is idle again', () async {
    final tab = await open('original');
    changeOnDisk('theirs');
    tab.busy = true;
    await workspace.checkDisk();
    expect(tab.editor.text.text, 'original');
    expect(tab.disk, DiskState.current);

    tab.busy = false;
    await workspace.checkDisk();
    expect(tab.editor.text.text, 'theirs');
  });

  test('a result is dropped when the tab saved while it was read', () async {
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    store.digestGate = Completer<void>();
    final checking = workspace.checkDisk();
    await pumpEventQueue();
    // Parked inside the file read, so the save below races it.
    expect(store.digests, 1);

    // The save changes both the file and the baseline under the check, and
    // new edits follow, so a stale comparison would flag the tab's own save
    // as an outside change.
    expect(await workspace.save(tab), isTrue);
    tab.editor.text.text = 'mine, more';
    store.digestGate!.complete();
    await checking;
    expect(tab.disk, DiskState.current);
    expect(workspace.error, isNull);
  });

  test('a result is dropped when the tab became busy meanwhile', () async {
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    changeOnDisk('theirs');
    store.digestGate = Completer<void>();
    final checking = workspace.checkDisk();
    await pumpEventQueue();

    // A revert takes the tab over; its own outcome settles the file.
    store.loadGate = Completer<void>();
    final reverting = workspace.revert(tab);
    await pumpEventQueue();
    expect(tab.busy, isTrue);
    store.digestGate!.complete();
    await checking;
    expect(tab.disk, DiskState.current);

    store.loadGate!.complete();
    expect(await reverting, isTrue);
    expect(tab.editor.text.text, 'theirs');
    expect(tab.disk, DiskState.current);
  });

  test('a check waits for an open dialog', () async {
    final tab = await open('original');
    tab.editor.text.text = 'mine';
    dialogs.choiceGate = Completer<CloseChoice>();
    final closing = workspace.closeTab(tab);
    await pumpEventQueue();
    expect(workspace.interactionLocked, isTrue);

    changeOnDisk('theirs');
    final checking = workspace.checkDisk();
    await pumpEventQueue();
    expect(tab.disk, DiskState.current);

    dialogs.choiceGate!.complete(CloseChoice.cancel);
    expect(await closing, isFalse);
    await checking;
    expect(tab.disk, DiskState.changed);
  });

  test('untitled documents are never checked', () async {
    final tab = workspace.newDocument()!;
    tab.editor.text.text = 'draft';
    await workspace.checkDisk();
    expect(store.stamps, 0);
    expect(tab.disk, DiskState.current);
  });

  test('outside changes are handled end to end on a real file', () async {
    final directory = await Directory.systemTemp.createTemp('planchette-');
    addTearDown(() => directory.delete(recursive: true));
    final local = DocumentWorkspace(
      store: LocalDocumentStore(),
      dialogs: FakeDialogs(),
    );
    addTearDown(local.dispose);
    final file = File(paths.join(directory.path, 'real.txt'));
    await file.writeAsString('first\n');
    await local.open(file.path);
    final tab = local.active!;

    // Sizes differ at each step, so no stamp can repeat within the file
    // system's timestamp granularity.
    await file.writeAsString('second version\n');
    await local.checkDisk();
    expect(tab.editor.text.text, 'second version\n');

    tab.editor.text.text = 'mine\n';
    await file.writeAsString('third version, theirs\n');
    await local.checkDisk();
    expect(tab.disk, DiskState.changed);
    local.keepMine(tab);
    expect(await local.save(tab), isTrue);
    expect(await file.readAsString(), 'mine\n');

    await file.delete();
    await local.checkDisk();
    expect(tab.disk, DiskState.missing);
    tab.editor.text.text = 'mine again\n';
    expect(await local.save(tab), isTrue);
    expect(await file.readAsString(), 'mine again\n');
    expect(tab.disk, DiskState.current);
    expect(local.error, isNull);
  });

  test('the local store stamps regular files only', () async {
    final directory = await Directory.systemTemp.createTemp('planchette-');
    addTearDown(() => directory.delete(recursive: true));
    final store = LocalDocumentStore();
    final file = paths.join(directory.path, 'notes.txt');
    expect(await store.stamp(file), isNull);

    await File(file).writeAsString('text');
    expect(await store.stamp(file), isNotNull);
    expect((await store.stamp(file))!.size, 4);

    // A directory in the file's place reads as missing, not unchanged.
    await File(file).delete();
    await Directory(file).create();
    expect(await store.stamp(file), isNull);
  });
}
