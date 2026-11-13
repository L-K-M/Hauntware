@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

/// Sets an extended attribute with the platform's own tool, or returns why
/// this machine cannot: no tool, or a file system without user attributes.
Future<String?> _setAttribute(File file, String name, String value) async {
  final result = Platform.isMacOS
      ? await Process.run('xattr', ['-w', name, value, file.path])
      : await Process.run('python3', [
          '-c',
          'import os, sys; os.setxattr(sys.argv[1], sys.argv[2], '
              'sys.argv[3].encode())',
          file.path,
          name,
          value,
        ]);
  return result.exitCode == 0 ? null : 'cannot set xattrs: ${result.stderr}';
}

Future<String?> _attribute(File file, String name) async {
  final result = Platform.isMacOS
      ? await Process.run('xattr', ['-p', name, file.path])
      : await Process.run('python3', [
          '-c',
          'import os, sys; print(os.getxattr(sys.argv[1], sys.argv[2])'
              '.decode(), end="")',
          file.path,
          name,
        ]);
  if (result.exitCode != 0) return null;
  return (result.stdout as String).trimRight();
}

void main() {
  late Directory directory;
  late File file;
  // Linux keeps user attributes in the user namespace; macOS has none.
  final name = Platform.isMacOS
      ? 'ch.lkmc.planchette-test'
      : 'user.planchette-test';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('planchette-xattr-');
    file = File('${directory.path}/doc.txt');
    await file.writeAsString('one\n');
  });
  tearDown(() => directory.delete(recursive: true));

  test('a save keeps the file\'s extended attributes', () async {
    final skipped = await _setAttribute(file, name, 'kept');
    if (skipped != null) {
      markTestSkipped(skipped);
      return;
    }
    final digest = await textDocumentSha256(file);

    await saveTextDocument(file, 'two\n', expectedSha256: digest);

    expect(await file.readAsString(), 'two\n');
    expect(await _attribute(file, name), 'kept');
  });

  test('every attribute survives, not only the first', () async {
    for (final suffix in ['a', 'b', 'c']) {
      final skipped = await _setAttribute(file, '$name-$suffix', suffix * 3);
      if (skipped != null) {
        markTestSkipped(skipped);
        return;
      }
    }
    final digest = await textDocumentSha256(file);

    await saveTextDocument(file, 'two\n', expectedSha256: digest);

    for (final suffix in ['a', 'b', 'c']) {
      expect(await _attribute(file, '$name-$suffix'), suffix * 3);
    }
  });
}
