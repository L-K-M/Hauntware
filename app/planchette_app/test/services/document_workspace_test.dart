import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_core/planchette_core.dart';
import 'package:planchette_app/services/document_store.dart';
import 'package:planchette_app/services/document_workspace.dart';

String testPath(String name) => paths.join(Directory.systemTemp.path, name);

TextDocument document(
  String name,
  String text, {
  String digest = 'baseline',
  bool bom = false,
  LineEnding ending = LineEnding.lf,
}) => TextDocument(
  file: File(testPath(name)),
  text: text,
  hasUtf8Bom: bom,
  lineEnding: ending,
  sha256: digest,
);

class MemoryDocuments implements DocumentStore {
  MemoryDocuments({paths.Context? pathContext})
    : pathContext = pathContext ?? paths.context;
  final paths.Context pathContext;
  final files = <String, TextDocument>{};
  final writes = <({String path, String text, String? digest})>[];
  final aliases = <String, String>{};
  final writeProtected = <String>{};
  Completer<void>? writeGate;
  Completer<void>? loadGate;
  Completer<void>? savePathGate;
  Object? writeError;
  final Map<String, Object> writeFailures = {};
  int version = 0;

  /// Set when two writes overlap in time, which leaves their commit order to
  /// the event loop rather than to the request order.
  bool sawOverlappingWrite = false;
  int _activeWrites = 0;

  @override
  Future<TextDocument> load(String path) async {
    await loadGate?.future;
    final value = files[aliases[path] ?? path];
    if (value == null) throw const FileSystemException('Missing file');
    return value;
  }

  @override
  Future<String> canonicalSavePath(String path) async {
    await savePathGate?.future;
    return pathContext.normalize(pathContext.absolute(path));
  }

  @override
  Future<String?> existingDigest(String path) async => files[path]?.sha256;

  @override
  Future<bool> isWriteProtected(String path) async =>
      writeProtected.contains(path);

  @override
  Future<TextDocument> write({
    required String path,
    required String text,
    required TextDocument? source,
    required String? expectedSha256,
  }) async {
    writes.add((path: path, text: text, digest: expectedSha256));
    _activeWrites++;
    if (_activeWrites > 1) sawOverlappingWrite = true;
    try {
      await writeGate?.future;
      if (writeFailures[path] case final error?) throw error;
      if (writeError case final error?) throw error;
      if (files[path]?.sha256 != expectedSha256) {
        throw StateError('Changed externally');
      }
      final saved = TextDocument(
        file: File(path),
        text: text,
        hasUtf8Bom: source?.hasUtf8Bom ?? false,
        lineEnding: source?.lineEnding ?? LineEnding.lf,
        sha256: 'saved-${++version}',
      );
      files[path] = saved;
      return saved;
    } finally {
      _activeWrites--;
    }
  }
}

class FakeDialogs implements DocumentDialogs {
  List<String> openPaths = [];
  String? savePath;
  bool replace = true;
  bool revert = true;
  bool revertAsked = false;
  final choices = <CloseChoice>[];
  final asked = <String>[];
  final bulkAsked = <List<String>>[];
  BulkCloseChoice bulkChoice = BulkCloseChoice.saveAll;
  Completer<BulkCloseChoice>? bulkGate;
  final savePrompts = <String>[];
  Completer<CloseChoice>? choiceGate;
  Future<void> Function()? beforeReplace;
  final readOnlyChoices = <ReadOnlyChoice>[];
  Completer<List<String>>? openGate;
  final readOnlyAsked = <String>[];

  @override
  Future<List<String>> pickOpenFiles() async => openGate?.future ?? openPaths;
  @override
  Future<String?> pickSavePath(String suggestedName) async {
    savePrompts.add(suggestedName);
    return savePath;
  }

  @override
  Future<bool> confirmReplace(String path) async {
    await beforeReplace?.call();
    return replace;
  }

  @override
  Future<BulkCloseChoice> chooseBulkClose(List<String> names) async {
    bulkAsked.add(names);
    return bulkGate?.future ?? bulkChoice;
  }

  @override
  Future<CloseChoice> chooseClose(String name) async {
    asked.add(name);
    return choiceGate?.future ??
        (choices.isEmpty ? CloseChoice.cancel : choices.removeAt(0));
  }

  @override
  Future<ReadOnlyChoice> chooseReadOnlySave(String name) async {
    readOnlyAsked.add(name);
    return readOnlyChoices.isEmpty
        ? ReadOnlyChoice.cancel
        : readOnlyChoices.removeAt(0);
  }

