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
  Object? writeError;
  int version = 0;

  @override
  Future<TextDocument> load(String path) async {
    final value = files[aliases[path] ?? path];
    if (value == null) throw const FileSystemException('Missing file');
    return value;
  }

  @override
  Future<String> canonicalSavePath(String path) async =>
      pathContext.normalize(pathContext.absolute(path));

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
    await writeGate?.future;
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
  }
}

class FakeDialogs implements DocumentDialogs {
  List<String> openPaths = [];
  String? savePath;
  bool replace = true;
  final choices = <CloseChoice>[];
  final asked = <String>[];
  Completer<CloseChoice>? choiceGate;
  Future<void> Function()? beforeReplace;
  final readOnlyChoices = <ReadOnlyChoice>[];
  final readOnlyAsked = <String>[];

  @override
  Future<List<String>> pickOpenFiles() async => openPaths;
  @override
  Future<String?> pickSavePath(String suggestedName) async => savePath;
  @override
  Future<bool> confirmReplace(String path) async {
    await beforeReplace?.call();
    return replace;
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

  test(
    'an unreadable file reports an error without leaving a broken tab',
    () async {
      final original = workspace.newDocument()!;
      await workspace.open(testPath('missing.txt'));
      expect(workspace.documents, [original]);
      expect(workspace.error, contains('Missing file'));
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

  test(
    'quit decisions are shared and cancellation retains every document',
    () async {
      final first = workspace.newDocument()!..editor.text.text = 'first';
      final second = workspace.newDocument()!..editor.text.text = 'second';
      dialogs.choices.addAll([CloseChoice.discard, CloseChoice.cancel]);
      final one = workspace.confirmQuit();
      final two = workspace.confirmQuit();
      expect(identical(one, two), isTrue);
      expect(await one, isFalse);
      expect(await two, isFalse);
      expect(dialogs.asked, [first.name, second.name]);
      expect(workspace.documents, [first, second]);
      expect(workspace.interactionLocked, isFalse);
    },
  );

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
}
