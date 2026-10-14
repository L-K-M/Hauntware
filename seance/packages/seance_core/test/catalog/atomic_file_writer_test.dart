import 'dart:convert';
import 'dart:io';

import 'package:seance_core/src/catalog/atomic_file_writer.dart';
import 'package:test/test.dart';

const _posixModeBits = 0x1ff;
const _ownerReadWrite = 0x180; // 0600

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('atomic-file-writer');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  String pathIn(String name) => '${dir.path}${Platform.pathSeparator}$name';

  /// Separator-robust basenames of everything directly in [dir].
  List<String> entries() => [
    for (final entry in dir.listSync()) entry.path.split(RegExp(r'[\\/]')).last,
  ]..sort();

  test(
    'replaces the file with the exact contents and leaves no temp',
    () async {
      final file = File(pathIn('store.json'));
      await file.writeAsString('older and longer contents than the new ones');

      await const AtomicFileWriter().write(file, '{"label":"café"}');

      expect(await file.readAsBytes(), utf8.encode('{"label":"café"}'));
      expect(entries(), ['store.json']);
    },
  );

  test('creates missing parent directories', () async {
    final file = File(pathIn('nested${Platform.pathSeparator}store.json'));

    await const AtomicFileWriter().write(file, 'contents');

    expect(await file.readAsString(), 'contents');
  });

  test('a failed rename deletes the temp and rethrows', () async {
    // A non-empty directory at the target path makes the rename fail after
    // the temp already holds the contents.
    final target = Directory(pathIn('store.json'))..createSync();
    File('${target.path}${Platform.pathSeparator}keep').writeAsStringSync('');

    await expectLater(
      const AtomicFileWriter().write(File(target.path), 'contents'),
      throwsA(isA<FileSystemException>()),
    );
    expect(entries(), ['store.json']);
  });

  group('permissions', () {
    int modeOf(String path) => File(path).statSync().mode & _posixModeBits;

    test('owner-only privacy lands the file at 0600', () async {
      final file = File(pathIn('vault.json'));

      await const AtomicFileWriter().write(
        file,
        'secret',
        privacy: AtomicFilePrivacy.ownerOnly,
      );

      expect(modeOf(file.path), _ownerReadWrite);
      expect(entries(), ['vault.json']);
    });

    test(
      'the process default keeps the umask mode a plain create gets',
      () async {
        final reference = File(pathIn('reference'))..createSync();
        final file = File(pathIn('servers.json'));

        await const AtomicFileWriter().write(file, '{}');

        expect(modeOf(file.path), modeOf(reference.path));
      },
    );
  }, skip: !Platform.isLinux && !Platform.isMacOS ? 'POSIX modes' : false);
}
