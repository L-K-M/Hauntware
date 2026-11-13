import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/services/save_siblings.dart';

import 'document_workspace_test.dart';

const _uuid = '0b6c7a52-6a6f-4d55-9a3c-2f1d1f3f9e01';
const _otherUuid = '7d3f1c11-2b4b-4c39-8f0e-6a2a9b8c4d22';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalSaveSiblings', () {
    late Directory directory;
    late File document;
    final now = DateTime.now();
    final old = now.subtract(const Duration(hours: 1));

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('planchette-siblings-');
      document = File(paths.join(directory.path, 'notes.txt'));
      await document.writeAsString('current');
    });
    tearDown(() => directory.delete(recursive: true));

    Future<File> sibling(String name, {DateTime? modified}) async {
      final file = File(paths.join(directory.path, name));
      await file.writeAsString('left over');
      await file.setLastModified(modified ?? old);
      return file;
    }

    LocalSaveSiblings siblings() => LocalSaveSiblings(clock: () => now);

    test('finds the backup and staging files a save left behind', () async {
      final backup = await sibling('notes.txt.planchette-$_uuid.backup');
      final edit = await sibling('notes.txt.planchette-$_otherUuid.edit');
      // Not this document's: other names, another prefix, a longer name.
      await sibling('notes.txt.bak');
      await sibling('notes.txt.seance-$_uuid.backup');
      await sibling('notes.txt.old.planchette-$_uuid.backup');
      await sibling('notes.planchette-$_uuid.backup');

      final found = await siblings().find(document.path);

      expect(found.map((sibling) => sibling.path).toSet(), {
        backup.path,
        edit.path,
      });
    });

    test('skips a staging file another save may still be writing', () async {
      await sibling('notes.txt.planchette-$_uuid.edit', modified: now);

      expect(await siblings().find(document.path), isEmpty);
    });

    test('matches a name the save had to shorten', () async {
      // 255 bytes per component, less the 55-byte backup suffix, leaves 200.
      final long = '${'a' * 240}.txt';
      final longDocument = File(paths.join(directory.path, long));
      await longDocument.writeAsString('current');
      final shortened = await sibling(
        '${long.substring(0, 200)}.planchette-$_uuid.backup',
      );
      // Too short to be a shortened form of the long name.
      await sibling('${long.substring(0, 150)}.planchette-$_uuid.backup');

      final found = await siblings().find(longDocument.path);

      expect(found.map((sibling) => sibling.path), [shortened.path]);
    });

    test('deletes a sibling that is as it was found', () async {
      final backup = await sibling('notes.txt.planchette-$_uuid.backup');
      final found = await siblings().find(document.path);

      await siblings().delete(document.path, found.single);

      expect(await backup.exists(), isFalse);
    });

    test('keeps a sibling that changed since it was found', () async {
      final backup = await sibling('notes.txt.planchette-$_uuid.backup');
      final found = await siblings().find(document.path);
      await backup.writeAsString('someone is writing this');

      await expectLater(
        siblings().delete(document.path, found.single),
        throwsA(isA<SaveSiblingException>()),
      );
      expect(await backup.exists(), isTrue);
    });

    test('treats a sibling that is already gone as deleted', () async {
      final backup = await sibling('notes.txt.planchette-$_uuid.backup');
      final found = await siblings().find(document.path);
      await backup.delete();

      await siblings().delete(document.path, found.single);

      expect(await backup.exists(), isFalse);
    });

    // A save interrupted between its renames leaves the document missing,
    // the earlier text in the backup and the newest in the staging file.
    for (final kind in ['backup', 'edit']) {
      test('keeps a .$kind file once the document is gone', () async {
        final left = await sibling('notes.txt.planchette-$_uuid.$kind');
        final found = await siblings().find(document.path);
        await document.delete();

        await expectLater(
          siblings().delete(document.path, found.single),
          throwsA(
            isA<SaveSiblingException>().having(
              (error) => error.message,
              'message',
              contains('only copy'),
            ),
          ),
        );
        expect(await left.exists(), isTrue);
      });
    }
  });

  group('the workspace', () {
    late MemoryDocuments store;
    late FakeDialogs dialogs;
    late _FakeSiblings siblings;
    late DocumentWorkspace workspace;

    setUp(() {
      store = MemoryDocuments();
      dialogs = FakeDialogs();
      siblings = _FakeSiblings();
      workspace = DocumentWorkspace(
        store: store,
        dialogs: dialogs,
        saveSiblings: siblings,
      );
      store.files[testPath('notes.txt')] = document('notes.txt', 'current');
      store.files[testPath('notes.txt.planchette-$_uuid.backup')] = document(
        'notes.txt.planchette-$_uuid.backup',
        'earlier',
      );
      siblings.found[testPath('notes.txt')] = [
        (
          path: testPath('notes.txt.planchette-$_uuid.backup'),
          stamp: (modified: DateTime.utc(2026), size: 7),
        ),
      ];
    });
    tearDown(() => workspace.dispose());

    test('asks about siblings once the document opens', () async {
      await workspace.open(testPath('notes.txt'));
      await pumpEventQueue();

      final (name, asked) = dialogs.siblingsAsked.single;
      expect(name, 'notes.txt');
      expect(asked, ['notes.txt.planchette-$_uuid.backup']);
      expect(siblings.deleted, isEmpty);
    });

    test('Open opens each sibling beside the document', () async {
      dialogs.siblingChoice = SaveSiblingChoice.open;

      await workspace.open(testPath('notes.txt'));
      await pumpEventQueue();

      expect(workspace.documents.map((tab) => tab.path), [
        testPath('notes.txt'),
        testPath('notes.txt.planchette-$_uuid.backup'),
      ]);
    });

    test('Delete removes them and reports one it could not', () async {
      dialogs.siblingChoice = SaveSiblingChoice.delete;
      siblings.found[testPath('notes.txt')]!.add((
        path: testPath('notes.txt.planchette-$_otherUuid.edit'),
        stamp: (modified: DateTime.utc(2026), size: 3),
      ));
      siblings.refuse.add(testPath('notes.txt.planchette-$_otherUuid.edit'));

      await workspace.open(testPath('notes.txt'));
      await pumpEventQueue();

      expect(siblings.deleted, [
        testPath('notes.txt.planchette-$_uuid.backup'),
      ]);
      expect(
        workspace.error,
        contains('notes.txt.planchette-$_otherUuid.edit: it changed'),
      );
    });

    test('a document is asked about once per session', () async {
      await workspace.open(testPath('notes.txt'));
      await pumpEventQueue();
      await workspace.closeTab(workspace.active!);
      await workspace.open(testPath('notes.txt'));
      await pumpEventQueue();

      expect(dialogs.siblingsAsked, hasLength(1));
    });

    test('a failed check is asked again at the next open', () async {
      siblings.failFind = true;
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);

      await workspace.open(testPath('notes.txt'));
      await pumpEventQueue();

      expect(reported.single.exception, isA<StateError>());
      expect(dialogs.siblingsAsked, isEmpty);

      siblings.failFind = false;
      await workspace.closeTab(workspace.active!);
      await workspace.open(testPath('notes.txt'));
      await pumpEventQueue();

      expect(dialogs.siblingsAsked, hasLength(1));
    });

    test('Delete reports an unexpected failure with the rest', () async {
      final backup = testPath('notes.txt.planchette-$_uuid.backup');
      siblings.crash.add(backup);
      dialogs.siblingChoice = SaveSiblingChoice.delete;
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);

      await workspace.open(testPath('notes.txt'));
      await pumpEventQueue();

      expect(reported.single.exception, isA<StateError>());
      expect(workspace.error, contains(paths.basename(backup)));
    });

    test('nothing is asked without siblings', () async {
      siblings.found.clear();

      await workspace.open(testPath('notes.txt'));
      await pumpEventQueue();

      expect(dialogs.siblingsAsked, isEmpty);
    });
  });
}

final class _FakeSiblings implements SaveSiblings {
  final found = <String, List<SaveSibling>>{};
  final deleted = <String>[];
  final refuse = <String>{};
  final crash = <String>{};
  var failFind = false;

  @override
  Future<List<SaveSibling>> find(String documentPath) async {
    if (failFind) throw StateError('cannot look');
    return found[documentPath] ?? const [];
  }

  @override
  Future<void> delete(String documentPath, SaveSibling sibling) async {
    if (refuse.contains(sibling.path)) {
      throw const SaveSiblingException('it changed since it was found');
    }
    if (crash.contains(sibling.path)) throw StateError('cannot delete');
    deleted.add(sibling.path);
  }
}
