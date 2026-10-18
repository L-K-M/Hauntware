import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/document_publication.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;

class Publication extends DocumentPublication {
  bool _pending = false;
  bool uploadSucceeds = true;
  int uploads = 0;
  int discards = 0;
  @override
  String get displayPath => 'Production (user@server:22)/etc/config.txt';
  @override
  String get sourcePath => '/etc/config.txt';
  @override
  bool get pending => _pending;
  @override
  void localSaved(String digest) {
    _pending = true;
    notifyListeners();
  }

  @override
  Future<bool> publish() async {
    uploads++;
    if (!uploadSucceeds) throw StateError('Disconnected');
    _pending = false;
    notifyListeners();
    return true;
  }

  @override
  Future<void> discard() async {
    discards++;
    _pending = false;
    notifyListeners();
  }
}

void main() {
  late MemoryDocuments store;
  late FakeDialogs dialogs;
  late DocumentWorkspace workspace;
  late Publication publication;

  setUp(() {
    store = MemoryDocuments();
    dialogs = FakeDialogs();
    workspace = DocumentWorkspace(store: store, dialogs: dialogs);
    publication = Publication();
    store.files[testPath('config.txt')] = document('config.txt', 'original');
  });
  tearDown(() {
    workspace.dispose();
    publication.dispose();
  });

  Future<DocumentTab> open() async {
    await workspace.openManaged(testPath('config.txt'), publication);
    return workspace.active!;
  }

  test('failed upload retains pending state and Save All retries it', () async {
    final tab = await open();
    tab.editor.text.text = 'edited';
    publication.uploadSucceeds = false;
    expect(await workspace.save(tab), isFalse);
    expect(store.files[tab.path]!.text, 'edited');
    expect(tab.editor.isDirty, isFalse);
    expect(tab.hasUnsavedChanges, isTrue);
    expect(workspace.windowTitle, startsWith('●'));
    dialogs.choices.add(CloseChoice.cancel);
    expect(await workspace.closeTab(tab), isFalse);
    expect(workspace.documents, contains(tab));

    publication.uploadSucceeds = true;
    expect(await workspace.saveAll(), isTrue);
    expect(publication.uploads, 2);
    expect(tab.hasUnsavedChanges, isFalse);
    expect(workspace.error, isNull);
    expect(tab.editor.displayPath, publication.displayPath);
  });

  test(
    'a local copy neither retargets nor marks the remote document saved',
    () async {
      final tab = await open();
      tab.editor.text.text = 'local export';
      dialogs.savePath = testPath('export.txt');
      expect(await workspace.save(tab, saveAs: true), isTrue);
      expect(store.files[testPath('export.txt')]!.text, 'local export');
      expect(store.files[testPath('config.txt')]!.text, 'original');
      expect(tab.path, testPath('config.txt'));
      expect(tab.hasUnsavedChanges, isTrue);
      expect(publication.uploads, 0);
    },
  );

  test('discard closes pending remote tab without uploading', () async {
    final tab = await open();
    publication.localSaved('new');
    dialogs.choices.add(CloseChoice.discard);
    expect(await workspace.closeTab(tab), isTrue);
    expect(publication.discards, 1);
    expect(publication.uploads, 0);
    expect(workspace.canReopenClosed, isFalse);
  });

  test(
    'a cancelled app-wide quit keeps a previously reviewed checkout',
    () async {
      await open();
      publication.localSaved('new');
      dialogs.choices.add(CloseChoice.discard);
      expect(await workspace.confirmQuit(), isTrue);
      workspace.releaseQuit();
      expect(publication.discards, 0);
      expect(workspace.active!.hasUnsavedChanges, isTrue);
    },
  );

  test('workspace prompts lock editor and quit until settled', () async {
    final tab = await open();
    await workspace.chooseWorkspace(() async {
      expect(workspace.interactionLocked, isTrue);
      expect(tab.editor.editingLocked, isTrue);
      expect(await workspace.confirmQuit(), isFalse);
      return 'folder';
    });
    expect(workspace.interactionLocked, isFalse);
    expect(tab.editor.editingLocked, isFalse);
  });
}
