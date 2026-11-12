import 'dart:io';

import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('planchette-folder-');
    file = File('${directory.path}/doc.txt');
    await file.writeAsString('one\n');
  });

  tearDown(() async {
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.run('chmod', ['755', directory.path]);
    }
    await directory.delete(recursive: true);
  });

  /// Makes [directory] read-only, or returns why this run cannot: root (or a
  /// process with CAP_DAC_OVERRIDE) writes into it regardless.
  Future<String?> restrictFolder() async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      return 'directory mode bits are POSIX-only';
    }
    await Process.run('chmod', ['555', directory.path]);
    final probe = File('${directory.path}/.probe');
    try {
      await probe.create(exclusive: true);
      await probe.delete();
      return 'this process writes into read-only folders';
    } on FileSystemException {
      return null;
    }
  }

  test('a folder that refuses the staging file has its own type', () async {
    final skipped = await restrictFolder();
    if (skipped != null) {
      markTestSkipped(skipped);
      return;
    }
    final digest = await textDocumentSha256(file);

    await expectLater(
      saveTextDocument(file, 'edit\n', expectedSha256: digest),
      throwsA(
        isA<TextDocumentFolderNotWritableException>()
            .having((error) => error.folder, 'folder', directory.path)
            .having(
              (error) => error.message,
              'message',
              startsWith('A temporary file could not be created'),
            ),
      ),
    );
    expect(await file.readAsString(), 'one\n');
  });

  test('a new file in such a folder reports the same type', () async {
    final skipped = await restrictFolder();
    if (skipped != null) {
      markTestSkipped(skipped);
      return;
    }

    await expectLater(
      createTextDocument(File('${directory.path}/new.txt'), 'new\n'),
      throwsA(isA<TextDocumentFolderNotWritableException>()),
    );
  });

  test('a vanished folder is not reported as unwritable', () async {
    final gone = Directory('${directory.path}/gone');
    await gone.create();
    final orphan = File('${gone.path}/doc.txt');
    await orphan.writeAsString('one\n');
    final digest = await textDocumentSha256(orphan);
    await gone.delete(recursive: true);

    await expectLater(
      saveTextDocument(orphan, 'edit\n', expectedSha256: digest),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error,
          'type',
          isNot(isA<TextDocumentFolderNotWritableException>()),
        ),
      ),
    );
  });
}
