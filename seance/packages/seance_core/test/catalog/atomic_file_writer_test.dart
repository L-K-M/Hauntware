import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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

  test('writes through a symbolic link and keeps the link', () async {
    if (Platform.isWindows) return;
    final target = File(pathIn('target.json'));
    await target.writeAsString('old');
    final link = Link(pathIn('link.json'));
    await link.create(target.path);

    await const AtomicFileWriter().write(File(link.path), 'new');

    expect(await target.readAsString(), 'new');
    expect(
      await FileSystemEntity.type(link.path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(entries(), containsAll(['target.json', 'link.json']));
  });

  test('a link and its target share request order', () async {
    final target = File(pathIn('target.json'));
    await target.writeAsString('old');
    final link = Link(pathIn('link.json'));
    await link.create(target.path);

    await Future.wait([
      const AtomicFileWriter().write(File(link.path), 'first'),
      const AtomicFileWriter().write(target, 'last'),
    ]);

    expect(await target.readAsString(), 'last');
  }, skip: Platform.isWindows);

  test('a chain of dangling relative links keeps every link', () async {
    final target = File(pathIn('missing%20?.json'));
    final middle = Link(pathIn('middle.json'));
    final link = Link(pathIn('link.json'));
    await middle.create('missing%20?.json');
    await link.create('middle.json');

    await const AtomicFileWriter().write(File(link.path), 'new');

    expect(await target.readAsString(), 'new');
    expect(await middle.target(), 'missing%20?.json');
    expect(await link.target(), 'middle.json');
  }, skip: Platform.isWindows);

  test('a cyclic link fails without replacing a link', () async {
    final first = Link(pathIn('first.json'));
    final second = Link(pathIn('second.json'));
    await first.create('second.json');
    await second.create('first.json');

    await expectLater(
      const AtomicFileWriter().write(File(first.path), 'new'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await first.target(), 'second.json');
    expect(await second.target(), 'first.json');
  }, skip: Platform.isWindows);

  test(
    'a parent-directory link cycle fails without poisoning later writes',
    () async {
      await Link(pathIn('loop')).create('loop/sub');
      final result = ReceivePort();
      final isolate = await Isolate.spawn(_writeThroughParentLoop, (
        result.sendPort,
        dir.path,
      ));
      try {
        expect(
          await result.first.timeout(const Duration(seconds: 3)),
          'recovered',
        );
      } finally {
        isolate.kill(priority: Isolate.immediate);
        result.close();
      }
      expect(await File(pathIn('recovered.json')).readAsString(), 'safe');
    },
    skip: Platform.isWindows,
  );

  test(
    'a non-directory component before dot-dot cannot redirect a write',
    () async {
      await File(pathIn('plain')).writeAsString('not a directory');
      final link = Link(pathIn('link.json'));
      await link.create('plain/../target.json');

      await expectLater(
        const AtomicFileWriter().write(File(link.path), 'new'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(pathIn('target.json')).exists(), isFalse);
      expect(await link.target(), 'plain/../target.json');
    },
    skip: Platform.isWindows,
  );

  test(
    'dot-dot after a directory symlink follows filesystem semantics',
    () async {
      await Directory(pathIn('elsewhere/inner')).create(recursive: true);
      await Link(pathIn('directory-alias')).create(pathIn('elsewhere/inner'));
      final link = Link(pathIn('link.json'));
      await link.create('directory-alias/../target.json');

      await const AtomicFileWriter().write(File(link.path), 'new');

      expect(await File(pathIn('elsewhere/target.json')).readAsString(), 'new');
      expect(await File(link.path).readAsString(), 'new');
      expect(await File(pathIn('target.json')).exists(), isFalse);
    },
    skip: Platform.isWindows,
  );

  test('concurrent writes keep the last requested snapshot', () async {
    final file = File(pathIn('store.json'));
    await Future.wait([
      for (var i = 0; i < 20; i++)
        const AtomicFileWriter().write(File(pathIn('store.json')), 'v$i'),
    ]);
    expect(await file.readAsString(), 'v19');
    expect(entries(), ['store.json']);
  });
}

// Isolate the failure probe so a regressed infinite resolution can be killed
// without leaving this test process's global writer queue stuck.
void _writeThroughParentLoop((SendPort, String) request) async {
  final (reply, directory) = request;
  try {
    await const AtomicFileWriter().write(
      File('$directory/loop/file'),
      'unsafe',
    );
    reply.send('unexpected success');
  } on FileSystemException {
    await const AtomicFileWriter().write(
      File('$directory/recovered.json'),
      'safe',
    );
    reply.send('recovered');
  } catch (error) {
    reply.send(error.runtimeType.toString());
  }
}
