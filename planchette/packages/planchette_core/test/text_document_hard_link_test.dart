import 'dart:io';

import 'package:planchette_core/planchette_core.dart';
import 'package:planchette_core/src/native_file_operations.dart';
import 'package:test/test.dart';

/// Links [link] to [target] with the platform's own tool: `ln` on POSIX,
/// `mklink /H` on Windows, which needs no elevation for a hard link.
Future<void> _hardLink(File target, File link) async {
  final result = Platform.isWindows
      ? await Process.run('cmd', ['/c', 'mklink', '/H', link.path, target.path])
      : await Process.run('ln', [target.path, link.path]);
  if (result.exitCode != 0) {
    fail('could not create a hard link: ${result.stderr}');
  }
}

void main() {
  late Directory directory;
  late File original;
  late File other;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('planchette-links-');
    original = File('${directory.path}${Platform.pathSeparator}notes.txt');
    other = File('${directory.path}${Platform.pathSeparator}alias.txt');
    await original.writeAsString('before\n');
  });

  tearDown(() async {
    if (Platform.isWindows) {
      for (final file in [original, other]) {
        if (file.existsSync()) setWindowsReadOnly(file.path, readOnly: false);
      }
    }
    await directory.delete(recursive: true);
  });

  Future<String> digest(File file) async =>
      (await loadTextDocument(file)).sha256;

  List<String> names() => [
    for (final entry in directory.listSync())
      entry.uri.pathSegments.lastWhere((segment) => segment.isNotEmpty),
  ]..sort();

  test('fileLinkCount reads the hard link count', () async {
    expect(fileLinkCount(original.path), 1);
    await _hardLink(original, other);
    expect(fileLinkCount(original.path), 2);
    expect(fileLinkCount(other.path), 2);
    expect(fileLinkCount('${directory.path}/missing.txt'), isNull);
  });

  test('a hard-linked file is saved in place, so every name sees it', () async {
    await _hardLink(original, other);
    final expected = await digest(original);

    final saved = await saveTextDocument(
      original,
      'after\n',
      expectedSha256: expected,
    );

    expect(await original.readAsString(), 'after\n');
    expect(await other.readAsString(), 'after\n');
    expect(fileLinkCount(original.path), 2);
    expect(saved, await digest(other));
    // The backup was removed and nothing was staged beside the file.
    expect(names(), ['alias.txt', 'notes.txt']);
  });

  test(
    'the backup holds the previous text, owner-only, during the write',
    () async {
      await _hardLink(original, other);
      String? backupText;
      int? backupMode;
      var temporaryStaged = false;

      await saveTextDocument(
        original,
        'after\n',
        expectedSha256: await digest(original),
        observeBackup: (backup) async {
          backupText = await backup.readAsString();
          backupMode = (await backup.stat()).mode & 0x1ff;
        },
        observeTemporary: (_) async => temporaryStaged = true,
      );

      expect(backupText, 'before\n');
      if (!Platform.isWindows) expect(backupMode, 0x180);
      expect(temporaryStaged, isFalse);
    },
  );

  test('a hard-linked file changed elsewhere is refused unchanged', () async {
    await _hardLink(original, other);
    final expected = await digest(original);
    await other.writeAsString('theirs\n');

    await expectLater(
      saveTextDocument(original, 'mine\n', expectedSha256: expected),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          contains('changed in another editor'),
        ),
      ),
    );
    expect(await original.readAsString(), 'theirs\n');
    expect(names(), ['alias.txt', 'notes.txt']);
  });

  test('a read-only hard-linked file is saved and stays read-only', () async {
    await _hardLink(original, other);
    final expected = await digest(original);
    if (Platform.isWindows) {
      setWindowsReadOnly(original.path, readOnly: true);
    } else {
      setFilePermissions(original.path, 0x124); // 0444
    }

    await saveTextDocument(original, 'after\n', expectedSha256: expected);

    expect(await other.readAsString(), 'after\n');
    expect(await isTextDocumentWriteProtected(original), isTrue);
  });

  test('a write that cannot land keeps the backup and names it', () async {
    await _hardLink(original, other);
    String? backupPath;

    await expectLater(
      saveTextDocument(
        original,
        'after\n',
        expectedSha256: await digest(original),
        observeBackup: (backup) async {
          backupPath = backup.path;
          // Neither the new text nor the old can be written here now.
          await original.delete();
          await Directory(original.path).create();
        },
      ),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          contains('preserved at'),
        ),
      ),
    );
    expect(await File(backupPath!).readAsString(), 'before\n');
    expect(await other.readAsString(), 'before\n');
  });

  test('a file with one name keeps the replacing save', () async {
    var temporaryStaged = false;
    await saveTextDocument(
      original,
      'after\n',
      expectedSha256: await digest(original),
      observeTemporary: (_) async => temporaryStaged = true,
    );
    expect(temporaryStaged, isTrue);
    expect(await original.readAsString(), 'after\n');
  });
}
