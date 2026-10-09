import 'dart:convert';
import 'dart:io';

import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

// Common desktop filesystems permit 255-byte path components.
const _maximumNameBytes = 255;

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('names-');
    directory = Directory(await directory.resolveSymbolicLinks());
  });

  tearDown(() => directory.delete(recursive: true));

  test('retains the original directory prefix of relative paths', () async {
    final uniqueName = directory.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .last;
    final file = File('$uniqueName.txt');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });

    await createTextDocument(
      file,
      'content',
      observeTemporary: (temporary) async {
        expect(temporary.path, startsWith('${file.path}.planchette-'));
      },
    );
    expect(await file.readAsString(), 'content');
  });

  test('rejects oversized valid prefixes before writing', () async {
    final file = File('${directory.path}/short.txt');
    await expectLater(
      createTextDocument(
        file,
        'content',
        temporaryPrefix: '.${'p' * _maximumNameBytes}',
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'reason',
          'Prefix is too long.',
        ),
      ),
    );
    expect(await directory.list().length, 0);
  });

  for (final name in [
    '${'a' * (_maximumNameBytes - 4)}.txt',
    '${'😀' * 62}abc.txt',
  ]) {
    final kind = name.startsWith('a') ? 'ASCII' : 'Unicode';

    test('creates and saves a maximum-length $kind filename', () async {
      final file = File('${directory.path}/$name');
      expect(utf8.encode(name).length, _maximumNameBytes);

      for (final prefix in ['.planchette', '.poltergeist', '.seance']) {
        Future<void> checkSibling(File sibling) async {
          expect(sibling.parent.path, directory.path);
          expect(sibling.path, contains('$prefix-'));
          expect(
            utf8.encode(sibling.uri.pathSegments.last).length,
            lessThanOrEqualTo(_maximumNameBytes),
          );
        }

        await createTextDocument(
          file,
          'original',
          temporaryPrefix: prefix,
          observeTemporary: checkSibling,
        );
        final document = await loadTextDocument(file);
        final digest = await saveTextDocument(
          file,
          'edited',
          expectedSha256: document.sha256,
          temporaryPrefix: prefix,
          observeTemporary: checkSibling,
          observeBackup: checkSibling,
        );

        expect((await loadTextDocument(file)).sha256, digest);
        expect(await file.readAsString(), 'edited');
        expect(await directory.list().length, 1);
        await file.delete();
      }
    });

    test('rolls back a conflicting long $kind filename', () async {
      final file = File('${directory.path}/$name');
      await file.writeAsString('original');
      final document = await loadTextDocument(file);
      await file.writeAsString('external');

      await expectLater(
        saveTextDocument(file, 'edited', expectedSha256: document.sha256),
        throwsA(isA<TextDocumentException>()),
      );

      expect(await file.readAsString(), 'external');
      expect(await directory.list().length, 1);
    });

    test('identifies retained backup for a long $kind filename', () async {
      final file = File('${directory.path}/$name');
      await file.writeAsString('original');
      final document = await loadTextDocument(file);
      late File backup;

      // A writer recreating the target must keep its bytes while the error
      // points to the exact shortened recovery name holding the original.
      await expectLater(
        saveTextDocument(
          file,
          'edited',
          expectedSha256: document.sha256,
          observeBackup: (savedOriginal) async {
            backup = savedOriginal;
            await file.writeAsString('concurrent');
          },
        ),
        throwsA(
          isA<TextDocumentException>().having(
            (error) => error.message,
            'retained recovery path',
            predicate<String>((message) => message.contains(backup.path)),
          ),
        ),
      );

      expect(await file.readAsString(), 'concurrent');
      expect(await backup.readAsString(), 'original');
      expect(await directory.list().length, 2);
    });
  }
}
