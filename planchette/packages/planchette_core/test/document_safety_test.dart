import 'dart:convert';
import 'dart:io';

import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('planchette-安全-');
    directory = Directory(await directory.resolveSymbolicLinks());
    file = File('${directory.path}/café-😀.txt');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'new documents publish complete content without precreating the path',
    () async {
      final digest = await createTextDocument(
        file,
        'first\nsecond\n',
        hasUtf8Bom: true,
        lineEnding: LineEnding.crlf,
        observeTemporary: (temporary) async {
          expect(await file.exists(), isFalse);
          expect(await temporary.readAsBytes(), [
            0xef,
            0xbb,
            0xbf,
            ...utf8.encode('first\r\nsecond\r\n'),
          ]);
        },
      );
      final loaded = await loadTextDocument(file);
      expect(loaded.sha256, digest);
      expect(loaded.text, 'first\nsecond\n');
      expect(loaded.hasUtf8Bom, isTrue);
      expect(loaded.lineEnding, LineEnding.crlf);
      expect(await directory.list().length, 1);
    },
  );

  test(
    'create refuses an occupied destination and leaves its bytes intact',
    () async {
      await file.writeAsString('existing');
      await expectLater(
        createTextDocument(file, 'new'),
        throwsA(isA<TextDocumentException>()),
      );
      expect(await file.readAsString(), 'existing');
      expect(await directory.list().length, 1);
    },
  );

  test(
    'create refuses a destination that appears after the temporary is ready',
    () async {
      await expectLater(
        createTextDocument(
          file,
          'new',
          observeTemporary: (_) => file.writeAsString('raced'),
        ),
        throwsA(isA<TextDocumentException>()),
      );
      expect(await file.readAsString(), 'raced');
      expect(await directory.list().length, 1);
    },
  );

  test(
    'failed create never leaves an empty destination or its temporary',
    () async {
      await expectLater(
        createTextDocument(
          file,
          'new',
          observeTemporary: (_) async => throw StateError('cancel'),
        ),
        throwsStateError,
      );
      expect(await file.exists(), isFalse);
      expect(await directory.list().length, 0);
    },
  );

  test('create refuses a directory', () async {
    await Directory(file.path).create();
    await expectLater(
      createTextDocument(file, 'new'),
      throwsA(isA<TextDocumentException>()),
    );
    expect(await Directory(file.path).exists(), isTrue);
  });

  test('create refuses even a dangling destination link', () async {
    if (Platform.isWindows) return;
    final destination = '${directory.path}/absent';
    final link = Link(file.path);
    await link.create(destination);
    await expectLater(
      createTextDocument(file, 'new'),
      throwsA(isA<TextDocumentException>()),
    );
    expect(await link.target(), destination);
    expect(await File(destination).exists(), isFalse);
  });

  test('managed documents reject a link at open', () async {
    if (Platform.isWindows) return;
    final target = File('${directory.path}/target');
    await target.writeAsString('original');
    await Link(file.path).create(target.path);
    await expectLater(
      loadTextDocument(file),
      throwsA(isA<TextDocumentException>()),
    );
    await expectLater(
      textDocumentSha256(file),
      throwsA(isA<TextDocumentException>()),
    );
    final local = await loadTextDocument(
      file,
      symlinkPolicy: SymlinkPolicy.resolveOnce,
    );
    expect(local.file.path, target.path);
    expect(local.text, 'original');
  });

  test(
    'local open retains the resolved identity when a directory link changes',
    () async {
      if (Platform.isWindows) return;
      final originalDirectory = await Directory(
        '${directory.path}/original',
      ).create();
      final otherDirectory = await Directory(
        '${directory.path}/other',
      ).create();
      final original = File('${originalDirectory.path}/file');
      final other = File('${otherDirectory.path}/file');
      await original.writeAsString('original');
      await other.writeAsString('other');
      final link = await Link(
        '${directory.path}/alias',
      ).create(originalDirectory.path);
      final loaded = await loadTextDocument(
        File('${link.path}/file'),
        symlinkPolicy: SymlinkPolicy.resolveOnce,
      );
      await link.update(otherDirectory.path);
      await saveTextDocument(
        loaded.file,
        'edited',
        expectedSha256: loaded.sha256,
      );
      expect(await original.readAsString(), 'edited');
      expect(await other.readAsString(), 'other');
    },
  );

  test(
    'preserve normalization retains the legacy mixed-ending buffer and save',
    () async {
      const raw = 'a\r\nb\nc\r';
      await file.writeAsString(raw);
      final loaded = await loadTextDocument(
        file,
        normalization: TextNormalization.preserve,
      );
      expect(loaded.text, raw);
      expect(loaded.lineEnding, LineEnding.lf);
      await saveTextDocument(
        file,
        loaded.text,
        expectedSha256: loaded.sha256,
        normalization: TextNormalization.preserve,
      );
      expect(await file.readAsString(), raw);
    },
  );

  test('a BOM-only file survives without becoming text content', () async {
    await file.writeAsBytes([0xef, 0xbb, 0xbf]);
    final loaded = await loadTextDocument(file);
    expect(loaded.text, '');
    expect(loaded.hasUtf8Bom, isTrue);
    await saveTextDocument(
      file,
      '',
      expectedSha256: loaded.sha256,
      hasUtf8Bom: true,
    );
    expect(await file.readAsBytes(), [0xef, 0xbb, 0xbf]);
  });

  test('caps include UTF-8, BOM, and expanded CRLF output bytes', () async {
    await expectLater(
      createTextDocument(
        file,
        'é\n',
        hasUtf8Bom: true,
        lineEnding: LineEnding.crlf,
        maximumBytes: 6,
      ),
      throwsA(isA<TextDocumentException>()),
    );
    expect(await file.exists(), isFalse);
    await createTextDocument(
      file,
      'é\n',
      hasUtf8Bom: true,
      lineEnding: LineEnding.crlf,
      maximumBytes: 7,
    );
    expect(await file.length(), 7);
  });

  test('a snapshot changed and restored around the read is refused', () async {
    await file.writeAsString('original');
    final originalHash = await textDocumentSha256(file);
    var reads = 0;
    await expectLater(
      loadTextDocument(
        file,
        sha256Of: (target) async {
          if (++reads == 1) {
            await target.writeAsString('changed');
          } else {
            await target.writeAsString('original');
          }
          return originalHash;
        },
      ),
      throwsA(isA<TextDocumentException>()),
    );
    expect(await file.readAsString(), 'original');
  });

  test(
    'failure after moving the original restores its complete bytes',
    () async {
      await file.writeAsString('original');
      final baseline = await textDocumentSha256(file);
      await expectLater(
        saveTextDocument(
          file,
          'edited',
          expectedSha256: baseline,
          observeBackup: (_) async => throw StateError('failed'),
        ),
        throwsStateError,
      );
      expect(await file.readAsString(), 'original');
      expect(await directory.list().length, 1);
    },
  );

  test('failed mode restoration leaves the original file intact', () async {
    await file.writeAsString('original');
    final baseline = await textDocumentSha256(file);
    await expectLater(
      saveTextDocument(
        file,
        'edited',
        expectedSha256: baseline,
        observeTemporary: (temporary) async => temporary.delete(),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await file.readAsString(), 'original');
    expect(await directory.list().length, 1);
  });

  test(
    'a recreated target is never overwritten by publication or rollback',
    () async {
      await file.writeAsString('original');
      final baseline = await textDocumentSha256(file);
      File? backup;
      await expectLater(
        saveTextDocument(
          file,
          'edited',
          expectedSha256: baseline,
          observeBackup: (savedOriginal) async {
            backup = savedOriginal;
            await file.writeAsString('concurrent');
          },
        ),
        throwsA(
          isA<TextDocumentException>().having(
            (error) => error.message,
            'recovery path',
            contains('.backup'),
          ),
        ),
      );
      expect(await file.readAsString(), 'concurrent');
      expect(await backup!.readAsString(), 'original');
      expect(await directory.list().length, 2);
    },
  );

  test(
    'digest failure restores original without losing concurrent changes',
    () async {
      await file.writeAsString('external');
      await expectLater(
        saveTextDocument(file, 'edited', expectedSha256: 'outdated'),
        throwsA(isA<TextDocumentException>()),
      );
      expect(await file.readAsString(), 'external');
      expect(await directory.list().length, 1);
    },
  );

  test(
    'all host prefixes preserve executable permissions and temp privacy',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      await file.writeAsString('script');
      await Process.run('chmod', ['755', file.path]);
      for (final prefix in ['.planchette', '.poltergeist', '.seance']) {
        await saveTextDocument(
          file,
          'edited',
          expectedSha256: await textDocumentSha256(file),
          temporaryPrefix: prefix,
          observeTemporary: (temporary) async {
            expect(temporary.path, contains('$prefix-'));
            expect((await temporary.stat()).mode & 0x1ff, 0x180);
          },
        );
        expect((await file.stat()).mode & 0x1ff, 0x1ed);
      }
    },
  );

  test('invalid policies fail before creating a temporary file', () async {
    await expectLater(
      createTextDocument(file, 'text', temporaryPrefix: '/escape'),
      throwsArgumentError,
    );
    await expectLater(
      createTextDocument(file, 'text', maximumBytes: -1),
      throwsArgumentError,
    );
    expect(await directory.list().length, 0);
  });
}
