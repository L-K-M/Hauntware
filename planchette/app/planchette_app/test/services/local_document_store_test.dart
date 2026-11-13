import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/services/document_store.dart';

// Save As resolves a chosen symbolic link to the file it names, as opening
// one does, and refuses a link that names no regular file with the reason.
void main() {
  late Directory directory;
  final store = LocalDocumentStore();

  setUp(() async {
    final created = await Directory.systemTemp.createTemp('planchette-links-');
    // macOS temp folders sit behind a link; compare resolved spellings.
    directory = Directory(await created.resolveSymbolicLinks());
  });

  tearDown(() => directory.delete(recursive: true));

  String at(String name) => paths.join(directory.path, name);

  Matcher refusal(String message) => throwsA(
    isA<FileSystemException>().having((e) => e.message, 'message', message),
  );

  group('canonicalSavePath on a symbolic link', () {
    test('resolves a link to a regular file, through a chain', () async {
      final target = await File(at('target.txt')).writeAsString('target');
      await Link(at('first.txt')).create(at('second.txt'));
      await Link(at('second.txt')).create('target.txt');

      expect(await store.canonicalSavePath(at('first.txt')), target.path);
    });

    test('refuses a dangling link and names the missing target', () async {
      await Link(at('link.txt')).create(at('gone.txt'));

      await expectLater(
        store.canonicalSavePath(at('link.txt')),
        refusal(
          'The destination is a symbolic link that points to a file that '
          'does not exist: ${at('gone.txt')}. Choose the file itself, or '
          'create it first.',
        ),
      );
    });

    test('refuses a link to a folder', () async {
      await Directory(at('folder')).create();
      await Link(at('link.txt')).create(at('folder'));

      await expectLater(
        store.canonicalSavePath(at('link.txt')),
        refusal(
          'The destination is a symbolic link to a folder, not a file: '
          '${at('folder')}.',
        ),
      );
    });

    test('refuses a link loop', () async {
      await Link(at('a.txt')).create(at('b.txt'));
      await Link(at('b.txt')).create(at('a.txt'));

      await expectLater(
        store.canonicalSavePath(at('a.txt')),
        refusal(
          'The destination is a symbolic link that loops back on itself, so '
          'it names no file.',
        ),
      );
    });
  }, skip: Platform.isWindows ? 'Creating links needs privileges.' : null);
}
