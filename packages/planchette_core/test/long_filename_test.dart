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
  }
}