  @override
  Future<bool> confirmRevert(String name) async {
    revertAsked = true;
    return revert;
  }
}

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

  /// Opens the seeded one.txt fixture and returns its tab, saving each save
  /// test from repeating the same three lines.
  Future<DocumentTab> openOne() async {
    store.files[testPath('one.txt')] = document('one.txt', 'disk');
    await workspace.open(testPath('one.txt'));
    return workspace.active!;
  }

  test('new documents retain independent text and find state', () {
    final first = workspace.newDocument()!;
    first.editor.text.text = 'first';
    first.editor.search.text = 'fir';
    final second = workspace.newDocument()!;
    second.editor.text.text = 'second';
    workspace.select(first);
    expect(first.editor.text.text, 'first');
    expect(first.editor.search.text, 'fir');
    expect(second.editor.text.text, 'second');
    expect(first.name, isNot(second.name));
  });

  test('opening a path or resolved alias reuses the existing buffer', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'disk');
    store.aliases[testPath('alias.txt')] = testPath('one.txt');
    await workspace.open(testPath('one.txt'));
    final original = workspace.active!;
    original.editor.text.text = 'unsaved';
    await workspace.open(testPath('one.txt'));
    await workspace.open(testPath('alias.txt'));
    expect(workspace.documents, [original]);
    expect(original.editor.text.text, 'unsaved');
  });

  test('reusing an open document asks the view to point at its tab', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'disk');
    store.aliases[testPath('alias.txt')] = testPath('one.txt');
    await workspace.open(testPath('one.txt'));
    final original = workspace.active!;
    expect(original.flashRequest, 0);

    // The same path, and a link that resolves onto it, both activate the
    // existing tab rather than adding one.
    await workspace.open(testPath('one.txt'));
    expect(original.flashRequest, 1);
    await workspace.open(testPath('alias.txt'));
    expect(original.flashRequest, 2);
    expect(workspace.documents, [original]);

    // A genuinely new document starts at zero: it has nothing to point at.
    store.files[testPath('two.txt')] = document('two.txt', 'disk');
    await workspace.open(testPath('two.txt'));
    expect(workspace.active!.flashRequest, 0);
    expect(workspace.documents, hasLength(2));
  });

  test(
    'an unreadable file reports an error without leaving a broken tab',
    () async {
      final original = workspace.newDocument()!;
      await workspace.open(testPath('missing.txt'));
      expect(workspace.documents, [original]);
      expect(workspace.error, contains('Missing file'));
    },
  );

  test('a batch open reports every failure in one message', () async {
    store.files[testPath('good.txt')] = document('good.txt', 'ok');
    dialogs.openPaths = [
      testPath('missing-a.txt'),
      testPath('good.txt'),
      testPath('missing-b.txt'),
      testPath('missing-c.txt'),
    ];
    await workspace.openDialog();
    expect(workspace.documents.map((tab) => tab.name), ['good.txt']);
    final error = workspace.error!;
    expect(error, contains('3 files'));
    expect(error, contains('missing-a.txt'));
    expect(error, contains('missing-b.txt'));
    expect(error, contains('missing-c.txt'));
    expect(error, isNot(contains('good.txt')));
  });

  test('same-basename failures fall back to full paths', () async {
    final first = paths.join(Directory.systemTemp.path, 'dir-a', 'same.txt');
    final second = paths.join(Directory.systemTemp.path, 'dir-b', 'same.txt');
    // Case variants are distinct files but indistinguishable as basenames.
    final cased = paths.join(Directory.systemTemp.path, 'dir-c', 'Same.txt');
    dialogs.openPaths = [first, second, cased];
    await workspace.openDialog();
    final error = workspace.error!;
    expect(error, contains(first));
    expect(error, contains(second));
    expect(error, contains(cased));
  });

  test('a single failed batch open keeps the one-file message', () async {
    dialogs.openPaths = [testPath('missing.txt')];
    await workspace.openDialog();
    expect(workspace.error, startsWith('Could not open missing.txt: '));
  });

  test('a lone open failure retires once that file opens', () async {
    dialogs.openPaths = [testPath('late.txt')];
    await workspace.openDialog();
    expect(workspace.error, startsWith('Could not open late.txt: '));

    store.files[testPath('late.txt')] = document('late.txt', 'here now');
    await workspace.open(testPath('late.txt'));
    expect(workspace.error, isNull);
  });

  test('a batch summary outlives one of its files opening', () async {
    dialogs.openPaths = [testPath('late.txt'), testPath('gone.txt')];
    await workspace.openDialog();
    expect(workspace.error, contains('2 files'));

    // The summary also names gone.txt, which is still missing.
    store.files[testPath('late.txt')] = document('late.txt', 'here now');
    await workspace.open(testPath('late.txt'));
    expect(workspace.error, contains('gone.txt'));
  });

  test('a repeated path in one batch reports its failure once', () async {
    dialogs.openPaths = [testPath('missing.txt'), testPath('missing.txt')];
    await workspace.openDialog();
    expect(workspace.error, startsWith('Could not open missing.txt: '));
  });

  test(
    'a long batch error lists the first failures and counts the rest',
    () async {
      dialogs.openPaths = [
        for (var i = 0; i < 7; i++) testPath('missing-$i.txt'),
      ];
      await workspace.openDialog();
      final error = workspace.error!;
      expect(error, contains('7 files'));
      for (var i = 0; i < 5; i++) {
        expect(error, contains('missing-$i.txt'));
      }
      expect(error, isNot(contains('missing-5.txt')));
      expect(error, isNot(contains('missing-6.txt')));
      expect(error, contains('and 2 more'));
    },
  );

  test(
    'Save As during an in-flight save still writes the chosen path',
    () async {
      final tab = await openOne();
      tab.editor.text.text = 'edited';
      store.writeGate = Completer<void>();
      final first = workspace.save(tab);
      await pumpEventQueue();
      dialogs.savePath = testPath('copy.txt');
      final second = workspace.save(tab, saveAs: true);
      store.writeGate!.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(store.writes.map((write) => write.path), [
        testPath('one.txt'),
        testPath('copy.txt'),
      ]);
      expect(tab.path, testPath('copy.txt'));
    },
  );

  test(
    'a second save during an in-flight save writes the newer text',
    () async {
      final tab = await openOne();
      tab.editor.text.text = 'first';
      store.writeGate = Completer<void>();
      final first = workspace.save(tab);
      await pumpEventQueue();
      tab.editor.text.text = 'second';
      final second = workspace.save(tab);
      store.writeGate!.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(store.writes.map((write) => write.text), ['first', 'second']);
      expect(tab.editor.isDirty, isFalse);
    },
  );

  test('saves queued behind one in-flight save run in request order', () async {
    final tab = await openOne();
    tab.editor.text.text = 'edited';
    store.writeGate = Completer<void>();
    final first = workspace.save(tab);
    await pumpEventQueue();

    // Both requests arrive while the first write is still gated, so both read
    // the same in-flight future.
    dialogs.savePath = testPath('copy.txt');
    final saveAs = workspace.save(tab, saveAs: true);
    final second = workspace.save(tab);
    store.writeGate!.complete();
    expect(await first, isTrue);
    expect(await saveAs, isTrue);
    expect(await second, isTrue);
    expect(store.sawOverlappingWrite, isFalse);
    expect(store.writes.map((write) => write.path), [
      testPath('one.txt'),
      testPath('copy.txt'),
      testPath('copy.txt'),
    ]);
  });

  test('opening a file reuses a pristine untitled tab', () async {
    final scratch = workspace.newDocument()!;
    store.files[testPath('one.txt')] = document('one.txt', 'disk');
    await workspace.open(testPath('one.txt'));
    expect(workspace.documents, hasLength(1));
    expect(workspace.active, isNot(scratch));
    expect(workspace.active!.path, testPath('one.txt'));
    expect(workspace.active!.editor.text.text, 'disk');
  });

  test('opening a file keeps an untitled tab that has content', () async {
    final scratch = workspace.newDocument()!..editor.text.text = 'note';
    store.files[testPath('one.txt')] = document('one.txt', 'disk');
    await workspace.open(testPath('one.txt'));
    expect(workspace.documents, [scratch, workspace.active]);
    expect(scratch.editor.text.text, 'note');
  });

  test('a failed open keeps the pristine untitled tab', () async {
    final scratch = workspace.newDocument()!;
    await workspace.open(testPath('missing.txt'));
    expect(workspace.documents, [scratch]);
    expect(workspace.active, scratch);
  });

  test(
    'opening a file replaces only the previously active pristine tab',
    () async {
      final background = workspace.newDocument()!;
      final scratch = workspace.newDocument()!;
      store.files[testPath('one.txt')] = document('one.txt', 'disk');
      await workspace.open(testPath('one.txt'));
      expect(workspace.documents, [background, workspace.active]);
      expect(workspace.active, isNot(scratch));
      expect(workspace.active!.path, testPath('one.txt'));
    },
  );

  test(
    'activating an already open file also drops the pristine untitled tab',
    () async {
      store.files[testPath('one.txt')] = document('one.txt', 'disk');
      final opened = await workspace
          .open(testPath('one.txt'))
          .then((_) => workspace.active!);
      final scratch = workspace.newDocument()!;
      await workspace.open(testPath('one.txt'));
      expect(workspace.documents, [opened]);
      expect(workspace.documents, isNot(contains(scratch)));
    },
  );

  test(
    'New Save creates an absent target and records the saved identity',
    () async {
      final tab = workspace.newDocument()!;
      tab.editor.text.text = 'new content';
      dialogs.savePath = testPath('new.txt');
      expect(await workspace.save(tab), isTrue);
      expect(store.files[dialogs.savePath]!.text, 'new content');
      expect(store.writes.single.digest, isNull);
      expect(tab.path, dialogs.savePath);
      expect(tab.editor.displayPath, dialogs.savePath);
      expect(tab.editor.isDirty, isFalse);
    },
  );

  group('saving a read-only file', () {
    late DocumentTab tab;
    setUp(() async {
      store.files[testPath('locked.txt')] = document('locked.txt', 'disk');
      store.writeProtected.add(testPath('locked.txt'));
      await workspace.open(testPath('locked.txt'));
      tab = workspace.active!..editor.text.text = 'edited';
    });

    test('asks first, and Cancel leaves the file alone', () async {
      expect(await workspace.save(tab), isFalse);
      expect(dialogs.readOnlyAsked, ['locked.txt']);
      expect(store.writes, isEmpty);
      expect(tab.editor.isDirty, isTrue);
    });

    test('Save Anyway replaces it and is not asked again', () async {
      dialogs.readOnlyChoices.add(ReadOnlyChoice.saveAnyway);
      expect(await workspace.save(tab), isTrue);
      expect(store.files[testPath('locked.txt')]!.text, 'edited');

      tab.editor.text.text = 'edited again';
      expect(await workspace.save(tab), isTrue);
      expect(dialogs.readOnlyAsked, hasLength(1));
      expect(store.files[testPath('locked.txt')]!.text, 'edited again');
    });

    test('a Save Anyway whose write fails asks again next time', () async {
      dialogs.readOnlyChoices.add(ReadOnlyChoice.saveAnyway);
      store.writeError = const FileSystemException('Disk full');
      expect(await workspace.save(tab), isFalse);

      // The consent covered one write that never happened; the next save is
      // a fresh decision about a file that is still protected.
      store.writeError = null;
      expect(await workspace.save(tab), isFalse);
      expect(dialogs.readOnlyAsked, ['locked.txt', 'locked.txt']);
      expect(store.files[testPath('locked.txt')]!.text, 'disk');
    });

    test('Save As writes a new file and keeps the original', () async {
      dialogs.readOnlyChoices.add(ReadOnlyChoice.saveAs);
      dialogs.savePath = testPath('copy.txt');
      expect(await workspace.save(tab), isTrue);
      expect(store.files[testPath('locked.txt')]!.text, 'disk');
      expect(store.files[testPath('copy.txt')]!.text, 'edited');
      expect(tab.path, testPath('copy.txt'));
    });

    test('an explicit Save As does not ask', () async {
      dialogs.savePath = testPath('copy.txt');
      expect(await workspace.save(tab, saveAs: true), isTrue);
      expect(dialogs.readOnlyAsked, isEmpty);
    });

    test('a close that saves asks too', () async {
      dialogs.choices.add(CloseChoice.save);
      expect(await workspace.closeTab(tab), isFalse);
      expect(dialogs.readOnlyAsked, ['locked.txt']);
      expect(workspace.documents, [tab]);
      expect(store.writes, isEmpty);
    });
  });

  test('canceling Save As keeps a new document dirty and unnamed', () async {
    final tab = workspace.newDocument()!;
    tab.editor.text.text = 'keep me';
    expect(await workspace.save(tab), isFalse);
    expect(tab.path, isNull);
    expect(tab.editor.isDirty, isTrue);
    expect(store.writes, isEmpty);
  });

  test(
    'Save As preserves formatting and leaves the original untouched',
    () async {
      store.files[testPath('one.txt')] = document(
        'one.txt',
        'original',
        bom: true,
        ending: LineEnding.crlf,
      );
      await workspace.open(testPath('one.txt'));
      final tab = workspace.active!;
      tab.editor.text.text = 'changed';
      dialogs.savePath = testPath('copy.txt');
      expect(await workspace.save(tab, saveAs: true), isTrue);
      expect(store.files[testPath('one.txt')]!.text, 'original');
      final copy = store.files[testPath('copy.txt')]!;
      expect(copy.text, 'changed');
      expect(copy.hasUtf8Bom, isTrue);
      expect(copy.lineEnding, LineEnding.crlf);
      expect(tab.path, testPath('copy.txt'));
    },
  );

  test('failed Save As keeps original identity and dirty buffer', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original');
    await workspace.open(testPath('one.txt'));
    final tab = workspace.active!;
    tab.editor.text.text = 'changed';
    dialogs.savePath = testPath('copy.txt');
    store.writeError = const FileSystemException('Disk full');
    expect(await workspace.save(tab, saveAs: true), isFalse);
    expect(tab.path, testPath('one.txt'));
    expect(tab.baseline!.sha256, 'baseline');
    expect(tab.editor.text.text, 'changed');
    expect(tab.editor.isDirty, isTrue);
    expect(workspace.error, contains('Disk full'));
  });

  test(
    'Save As to the same path cannot bypass external-change detection',
    () async {
      store.files[testPath('one.txt')] = document('one.txt', 'original');
      await workspace.open(testPath('one.txt'));
      final tab = workspace.active!..editor.text.text = 'local edit';
      store.files[testPath('one.txt')] = document(
        'one.txt',
        'external edit',
        digest: 'external',
      );
      dialogs.savePath = testPath('one.txt');
      expect(await workspace.save(tab, saveAs: true), isFalse);
      expect(store.writes.single.digest, 'baseline');
      expect(store.files[testPath('one.txt')]!.text, 'external edit');
    },
  );

  test('Save As refuses a target open in another tab', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original');
    await workspace.open(testPath('one.txt'));
    final tab = workspace.newDocument()!..editor.text.text = 'replacement';
    dialogs.savePath = testPath('one.txt');
    expect(await workspace.save(tab, saveAs: true), isFalse);
    expect(store.writes, isEmpty);
    expect(workspace.error, contains('already open'));
  });

  test(
    'replacement target changes while confirmation is open are preserved',
    () async {
      store.files[testPath('target.txt')] = document('target.txt', 'original');
      final tab = workspace.newDocument()!..editor.text.text = 'replacement';
      dialogs.savePath = testPath('target.txt');
      dialogs.beforeReplace = () async {
        store.files[testPath('target.txt')] = document(
          'target.txt',
          'external',
          digest: 'external',
        );
      };
      expect(await workspace.save(tab), isFalse);
      expect(store.files[testPath('target.txt')]!.text, 'external');
      expect(tab.path, isNull);
    },
  );

  test(
    'pending save retains tab and quit; edits during it remain dirty',
    () async {
      store.files[testPath('one.txt')] = document('one.txt', 'original');
      await workspace.open(testPath('one.txt'));
      final tab = workspace.active!..editor.text.text = 'saving';
      store.writeGate = Completer<void>();
      final saving = workspace.save(tab);
      await Future<void>.delayed(Duration.zero);
      expect(await workspace.closeTab(tab), isFalse);
      expect(await workspace.confirmQuit(), isFalse);
      tab.editor.text.text = 'newer edit';
      store.writeGate!.complete();
      expect(await saving, isTrue);
      expect(store.files[testPath('one.txt')]!.text, 'saving');
      expect(tab.editor.text.text, 'newer edit');
      expect(tab.editor.isDirty, isTrue);
    },
  );

  test(
    'Save in dirty close handles unnamed files and only closes after commit',
    () async {
      final tab = workspace.newDocument()!..editor.text.text = 'keep me';
      dialogs.choices.add(CloseChoice.save);
      dialogs.savePath = testPath('new.txt');
      expect(await workspace.closeTab(tab), isTrue);
      expect(workspace.documents, isEmpty);
      expect(store.files[testPath('new.txt')]!.text, 'keep me');
    },
  );

  test('a refused close says why instead of doing nothing', () async {
    store.files[testPath('busy.txt')] = document('busy.txt', 'original');
    await workspace.open(testPath('busy.txt'));
    final tab = workspace.active!..editor.text.text = 'saving';
    store.writeGate = Completer<void>();
    final saving = workspace.save(tab);
    await Future<void>.delayed(Duration.zero);

    expect(tab.editor.isSaving, isTrue);
    expect(await workspace.closeTab(tab), isFalse);
    expect(workspace.error, contains('still being saved'));
    expect(workspace.documents, [tab]);

    store.writeGate!.complete();
    expect(await saving, isTrue);
    expect(await workspace.closeTab(tab), isTrue);
    // The refusal named this tab, and the tab is gone, so it goes too.
    expect(workspace.error, isNull);
  });

  test('a tab busy with a save in progress gets its own wording', () async {
    // The Save As dialog has answered but the destination is not resolved
    // yet: the tab is busy, no write is running, and no dialog holds the
    // workspace. That is the window the "busy" wording is for.
    store.files[testPath('source.txt')] = document('source.txt', 'original');
    await workspace.open(testPath('source.txt'));
    final tab = workspace.active!..editor.text.text = 'changed';
    dialogs.savePath = testPath('target.txt');
    store.savePathGate = Completer<void>();
    final saving = workspace.save(tab, saveAs: true);
    await Future<void>.delayed(Duration.zero);

    expect(tab.busy, isTrue);
    expect(tab.editor.isSaving, isFalse);
    expect(workspace.interactionLocked, isFalse);
    expect(await workspace.closeTab(tab), isFalse);
    expect(workspace.error, contains('is busy'));
    expect(workspace.error, isNot(contains('still being saved')));

    store.savePathGate!.complete();
    expect(await saving, isTrue);
    expect(await workspace.closeTab(tab), isTrue);
    expect(workspace.error, isNull);
  });

  test('saving a document that is still opening says so', () async {
    store.files[testPath('opening.txt')] = document('opening.txt', 'on disk');
    store.loadGate = Completer<void>();
    final opening = workspace.open(testPath('opening.txt'));
    await Future<void>.delayed(Duration.zero);
    final tab = workspace.active!;
    expect(tab.editor.isLoading, isTrue);

    expect(await workspace.save(tab), isFalse);
    expect(workspace.error, contains('still opening'));
    expect(workspace.documents, [tab]);

    store.loadGate!.complete();
    await opening;
    expect(tab.editor.isLoading, isFalse);
    // The refusal is about a state that has now passed.
    expect(await workspace.closeTab(tab), isTrue);
    expect(workspace.error, isNull);
  });

  test('a locked workspace refuses a close silently', () async {
    final tab = workspace.newDocument()!..editor.text.text = 'keep me';
    dialogs.choiceGate = Completer<CloseChoice>();
    final closing = workspace.closeTab(tab);
    await Future<void>.delayed(Duration.zero);

    // A dialog is open: the refusal is visible, so it must not also raise an
    // error the user did not cause.
    expect(await workspace.save(tab), isFalse);
    expect(workspace.error, isNull);

    dialogs.choiceGate!.complete(CloseChoice.discard);
    expect(await closing, isTrue);
  });

  test(
    'a discard refused by a newer edit says nothing was discarded',
    () async {
      final tab = workspace.newDocument()!..editor.text.text = 'keep me';
      dialogs.choiceGate = Completer<CloseChoice>();
      final closing = workspace.closeTab(tab);
      await Future<void>.delayed(Duration.zero);
      tab.editor.text.text = 'edited again';
      dialogs.choiceGate!.complete(CloseChoice.discard);

      expect(await closing, isFalse);
      expect(workspace.documents, [tab]);
      expect(tab.editor.isDirty, isTrue);
      expect(workspace.error, contains('nothing was'));
    },
  );

  test('a cancelled close prompt stays silent', () async {
    final tab = workspace.newDocument()!..editor.text.text = 'keep me';
    dialogs.choices.add(CloseChoice.cancel);
    expect(await workspace.closeTab(tab), isFalse);
    expect(workspace.documents, [tab]);
    expect(workspace.error, isNull);
  });

  test('canceled destination keeps dirty close open', () async {
    final tab = workspace.newDocument()!..editor.text.text = 'keep me';
    dialogs.choices.add(CloseChoice.save);
    expect(await workspace.closeTab(tab), isFalse);
    expect(workspace.documents, [tab]);
    expect(tab.editor.isDirty, isTrue);
  });

  test(
    'save from a native menu is blocked while discard decision is pending',
    () async {
      final tab = workspace.newDocument()!..editor.text.text = 'keep me';
      dialogs.choiceGate = Completer<CloseChoice>();
      final closing = workspace.closeTab(tab);
      expect(await workspace.save(tab), isFalse);
      expect(workspace.newDocument(), isNull);
      dialogs.choiceGate!.complete(CloseChoice.cancel);
      expect(await closing, isFalse);
      expect(workspace.interactionLocked, isFalse);
    },
  );

  test('discard cannot approve a later buffer revision', () async {
    final tab = workspace.newDocument()!..editor.text.text = 'reviewed';
    dialogs.choiceGate = Completer<CloseChoice>();
    final closing = workspace.closeTab(tab);
    tab.editor.text.text = 'later revision';
    dialogs.choiceGate!.complete(CloseChoice.discard);
    expect(await closing, isFalse);
    expect(workspace.documents, [tab]);
  });

  test('revert reloads the saved file after confirmation', () async {
    store.files[testPath('note.txt')] = document('note.txt', 'saved text');
    await workspace.open(testPath('note.txt'));
    final tab = workspace.active!..editor.text.text = 'local edits';
    store.files[testPath('note.txt')] = document(
      'note.txt',
      'changed elsewhere',
      digest: 'external',
    );
    expect(await workspace.revert(tab), isTrue);
    expect(tab.editor.text.text, 'changed elsewhere');
    expect(tab.editor.isDirty, isFalse);
    expect(dialogs.revertAsked, isTrue);
  });

  test('declined revert keeps the unsaved buffer', () async {
    store.files[testPath('note.txt')] = document('note.txt', 'saved text');
    await workspace.open(testPath('note.txt'));
    final tab = workspace.active!..editor.text.text = 'local edits';
    dialogs.revert = false;
    expect(await workspace.revert(tab), isFalse);
    expect(tab.editor.text.text, 'local edits');
    expect(tab.editor.isDirty, isTrue);
  });

  test('revert of a clean document skips confirmation', () async {
    store.files[testPath('note.txt')] = document('note.txt', 'saved text');
    await workspace.open(testPath('note.txt'));
    final tab = workspace.active!;
    dialogs.revert = false;
    expect(await workspace.revert(tab), isTrue);
    expect(dialogs.revertAsked, isFalse);
    expect(tab.editor.text.text, 'saved text');
  });

  test('a failed reload keeps the buffer and reports an error', () async {
    store.files[testPath('note.txt')] = document('note.txt', 'saved text');
    await workspace.open(testPath('note.txt'));
    final tab = workspace.active!..editor.text.text = 'precious edits';
    store.files.remove(testPath('note.txt'));
    expect(await workspace.revert(tab), isFalse);
    expect(tab.editor.text.text, 'precious edits');
    expect(tab.editor.isDirty, isTrue);
    expect(tab.editor.error, isNull);
    expect(tab.editor.canSave, isTrue);
    expect(workspace.error, contains('Could not revert'));
  });

  test('untitled tabs cannot revert', () async {
    final tab = workspace.newDocument()!;
    expect(await workspace.revert(tab), isFalse);
    expect(dialogs.revertAsked, isFalse);
  });

  test('revert works after Save As gives an untitled tab a file', () async {
    final tab = workspace.newDocument()!..editor.text.text = 'first draft';
    dialogs.savePath = testPath('draft.txt');
    expect(await workspace.save(tab), isTrue);
    tab.editor.text.text = 'revised';
    store.files[testPath('draft.txt')] = document(
      'draft.txt',
      'newer on disk',
      digest: 'external',
    );
    expect(await workspace.revert(tab), isTrue);
    expect(tab.editor.text.text, 'newer on disk');
    expect(tab.editor.isDirty, isFalse);
  });

  test('revert follows a Save As retarget', () async {
    store.files[testPath('a.txt')] = document('a.txt', 'content a');
    await workspace.open(testPath('a.txt'));
    final tab = workspace.active!;
    dialogs.savePath = testPath('b.txt');
    expect(await workspace.save(tab, saveAs: true), isTrue);
    tab.editor.text.text = 'edited at b';
    store.files[testPath('b.txt')] = document(
      'b.txt',
      'newer b',
      digest: 'b-external',
    );
    expect(await workspace.revert(tab), isTrue);
    expect(tab.editor.text.text, 'newer b');
    expect(tab.path, testPath('b.txt'));
  });

  test(
    'quit decisions are shared and cancellation retains every document',
    () async {
      final first = workspace.newDocument()!..editor.text.text = 'first';
      final second = workspace.newDocument()!..editor.text.text = 'second';
      dialogs.bulkChoice = BulkCloseChoice.cancel;
      final one = workspace.confirmQuit();
      final two = workspace.confirmQuit();
      expect(identical(one, two), isTrue);
      expect(await one, isFalse);
      expect(await two, isFalse);
      expect(dialogs.bulkAsked, [
        [first.name, second.name],
      ]);
      expect(workspace.documents, [first, second]);
      expect(workspace.interactionLocked, isFalse);
    },
  );

  test(
    'quit with several dirty documents saves all of them from one question',
    () async {
      store.files[testPath('one.txt')] = document('one.txt', 'one');
      store.files[testPath('two.txt')] = document('two.txt', 'two');
      final one = await openOne();
      await workspace.open(testPath('two.txt'));
      final two = workspace.active!;
      one.editor.text.text = 'edited one';
      two.editor.text.text = 'edited two';
      dialogs.bulkChoice = BulkCloseChoice.saveAll;
      expect(await workspace.confirmQuit(), isTrue);
      expect(dialogs.asked, isEmpty);
      expect(store.files[testPath('one.txt')]!.text, 'edited one');
      expect(store.files[testPath('two.txt')]!.text, 'edited two');
      expect(workspace.interactionLocked, isTrue);
    },
  );

  test(
    'quit with several dirty documents can discard all of them at once',
    () async {
      store.files[testPath('one.txt')] = document('one.txt', 'one');
      store.files[testPath('two.txt')] = document('two.txt', 'two');
      final one = await openOne();
      await workspace.open(testPath('two.txt'));
      one.editor.text.text = 'dropped';
      workspace.active!.editor.text.text = 'dropped too';
      dialogs.bulkChoice = BulkCloseChoice.discardAll;
      expect(await workspace.confirmQuit(), isTrue);
      expect(store.writes, isEmpty);
      expect(store.files[testPath('one.txt')]!.text, 'disk');
    },
  );

  test('a failed bulk save aborts the quit and keeps every document', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'one');
    store.files[testPath('two.txt')] = document('two.txt', 'two');
    final one = await openOne();
    await workspace.open(testPath('two.txt'));
    one.editor.text.text = 'edited one';
    workspace.active!.editor.text.text = 'edited two';
    store.writeError = const FileSystemException('Disk full');
    dialogs.bulkChoice = BulkCloseChoice.saveAll;
    expect(await workspace.confirmQuit(), isFalse);
    expect(workspace.documents, hasLength(2));
    expect(one.editor.isDirty, isTrue);
    // The failure names the file that could not be written.
    expect(workspace.error, contains(one.name));
    expect(workspace.error, contains('Disk full'));
    expect(workspace.interactionLocked, isFalse);
  });

  test('a single dirty document still gets its own close question', () async {
    final tab = workspace.newDocument()!..editor.text.text = 'only one';
    dialogs.choices.add(CloseChoice.discard);
    expect(await workspace.confirmQuit(), isTrue);
    expect(dialogs.bulkAsked, isEmpty);
    expect(dialogs.asked, [tab.name]);
  });

  test('two tabs with one dirty still ask per file', () async {
    await openOne();
    final scratch = workspace.newDocument()!..editor.text.text = 'scratch';
    dialogs.choices.add(CloseChoice.discard);
    expect(await workspace.confirmQuit(), isTrue);
    expect(dialogs.bulkAsked, isEmpty);
    expect(dialogs.asked, [scratch.name]);
  });

  test('Save All with a canceled destination aborts the quit', () async {
    final first = workspace.newDocument()!..editor.text.text = 'first';
    final second = workspace.newDocument()!..editor.text.text = 'second';
    dialogs.bulkChoice = BulkCloseChoice.saveAll;
    dialogs.savePath = null;
    expect(await workspace.confirmQuit(), isFalse);
    expect(workspace.documents, [first, second]);
    expect(first.editor.isDirty, isTrue);
    expect(second.editor.isDirty, isTrue);
    // A declined destination is a choice, not a failure: nothing was written
    // and the user is not shown an error.
    expect(store.writes, isEmpty);
    expect(workspace.error, isNull);
    expect(workspace.interactionLocked, isFalse);
  });

  test('quit Save persists while editing stays locked', () async {
    final tab = workspace.newDocument()!
      ..editor.text.text = 'persist before quit';
    dialogs.choices.add(CloseChoice.save);
    dialogs.savePath = testPath('quit.txt');
    expect(await workspace.confirmQuit(), isTrue);
    expect(store.files[testPath('quit.txt')]!.text, 'persist before quit');
    expect(tab.editor.isDirty, isFalse);
    expect(workspace.interactionLocked, isTrue);
  });

  test(
    'native opens queued during a close dialog arrive after cancellation',
    () async {
      workspace.newDocument()!.editor.text.text = 'dirty';
      store.files[testPath('incoming.txt')] = document(
        'incoming.txt',
        'incoming',
      );
      dialogs.choiceGate = Completer<CloseChoice>();
      final quitting = workspace.confirmQuit();
      final opening = workspace.open(testPath('incoming.txt'));
      expect(workspace.documents.length, 1);
      dialogs.choiceGate!.complete(CloseChoice.cancel);
      expect(await quitting, isFalse);
      await opening;
      expect(workspace.documents.length, 2);
      expect(workspace.active!.name, 'incoming.txt');
    },
  );
  test(
    'Save As cannot overwrite another tab through a directory alias',
    () async {
      if (Platform.isWindows) {
        return; // Creating links needs developer privileges.
      }
      final directory = await Directory.systemTemp.createTemp(
        'planchette-alias-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final real = await Directory(paths.join(directory.path, 'real')).create();
      final alias = await Link(
        paths.join(directory.path, 'alias'),
      ).create(real.path);
      final file = await File(
        paths.join(real.path, 'open.txt'),
      ).writeAsString('on disk');
      final local = DocumentWorkspace(
        store: LocalDocumentStore(),
        dialogs: dialogs,
      );
      addTearDown(local.dispose);
      await local.open(file.path);
      final original = local.active!..editor.text.text = 'unsaved original';
      final replacement = local.newDocument()!
        ..editor.text.text = 'replacement';
      dialogs.savePath = paths.join(alias.path, 'open.txt');
      expect(await local.save(replacement, saveAs: true), isFalse);
      expect(await file.readAsString(), 'on disk');
      expect(original.editor.text.text, 'unsaved original');
      expect(replacement.path, isNull);
    },
  );
  test(
    'Windows path case variants reuse tabs and refuse another tab target',
    () async {
      final windows = paths.Context(
        style: paths.Style.windows,
        current: r'C:\Notes',
      );
      final memory = MemoryDocuments(pathContext: windows);
      final local = DocumentWorkspace(
        store: memory,
        dialogs: dialogs,
        pathContext: windows,
      );
      addTearDown(local.dispose);
      const originalPath = r'C:\Notes\Example.txt';
      memory.files[originalPath] = TextDocument(
        file: File(originalPath),
        text: 'original',
        hasUtf8Bom: false,
        lineEnding: LineEnding.lf,
        sha256: 'baseline',
      );
      await local.open(originalPath);
      final original = local.active!;
      await local.open(r'c:\notes\EXAMPLE.TXT');
      expect(local.documents, [original]);
      final replacement = local.newDocument()!
        ..editor.text.text = 'replacement';
      dialogs.savePath = r'c:\notes\EXAMPLE.TXT';
      expect(await local.save(replacement, saveAs: true), isFalse);
      expect(memory.writes, isEmpty);
    },
  );
  test('case-variant Save As cannot overwrite another open tab', () async {
    final directory = await Directory.systemTemp.createTemp('planchette-case-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File(
      paths.join(directory.path, 'README.md'),
    ).writeAsString('on disk');
    final variant = File(paths.join(directory.path, 'readme.MD'));
    if (!await variant.exists()) {
      markTestSkipped('The temporary volume is case-sensitive.');
      return;
    }
    expect(await FileSystemEntity.identical(file.path, variant.path), isTrue);
    final local = DocumentWorkspace(
      store: LocalDocumentStore(),
      dialogs: dialogs,
    );
    addTearDown(local.dispose);
    await local.open(file.path);
    final original = local.active!..editor.text.text = 'unsaved original';
    final replacement = local.newDocument()!..editor.text.text = 'replacement';
    dialogs.savePath = variant.path;
    expect(await local.save(replacement, saveAs: true), isFalse);
    expect(await file.readAsString(), 'on disk');
    expect(original.editor.text.text, 'unsaved original');
    expect(replacement.path, isNull);
  });

  test(
    'case-variant Save As retains the original external-change baseline',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'planchette-case-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        paths.join(directory.path, 'README.md'),
      ).writeAsString('baseline');
      final variant = File(paths.join(directory.path, 'readme.MD'));
      if (!await variant.exists()) {
        markTestSkipped('The temporary volume is case-sensitive.');
        return;
      }
      expect(await FileSystemEntity.identical(file.path, variant.path), isTrue);
      final local = DocumentWorkspace(
        store: LocalDocumentStore(),
        dialogs: dialogs,
      );
      addTearDown(local.dispose);
      await local.open(file.path);
      final tab = local.active!..editor.text.text = 'local edit';
      final baseline = tab.baseline!.sha256;
      await file.writeAsString('external edit');
      dialogs.savePath = variant.path;
      expect(await local.save(tab, saveAs: true), isFalse);
      expect(await file.readAsString(), 'external edit');
      expect(tab.baseline!.sha256, baseline);
      expect(tab.editor.text.text, 'local edit');
      expect(tab.editor.isDirty, isTrue);
    },
  );
  test(
    'Save As continues to refuse a final symbolic-link destination',
    () async {
      if (Platform.isWindows) {
        markTestSkipped(
          'Creating Windows links requires developer privileges.',
        );
        return;
      }
      final directory = await Directory.systemTemp.createTemp(
        'planchette-final-link-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final target = await File(
        paths.join(directory.path, 'target.txt'),
      ).writeAsString('target');
      final link = await Link(
        paths.join(directory.path, 'link.txt'),
      ).create(target.path);
      final local = DocumentWorkspace(
        store: LocalDocumentStore(),
        dialogs: dialogs,
      );
      addTearDown(local.dispose);
      final tab = local.newDocument()!..editor.text.text = 'replacement';
      dialogs.savePath = link.path;
      expect(await local.save(tab, saveAs: true), isFalse);
      expect(await target.readAsString(), 'target');
      expect(
        await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(tab.path, isNull);
    },
  );

  test('a failed save retires its banner when that document saves', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original');
    await workspace.open(testPath('one.txt'));
    final tab = workspace.active!..editor.text.text = 'edited';
    store.writeError = const FileSystemException('Disk full');
    expect(await workspace.save(tab), isFalse);
    expect(workspace.error, contains('Disk full'));

    store.writeError = null;
    expect(await workspace.save(tab), isTrue);
    expect(workspace.error, isNull);
  });

  test('a success on one document keeps another failure visible', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original');
    await workspace.open(testPath('one.txt'));
    final opened = workspace.active!;
    final draft = workspace.newDocument()!..editor.text.text = 'draft';
    dialogs.savePath = testPath('one.txt');
    expect(await workspace.save(draft), isFalse);
    expect(workspace.error, contains('already open'));

    opened.editor.text.text = 'edited';
    expect(await workspace.save(opened), isTrue);
    expect(workspace.error, contains('already open'));
  });

  test('a failed open retires its banner when that path opens', () async {
    await workspace.open(testPath('missing.txt'));
    expect(workspace.error, contains('Could not open'));

    store.files[testPath('missing.txt')] = document('missing.txt', 'arrived');
    await workspace.open(testPath('missing.txt'));
    expect(workspace.error, isNull);
  });

  test('a save success does not clear an unrelated open failure', () async {
    await workspace.open(testPath('missing.txt'));
    expect(workspace.error, contains('Could not open'));

    final tab = workspace.newDocument()!..editor.text.text = 'draft';
    dialogs.savePath = testPath('draft.txt');
    expect(await workspace.save(tab), isTrue);
    expect(workspace.error, contains('missing.txt'));
  });

  test('a quit failure survives unrelated successes', () async {
    final tab = workspace.newDocument()!..editor.text.text = 'draft';
    dialogs.savePath = testPath('draft.txt');
    workspace.quitFailed(StateError('destroy failed'));
    expect(workspace.error, contains('Could not close Planchette'));

    expect(await workspace.save(tab), isTrue);
    expect(workspace.error, contains('Could not close Planchette'));
  });

  test('a still-opening refusal clears when the load completes', () async {
    store.files[testPath('slow.txt')] = document('slow.txt', 'on disk');
    store.loadGate = Completer<void>();
    final opening = workspace.open(testPath('slow.txt'));
    await Future<void>.delayed(Duration.zero);
    final tab = workspace.active!;
    expect(tab.editor.isLoading, isTrue);

    expect(await workspace.save(tab), isFalse);
    expect(workspace.error, contains('still opening'));

    store.loadGate!.complete();
    await opening;
    expect(workspace.error, isNull);
  });

  test('closing a tab retires its own save failure', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original');
    await workspace.open(testPath('one.txt'));
    final tab = workspace.active!..editor.text.text = 'edited';
    store.writeError = const FileSystemException('Disk full');
    expect(await workspace.save(tab), isFalse);
    expect(workspace.error, contains('Disk full'));

    dialogs.choices.add(CloseChoice.discard);
    expect(await workspace.closeTab(tab), isTrue);
    expect(workspace.error, isNull);
  });

  test('closing an unrelated tab keeps another document failure', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original one');
    store.files[testPath('two.txt')] = document('two.txt', 'original two');
    await workspace.open(testPath('one.txt'));
    final file = workspace.active!..editor.text.text = 'edited one';
    await workspace.open(testPath('two.txt'));
    final other = workspace.active!;
    store.writeError = const FileSystemException('Disk full');
    expect(await workspace.save(file), isFalse);
    expect(workspace.error, contains('one.txt'));

    expect(await workspace.closeTab(other), isTrue);
    expect(workspace.error, contains('one.txt'));
    expect(workspace.documents, [file]);
  });

  test('closing an unrelated tab keeps a refusal that still holds', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original one');
    store.files[testPath('two.txt')] = document('two.txt', 'original two');
    await workspace.open(testPath('one.txt'));
    final saving = workspace.active!..editor.text.text = 'edited one';
    await workspace.open(testPath('two.txt'));
    final other = workspace.active!;
    store.writeGate = Completer<void>();
    final save = workspace.save(saving);
    await pumpEventQueue();

    expect(await workspace.closeTab(saving), isFalse);
    expect(workspace.error, contains('one.txt is still being saved'));
    // one.txt is still saving, so the refusal is still true after an
    // unrelated tab goes away.
    expect(await workspace.closeTab(other), isTrue);
    expect(workspace.error, contains('one.txt is still being saved'));

    store.writeGate!.complete();
    expect(await save, isTrue);
  });

  test('Save All writes every dirty document', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original');
    await workspace.open(testPath('one.txt'));
    final file = workspace.active!..editor.text.text = 'edited';
    final draft = workspace.newDocument()!..editor.text.text = 'fresh draft';
    dialogs.savePath = testPath('draft.txt');

    expect(await workspace.saveAll(), isTrue);
    expect(store.files[testPath('one.txt')]!.text, 'edited');
    expect(store.files[testPath('draft.txt')]!.text, 'fresh draft');
    expect(file.editor.isDirty, isFalse);
    expect(draft.editor.isDirty, isFalse);
    expect(workspace.error, isNull);
  });

  test('Save All reports partial failures with the saved count', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original one');
    store.files[testPath('two.txt')] = document('two.txt', 'original two');
    await workspace.open(testPath('one.txt'));
    final first = workspace.active!;
    await workspace.open(testPath('two.txt'));
    final second = workspace.active!;
    first.editor.text.text = 'edited one';
    second.editor.text.text = 'edited two';
    store.writeFailures[second.path!] = const FileSystemException('Disk full');

    expect(await workspace.saveAll(), isFalse);
    expect(store.files[testPath('one.txt')]!.text, 'edited one');
    expect(store.files[testPath('two.txt')]!.text, 'original two');
    expect(workspace.error, contains('Saved 1 of 2'));
    expect(workspace.error, contains('two.txt ('));
    expect(workspace.error, contains('Disk full'));
    expect(first.editor.isDirty, isFalse);
    expect(second.editor.isDirty, isTrue);
  });

  test('a lone Save All failure keeps the individual save message', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original');
    await workspace.open(testPath('one.txt'));
    final tab = workspace.active!..editor.text.text = 'edited';
    store.writeError = const FileSystemException('Disk full');

    expect(await workspace.saveAll(), isFalse);
    expect(workspace.error, contains('Could not save one.txt'));
    expect(workspace.error, contains('Disk full'));
    expect(workspace.error, isNot(contains('Saved')));
    expect(tab.editor.isDirty, isTrue);
  });

  test('Save All keeps a declined destination out of the report', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original');
    await workspace.open(testPath('one.txt'));
    final file = workspace.active!..editor.text.text = 'edited';
    final draft = workspace.newDocument()!..editor.text.text = 'fresh draft';
    // The save-path prompt returns null: the untitled draft is declined.

    expect(await workspace.saveAll(), isFalse);
    expect(file.editor.isDirty, isFalse);
    expect(draft.editor.isDirty, isTrue);
    expect(store.writes, hasLength(1));
    expect(workspace.error, isNull);
  });

  test('Save All with nothing dirty succeeds as a no-op', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'on disk');
    await workspace.open(testPath('one.txt'));
    workspace.newDocument();

    expect(await workspace.saveAll(), isTrue);
    expect(store.writes, isEmpty);
    expect(workspace.error, isNull);
  });

  test('Save All stays silent while the workspace is locked', () async {
    final tab = workspace.newDocument()!..editor.text.text = 'keep me';
    dialogs.choiceGate = Completer<CloseChoice>();
    final closing = workspace.closeTab(tab);
    await Future<void>.delayed(Duration.zero);

    expect(await workspace.saveAll(), isFalse);
    expect(store.writes, isEmpty);
    expect(workspace.error, isNull);

    dialogs.choiceGate!.complete(CloseChoice.cancel);
    expect(await closing, isFalse);
  });

  test('a second Save All cannot interleave with a running one', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original one');
    store.files[testPath('two.txt')] = document('two.txt', 'original two');
    await workspace.open(testPath('one.txt'));
    final first = workspace.active!..editor.text.text = 'edited one';
    await workspace.open(testPath('two.txt'));
    final second = workspace.active!..editor.text.text = 'edited two';
    store.writeGate = Completer<void>();

    final run = workspace.saveAll();
    await Future<void>.delayed(Duration.zero);
    final overlap = workspace.saveAll();
    store.writeGate!.complete();

    expect(await run, isTrue);
    expect(await overlap, isFalse);
    expect(store.writes, hasLength(2));
    expect(first.editor.isDirty, isFalse);
    expect(second.editor.isDirty, isFalse);
    expect(workspace.error, isNull);
  });

  test('a tab closed mid Save All does not fail the run', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original one');
    store.files[testPath('two.txt')] = document('two.txt', 'original two');
    await workspace.open(testPath('one.txt'));
    final file = workspace.active!..editor.text.text = 'edited one';
    await workspace.open(testPath('two.txt'));
    final closing = workspace.active!..editor.text.text = 'edited two';
    dialogs.choices.add(CloseChoice.discard);
    store.writeGate = Completer<void>();

    final run = workspace.saveAll();
    await Future<void>.delayed(Duration.zero);
    expect(await workspace.closeTab(closing), isTrue);
    store.writeGate!.complete();

    expect(await run, isTrue);
    expect(workspace.error, isNull);
    expect(file.editor.isDirty, isFalse);
    expect(workspace.documents, [file]);
  });

  test('Save All reports what a modal stopped it from reaching', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original one');
    store.files[testPath('two.txt')] = document('two.txt', 'original two');
    await workspace.open(testPath('one.txt'));
    final file = workspace.active!..editor.text.text = 'edited one';
    await workspace.open(testPath('two.txt'));
    final other = workspace.active!..editor.text.text = 'edited two';
    store.writeError = const FileSystemException('Disk full');
    store.writeGate = Completer<void>();
    dialogs.choiceGate = Completer<CloseChoice>();

    final run = workspace.saveAll();
    await Future<void>.delayed(Duration.zero);
    final closing = workspace.closeTab(other);
    await Future<void>.delayed(Duration.zero);
    expect(workspace.interactionLocked, isTrue);
    store.writeGate!.complete();

    expect(await run, isFalse);
    expect(workspace.error, contains('Saved 0 of 2'));
    expect(workspace.error, contains('one.txt'));
    expect(file.editor.isDirty, isTrue);
    expect(other.editor.isDirty, isTrue);

    dialogs.choiceGate!.complete(CloseChoice.cancel);
    expect(await closing, isFalse);
  });

  test('Save All counts a vanished tab in the failure total', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original one');
    store.files[testPath('two.txt')] = document('two.txt', 'original two');
    await workspace.open(testPath('one.txt'));
    final file = workspace.active!..editor.text.text = 'edited one';
    await workspace.open(testPath('two.txt'));
    final closing = workspace.active!..editor.text.text = 'edited two';
    store.writeError = const FileSystemException('Disk full');
    store.writeGate = Completer<void>();

    final run = workspace.saveAll();
    await Future<void>.delayed(Duration.zero);
    dialogs.choices.add(CloseChoice.discard);
    expect(await workspace.closeTab(closing), isTrue);
    store.writeGate!.complete();

    expect(await run, isFalse);
    expect(workspace.error, contains('Saved 0 of 2'));
    expect(workspace.error, contains('one.txt'));
    expect(file.editor.isDirty, isTrue);
  });

  test('Save All names the documents it never reached', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original one');
    store.files[testPath('two.txt')] = document('two.txt', 'original two');
    await workspace.open(testPath('one.txt'));
    final file = workspace.active!..editor.text.text = 'edited one';
    await workspace.open(testPath('two.txt'));
    final other = workspace.active!..editor.text.text = 'edited two';
    store.writeGate = Completer<void>();
    dialogs.choiceGate = Completer<CloseChoice>();

    final run = workspace.saveAll();
    await Future<void>.delayed(Duration.zero);
    final closing = workspace.closeTab(other);
    await Future<void>.delayed(Duration.zero);
    expect(workspace.interactionLocked, isTrue);
    store.writeGate!.complete();

    expect(await run, isFalse);
    expect(
      workspace.error,
      'Save All stopped with 1 document not saved: two.txt.',
    );
    expect(file.editor.isDirty, isFalse);
    expect(other.editor.isDirty, isTrue);

    dialogs.choiceGate!.complete(CloseChoice.cancel);
    expect(await closing, isFalse);
  });

  test('a retried save keeps a Save All summary naming others', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original one');
    store.files[testPath('two.txt')] = document('two.txt', 'original two');
    await workspace.open(testPath('one.txt'));
    final first = workspace.active!..editor.text.text = 'edited one';
    await workspace.open(testPath('two.txt'));
    final second = workspace.active!..editor.text.text = 'edited two';
    store.writeFailures[first.path!] = const FileSystemException('Disk full');
    store.writeFailures[second.path!] = const FileSystemException('Disk full');
    expect(await workspace.saveAll(), isFalse);
    expect(workspace.error, contains('Saved 0 of 2'));

    // two.txt then saves on its own, but one.txt is still unsaved and the
    // summary is the only thing still saying so.
    store.writeFailures.remove(second.path!);
    expect(await workspace.save(second), isTrue);
    expect(workspace.error, contains('one.txt'));
  });

  test(
    'a tab saved and closed while Save All waited is not a failure',
    () async {
      store.files[testPath('two.txt')] = document('two.txt', 'original two');
      store.files[testPath('three.txt')] = document('three.txt', 'original 3');
      await workspace.open(testPath('two.txt'));
      final second = workspace.active!..editor.text.text = 'edited two';
      await workspace.open(testPath('three.txt'));
      final third = workspace.active!..editor.text.text = 'edited three';

      // Close two.txt with Save and hold its write, so Save All queues its own
      // request for two.txt behind the close's save.
      dialogs.choices.add(CloseChoice.save);
      store.writeGate = Completer<void>();
      final closing = workspace.closeTab(second);
      await pumpEventQueue();
      final all = workspace.saveAll();
      await pumpEventQueue();
      store.writeGate!.complete();

      expect(await closing, isTrue);
      expect(await all, isTrue);
      expect(workspace.documents, [third]);
      expect(store.files[testPath('two.txt')]!.text, 'edited two');
      expect(store.files[testPath('three.txt')]!.text, 'edited three');
      expect(workspace.error, isNull);
    },
  );

  test('a Save All summary quotes each failure with one full stop', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'original one');
    store.files[testPath('two.txt')] = document('two.txt', 'original two');
    await workspace.open(testPath('one.txt'));
    final first = workspace.active!..editor.text.text = 'edited one';
    await workspace.open(testPath('two.txt'));
    final second = workspace.active!..editor.text.text = 'edited two';
    store.writeFailures[first.path!] = StateError('Changed externally.');
    store.writeFailures[second.path!] = StateError('Changed externally.');

    expect(await workspace.saveAll(), isFalse);
    expect(workspace.error, contains('(Bad state: Changed externally)'));
    expect(workspace.error, isNot(contains('.)')));
  });

  test('quit during a save says why the window stays open', () async {
    final tab = workspace.newDocument()!..editor.text.text = 'saving';
    dialogs.savePath = testPath('one.txt');
    store.writeGate = Completer<void>();
    final saving = workspace.save(tab);
    await pumpEventQueue();
    expect(await workspace.confirmQuit(), isFalse);
    expect(workspace.error, contains('save'));
    store.writeGate!.complete();
    expect(await saving, isTrue);

    // The notice described work that has now finished, so it must not linger.
    expect(workspace.error, isNull);
    expect(await workspace.confirmQuit(), isTrue);
  });

  test('quit during an open says why the window stays open', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'disk');
    store.loadGate = Completer<void>();
    final opening = workspace.open(testPath('one.txt'));
    await pumpEventQueue();
    expect(await workspace.confirmQuit(), isFalse);
    expect(workspace.error, contains('open'));
    store.loadGate!.complete();
    await opening;
    expect(workspace.error, isNull);
    expect(await workspace.confirmQuit(), isTrue);
  });

  test(
    'a quit notice retires, with a notification, when its wait ends',
    () async {
      final tab = workspace.newDocument()!;
      store.files[testPath('one.txt')] = document('one.txt', 'disk');
      store.loadGate = Completer<void>();
      final opening = workspace.open(testPath('one.txt'));
      await pumpEventQueue();
      expect(await workspace.confirmQuit(), isFalse);
      expect(workspace.error, contains('open'));

      var afterClearing = 0;
      workspace.addListener(() {
        if (workspace.error == null) afterClearing++;
      });
      // Closing an unrelated tab ends nothing the notice is waiting on: the
      // open is still running, so a quit would still be refused.
      expect(await workspace.closeTab(tab), isTrue);
      expect(workspace.error, contains('open'));
      expect(afterClearing, 0);

      store.loadGate!.complete();
      await opening;
      expect(workspace.error, isNull);
      expect(afterClearing, greaterThan(0));
    },
  );

  test('a quit refusal never buries a failure the user must act on', () async {
    final failed = workspace.newDocument()!..editor.text.text = 'doomed';
    dialogs.savePath = testPath('one.txt');
    store.writeError = const FileSystemException('Disk full');
    expect(await workspace.save(failed), isFalse);
    expect(workspace.error, contains('Disk full'));

    store.writeError = null;
    store.writeGate = Completer<void>();
    final other = workspace.newDocument()!..editor.text.text = 'saving';
    dialogs.savePath = testPath('two.txt');
    final saving = workspace.save(other);
    await pumpEventQueue();
    expect(await workspace.confirmQuit(), isFalse);
    expect(workspace.error, contains('Disk full'));
    store.writeGate!.complete();
    expect(await saving, isTrue);
  });

  test(
    'a save finishing does not retire a notice about a running open',
    () async {
      final tab = workspace.newDocument()!..editor.text.text = 'saving';
      dialogs.savePath = testPath('one.txt');
      store.writeGate = Completer<void>();
      final saving = workspace.save(tab);
      await pumpEventQueue();

      store.files[testPath('two.txt')] = document('two.txt', 'disk');
      store.loadGate = Completer<void>();
      final opening = workspace.open(testPath('two.txt'));
      await pumpEventQueue();
      expect(await workspace.confirmQuit(), isFalse);
      expect(workspace.error, contains('open'));

      // The save ends while the open is still running: its notice is still true.
      store.writeGate!.complete();
      expect(await saving, isTrue);
      expect(workspace.error, contains('open'));
      store.loadGate!.complete();
      await opening;
      expect(workspace.error, isNull);
    },
  );

  test('a real failure is not cleared when the busy work finishes', () async {
    final tab = workspace.newDocument()!..editor.text.text = 'saving';
    dialogs.savePath = testPath('one.txt');
    store.writeGate = Completer<void>();
    store.writeError = const FileSystemException('Disk full');
    final saving = workspace.save(tab);
    await pumpEventQueue();
    expect(await workspace.confirmQuit(), isFalse);
    expect(workspace.error, contains('save is still running'));
    store.writeGate!.complete();
    expect(await saving, isFalse);
    expect(workspace.error, contains('Disk full'));
  });

  test('a quit notice about a dialog retires once the dialog ends', () async {
    store.files[testPath('target.txt')] = document('target.txt', 'exists');
    final tab = workspace.newDocument()!..editor.text.text = 'new';
    dialogs.savePath = testPath('target.txt');
    final gate = Completer<void>();
    dialogs.beforeReplace = () => gate.future;
    final saving = workspace.save(tab);
    await pumpEventQueue();
    expect(await workspace.confirmQuit(), isFalse);
    expect(workspace.error, contains('dialog'));

    gate.complete();
    expect(await saving, isTrue);
    expect(workspace.error, isNull);
  });

  test('a quit notice about a cancelled Open dialog retires', () async {
    dialogs.openGate = Completer<List<String>>();
    final opening = workspace.openDialog();
    await pumpEventQueue();
    expect(await workspace.confirmQuit(), isFalse);
    expect(workspace.error, contains('dialog'));

    dialogs.openGate!.complete(const []);
    await opening;
    expect(workspace.error, isNull);
  });

  test('quit Discard All refuses when a document changed under it', () async {
    final first = workspace.newDocument()!..editor.text.text = 'first';
    final second = workspace.newDocument()!..editor.text.text = 'second';
    final clean = workspace.newDocument()!;
    dialogs.bulkGate = Completer<BulkCloseChoice>();
    final quit = workspace.confirmQuit();
    await pumpEventQueue();
    // The answer covers the text the question was asked about; a buffer that
    // moved on meanwhile has edits nobody agreed to drop.
    clean.editor.text.text = 'typed while asked';
    dialogs.bulkGate!.complete(BulkCloseChoice.discardAll);

    expect(await quit, isFalse);
    expect(workspace.documents, [first, second, clean]);
    expect(workspace.error, contains('changed while'));
  });

  test('quit Save All also saves edits made while it was asked', () async {
    for (final name in ['one.txt', 'two.txt', 'three.txt']) {
      store.files[testPath(name)] = document(name, name);
      await workspace.open(testPath(name));
    }
    final [one, two, three] = workspace.documents;
    one.editor.text.text = 'edited one';
    two.editor.text.text = 'edited two';
    dialogs.bulkGate = Completer<BulkCloseChoice>();
    final quit = workspace.confirmQuit();
    await pumpEventQueue();
    expect(dialogs.bulkAsked, [
      ['one.txt', 'two.txt'],
    ]);
    three.editor.text.text = 'typed while asked';
    dialogs.bulkGate!.complete(BulkCloseChoice.saveAll);

    expect(await quit, isTrue);
    expect(store.files[testPath('one.txt')]!.text, 'edited one');
    expect(store.files[testPath('three.txt')]!.text, 'typed while asked');
  });

  test('a failed quit Save All says what was saved and stays open', () async {
    store.files[testPath('one.txt')] = document('one.txt', 'one');
    store.files[testPath('two.txt')] = document('two.txt', 'two');
    await workspace.open(testPath('one.txt'));
    final one = workspace.active!..editor.text.text = 'edited one';
    await workspace.open(testPath('two.txt'));
    final two = workspace.active!..editor.text.text = 'edited two';
    store.writeFailures[two.path!] = const FileSystemException('Disk full');
    dialogs.bulkChoice = BulkCloseChoice.saveAll;

    expect(await workspace.confirmQuit(), isFalse);
    expect(store.files[testPath('one.txt')]!.text, 'edited one');
    expect(workspace.error, contains('Saved 1 of 2'));
    expect(workspace.error, contains('Disk full'));
    expect(workspace.documents, [one, two]);
    expect(workspace.interactionLocked, isFalse);
  });

  test('declining a destination in quit Save All cancels quietly', () async {
    workspace.newDocument()!.editor.text.text = 'first';
    workspace.newDocument()!.editor.text.text = 'second';
    dialogs.bulkChoice = BulkCloseChoice.saveAll;
    dialogs.savePath = null;

    expect(await workspace.confirmQuit(), isFalse);
    // Cancelling the first destination cancels the quit; nobody is asked for
    // the second, and a choice the user made is not an error.
    expect(dialogs.savePrompts, hasLength(1));
    expect(workspace.error, isNull);
    expect(workspace.interactionLocked, isFalse);
  });
  test(
    'closeOthers removes the rest and lands selection on the kept tab',
    () async {
      workspace.newDocument();
      final keep = workspace.newDocument()!;
      workspace.newDocument();
      await workspace.closeOthers(keep);
      expect(workspace.documents, [keep]);
      expect(workspace.active, keep);
    },
  );

  test('a cancelled Close Others leaves the refused tab active', () async {
    workspace.newDocument();
    final keep = workspace.newDocument()!;
    final refused = workspace.newDocument()!..editor.text.text = 'unsaved';
    dialogs.choices.add(CloseChoice.cancel);
    expect(await workspace.closeOthers(keep), isFalse);
    // The prompt showed the refused tab; the user is still looking at it.
    expect(workspace.documents, [keep, refused]);
    expect(workspace.active, refused);
  });

  test('a completed Close Others reports it and selects the kept tab', () {
    workspace.newDocument();
    final keep = workspace.newDocument()!;
    workspace.newDocument();
    return workspace.closeOthers(keep).then((closed) {
      expect(closed, isTrue);
      expect(workspace.active, keep);
    });
  });

  test(
    'closeAllTabs confirms each dirty tab and a cancel stops the sweep',
    () async {
      workspace.newDocument()!.editor.text.text = 'first';
      final second = workspace.newDocument()!..editor.text.text = 'second';
      final third = workspace.newDocument()!..editor.text.text = 'third';
      dialogs.choices.addAll([CloseChoice.discard, CloseChoice.cancel]);
      await workspace.closeAllTabs();
      expect(workspace.documents, [second, third]);
      expect(second.editor.isDirty, isTrue);
      expect(workspace.interactionLocked, isFalse);
    },
  );
}
