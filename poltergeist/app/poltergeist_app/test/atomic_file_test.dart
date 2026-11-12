// Ported from Séance app/seance_app/test/atomic_file_test.dart @ e11206a; see docs/PORTS.md.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/atomic_file.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_atomic_test_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('creates the parent directory and round-trips content', () async {
    final target = File(
      p.join(temporaryDirectory.path, 'nested', 'deep', 'data.json'),
    );

    await writeStringAtomically(target, '{"hello":"world"}');

    expect(await target.readAsString(), '{"hello":"world"}');
  });

  test('replaces existing content and leaves no temporary file', () async {
    final target = File(p.join(temporaryDirectory.path, 'data.json'));

    await writeStringAtomically(target, 'first');
    await writeStringAtomically(target, 'second');

    expect(await target.readAsString(), 'second');
    expect(await _entryNames(temporaryDirectory), ['data.json']);
  });

  test('removes the temporary sibling after rename fails', () async {
    final target = File(p.join(temporaryDirectory.path, 'data.json'));
    await Directory(target.path).create();

    await expectLater(
      writeStringAtomically(target, 'value'),
      throwsA(isA<FileSystemException>()),
    );

    expect(await _entryNames(temporaryDirectory), ['data.json']);
  });

  test(
    'writes through a symbolic link and keeps the link',
    () async {
      final target = File(p.join(temporaryDirectory.path, 'target.json'));
      await target.writeAsString('old');
      final link = Link(p.join(temporaryDirectory.path, 'link.json'));
      await link.create(target.path);

      await writeStringAtomically(File(link.path), 'new');

      expect(await target.readAsString(), 'new');
      expect(
        await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
    },
    skip: Platform.isWindows ? 'symbolic links need extra rights on Windows' : null,
  );
}

Future<List<String>> _entryNames(Directory directory) async {
  final names = await directory
      .list()
      .map((entry) => p.basename(entry.path))
      .toList();
  names.sort();

  return names;
}
