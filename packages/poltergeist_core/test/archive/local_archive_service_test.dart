@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

const String _stageMarkerName = '.poltergeist-archive-owner';
const String _stageMarkerContents = 'poltergeist-archive-stage-v1\n';
const String _stageMarkerPrefix = 'poltergeist-archive-stage-v2:';
const String _archiveStateDirectoryName = 'local-archive-state-v1';
const String _ownershipKeyName = 'archive-owner.key';
const int _ownershipKeyBytes = 32;
const Duration _archiveHelperReadyTimeout = Duration(seconds: 30);

void main() {
  late Directory root;
  late LocalArchiveService service;

  setUp(() {
    final temp = Directory.systemTemp.createTempSync('pg-archive');
    root = Directory(temp.resolveSymbolicLinksSync());
    service = LocalArchiveService();
  });

  tearDown(() async {
    await service.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String pathOf(String name) => p.join(root.path, name);

  test('creates and extracts a streamed ZIP with per-entry progress', () async {
    final source = Directory(pathOf('source'))..createSync();
    Directory(p.join(source.path, 'empty')).createSync();
    Directory(p.join(source.path, 'nested')).createSync();
    File(p.join(source.path, 'hello.txt')).writeAsStringSync('hello');
    File(p.join(source.path, 'nested/data.bin')).writeAsBytesSync(
      Uint8List.fromList(List<int>.generate(2048, (index) => index & 0xff)),
    );

    final createProgress = <LocalArchiveProgress>[];
    final create = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('bundle.zip'),
    );
    final createSubscription = create.progress.listen(createProgress.add);
    final created = await create.done;
    await createSubscription.cancel();

    expect(created.destinationPath, pathOf('bundle.zip'));
    expect(created.entries, 5);
    expect(created.uncompressedBytes, 2053);
    expect(File(created.destinationPath).existsSync(), isTrue);
    final helloProgress = createProgress.lastWhere(
      (progress) => progress.entryName == 'source/hello.txt',
    );
    expect(helloProgress.entryIsDirectory, isFalse);
    expect(helloProgress.entryProcessedBytes, 5);
    expect(helloProgress.entryTotalBytes, 5);
    expect(helloProgress.completedEntries, greaterThan(0));

    final extractProgress = <LocalArchiveProgress>[];
    final extract = service.extractZip(
      archivePath: created.destinationPath,
      destinationPath: pathOf('unpacked'),
    );
    final extractSubscription = extract.progress.listen(extractProgress.add);
    final extracted = await extract.done;
    await extractSubscription.cancel();

    expect(
      File(
        p.join(extracted.destinationPath, 'source/hello.txt'),
      ).readAsStringSync(),
      'hello',
    );
    expect(
      Directory(p.join(extracted.destinationPath, 'source/empty')).existsSync(),
      isTrue,
    );
    final dataProgress = extractProgress.lastWhere(
      (progress) => progress.entryName == 'source/nested/data.bin',
    );
    expect(dataProgress.entryProcessedBytes, 2048);
    expect(dataProgress.entryTotalBytes, 2048);
    expect(_stageNames(root), isEmpty);
  });

  test('snapshots the source list before returning its job', () async {
    final source = File(pathOf('snapshot-source'))..writeAsStringSync('data');
    final sources = <String>[source.path];
    final job = service.createZip(
      sourcePaths: sources,
      destinationPath: pathOf('snapshot.zip'),
    );
    sources
      ..clear()
      ..add('');

    final result = await job.done;
    final archive = ZipDecoder().decodeBytes(
      File(result.destinationPath).readAsBytesSync(),
    );
    expect(
      archive.files.map((entry) => entry.name),
      contains('snapshot-source'),
    );
    archive.clearSync();
  });

  test('creates from a file below an execute-only ancestor', () async {
    if (!Platform.isLinux) {
      markTestSkipped('Linux permission traversal is required');
      return;
    }
    final ancestor = Directory(pathOf('execute-only'))..createSync();
    final source = File(p.join(ancestor.path, 'data'))
      ..writeAsStringSync('payload');
    final restricted = Process.runSync('chmod', ['0111', ancestor.path]);
    expect(restricted.exitCode, 0);

    try {
      final result = await service
          .createZip(
            sourcePaths: [source.path],
            destinationPath: pathOf('execute-only.zip'),
          )
          .done;

      expect(File(result.destinationPath).existsSync(), isTrue);
    } finally {
      Process.runSync('chmod', ['0700', ancestor.path]);
    }
  });

  test('creates from a file reached through a symlinked ancestor', () async {
    if (Platform.isWindows) {
      markTestSkipped('creating symbolic links requires Windows privileges');
      return;
    }
    final sourceDirectory = Directory(pathOf('source-directory'))..createSync();
    final source = File(p.join(sourceDirectory.path, 'data'))
      ..writeAsStringSync('payload');
    final alias = Link(pathOf('source-alias'))
      ..createSync(sourceDirectory.path);

    final result = await service
        .createZip(
          sourcePaths: [p.join(alias.path, p.basename(source.path))],
          destinationPath: pathOf('symlinked-ancestor.zip'),
        )
        .done;

    expect(File(result.destinationPath).existsSync(), isTrue);
  });

  test(
    'extracts an archive addressed relative to the working directory',
    () async {
      final archive = File(pathOf('relative.zip'));
      _writeZip(archive, [ArchiveFile.string('data', 'payload')]);
      final relativePath = p.relative(
        archive.path,
        from: Directory.current.path,
      );

      final result = await service
          .extractZip(
            archivePath: relativePath,
            destinationPath: pathOf('relative-output'),
          )
          .done;

      expect(
        File(p.join(result.destinationPath, 'data')).readAsStringSync(),
        'payload',
      );
    },
  );

  test(
    'rejects an empty source without reading the working directory',
    () async {
      await service.close();
      service = LocalArchiveService(
        limits: const LocalArchiveLimits(maximumEntries: 1),
      );

      await _expectArchiveError(
        service.createZip(
          sourcePaths: const [''],
          destinationPath: pathOf('empty-source.zip'),
        ),
        LocalArchiveErrorKind.unsafeEntry,
      );
      expect(File(pathOf('empty-source.zip')).existsSync(), isFalse);
      expect(_stageNames(root), isEmpty);
    },
  );

  test('serializes concurrent Keep Both commits', () async {
    final otherService = LocalArchiveService();
    addTearDown(otherService.close);
    final first = File(pathOf('first.txt'))..writeAsStringSync('first');
    final second = File(pathOf('second.txt'))..writeAsStringSync('second');
    final one = service.createZip(
      sourcePaths: [first.path],
      destinationPath: pathOf('same.zip'),
    );
    final two = otherService.createZip(
      sourcePaths: [second.path],
      destinationPath: pathOf('same.zip'),
    );

    final results = await Future.wait([one.done, two.done]);
    expect(
      results.map((result) => p.basename(result.destinationPath)).toSet(),
      {'same.zip', 'same (2).zip'},
    );
    expect(
      results.every((result) => File(result.destinationPath).existsSync()),
      isTrue,
    );
  });

  test('keeps commit locks outside destination folders', () async {
    final parent = Directory(pathOf('destination'))..createSync();
    final source = File(p.join(parent.path, 'source'))
      ..writeAsStringSync('data');
    final first = await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: p.join(parent.path, 'archive.zip'),
        )
        .done;

    expect(
      parent
          .listSync(followLinks: false)
          .map((entry) => p.basename(entry.path))
          .toSet(),
      {'source', 'archive.zip'},
    );

    final second = await service
        .createZip(
          sourcePaths: [parent.path],
          destinationPath: pathOf('destination.zip'),
        )
        .done;
    final archive = ZipDecoder().decodeBytes(
      File(second.destinationPath).readAsBytesSync(),
    );
    expect(
      archive.files.map((entry) => entry.name),
      everyElement(isNot(contains('.poltergeist-archive-commit.lock'))),
    );
    archive.clearSync();
    expect(File(first.destinationPath).existsSync(), isTrue);
  });

  test('uses private owner-only commit lock storage', () async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      markTestSkipped('POSIX permission bits are required');
      return;
    }
    final parent = Directory(pathOf('private-lock-parent'))..createSync();
    final source = File(p.join(parent.path, 'source'))
      ..writeAsStringSync('data');
    await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: p.join(parent.path, 'archive.zip'),
        )
        .done;
    final lockDirectory = await _archiveLockDirectory();
    final parentPath = await parent.resolveSymbolicLinks();
    final lockName = '${sha256.convert(utf8.encode(parentPath))}.lock';
    final lock = File(p.join(lockDirectory.path, lockName));
    addTearDown(() async {
      if (await lock.exists()) await lock.delete();
    });

    expect((await lockDirectory.stat()).mode & 0x1ff, 0x1c0);
    expect((await lock.stat()).mode & 0x1ff, 0x180);
  });

  test('rejects a symlink precreated at the commit lock path', () async {
    if (Platform.isWindows) {
      markTestSkipped('creating symbolic links requires Windows privileges');
      return;
    }
    final parent = Directory(pathOf('hostile-lock-parent'))..createSync();
    final source = File(p.join(parent.path, 'source'))
      ..writeAsStringSync('data');
    await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: p.join(parent.path, 'seed.zip'),
        )
        .done;
    final lockDirectory = await _archiveLockDirectory();
    final parentPath = await parent.resolveSymbolicLinks();
    final lockName = '${sha256.convert(utf8.encode(parentPath))}.lock';
    final lockPath = p.join(lockDirectory.path, lockName);
    await File(lockPath).delete();
    final target = File(pathOf('lock-target'))..writeAsStringSync('keep');
    final link = Link(lockPath)..createSync(target.path);
    addTearDown(() async {
      if (await link.exists()) await link.delete();
    });

    await _expectArchiveError(
      service.createZip(
        sourcePaths: [source.path],
        destinationPath: p.join(parent.path, 'archive.zip'),
      ),
      LocalArchiveErrorKind.conflict,
    );
    expect(target.readAsStringSync(), 'keep');
  });

  test('serializes Keep Both commits across processes', () async {
    final first = File(pathOf('process-first'))..writeAsStringSync('first');
    final second = File(pathOf('process-second'))..writeAsStringSync('second');
    final destination = pathOf('process-same.zip');
    final one = await _startArchiveHelper(['commit', first.path, destination]);
    final two = await _startArchiveHelper(['commit', second.path, destination]);
    addTearDown(() => _stopHelper(one.$1));
    addTearDown(() => _stopHelper(two.$1));

    await Future.wait([
      one.$2.firstWhere((line) => line == 'ready'),
      two.$2.firstWhere((line) => line == 'ready'),
    ]).timeout(_archiveHelperReadyTimeout);
    final oneResult = one.$2.firstWhere((line) => line.startsWith('result:'));
    final twoResult = two.$2.firstWhere((line) => line.startsWith('result:'));
    one.$1.stdin.writeln('go');
    two.$1.stdin.writeln('go');

    final lines = await Future.wait([oneResult, twoResult]);
    expect(lines.map((line) => line.substring('result:'.length)).toSet(), {
      'process-same.zip',
      'process-same (2).zip',
    });
    expect(await one.$1.exitCode, 0);
    expect(await two.$1.exitCode, 0);
  });

  test('keeps both when extraction destination already exists', () async {
    final archive = File(pathOf('input.zip'));
    _writeZip(archive, [ArchiveFile.string('file.txt', 'content')]);
    Directory(pathOf('output')).createSync();

    final result = await service
        .extractZip(
          archivePath: archive.path,
          destinationPath: pathOf('output'),
        )
        .done;

    expect(p.basename(result.destinationPath), 'output (2)');
    expect(
      File(p.join(result.destinationPath, 'file.txt')).readAsStringSync(),
      'content',
    );
  });

  for (final (label, entries) in <(String, List<ArchiveFile>)>[
    ('traversal', [ArchiveFile.string('../escape.txt', 'bad')]),
    (
      'case aliases',
      [ArchiveFile.string('Readme', 'a'), ArchiveFile.string('README', 'b')],
    ),
    (
      'normalization aliases',
      [
        ArchiveFile.string('caf\u00e9.txt', 'a'),
        ArchiveFile.string('cafe\u0301.txt', 'b'),
      ],
    ),
    (
      'file-prefix conflict',
      [ArchiveFile.string('node', 'a'), ArchiveFile.string('node/child', 'b')],
    ),
  ]) {
    test('rejects $label before materializing output', () async {
      final archive = File(pathOf('unsafe.zip'));
      _writeZip(archive, entries);

      await _expectArchiveError(
        service.extractZip(
          archivePath: archive.path,
          destinationPath: pathOf('output'),
        ),
        LocalArchiveErrorKind.unsafeEntry,
      );

      expect(Directory(pathOf('output')).existsSync(), isFalse);
      expect(_stageNames(root), isEmpty);
    });
  }

  test('rejects exact duplicate entry paths', () async {
    final archive = File(pathOf('duplicate.zip'));
    _writeZip(archive, [
      ArchiveFile.string('first', 'a'),
      ArchiveFile.string('other', 'b'),
    ]);
    final bytes = archive.readAsBytesSync();
    _replaceAscii(bytes, 'other', 'first');
    archive.writeAsBytesSync(bytes);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('output'),
      ),
      LocalArchiveErrorKind.unsafeEntry,
    );
    expect(_stageNames(root), isEmpty);
  });

  for (final (label, entry) in <(String, ArchiveFile)>[
    ('symbolic link', ArchiveFile.noCompress('link', 0, [])..mode = 0xa1ff),
    ('special entry', ArchiveFile.noCompress('pipe', 0, [])..mode = 0x11ff),
    (
      'unsupported compression',
      ArchiveFile.string('data', 'content')
        ..compression = CompressionType.bzip2,
    ),
  ]) {
    test('rejects $label metadata', () async {
      final archive = File(pathOf('unsupported.zip'));
      _writeZip(archive, [entry]);

      await _expectArchiveError(
        service.extractZip(
          archivePath: archive.path,
          destinationPath: pathOf('output'),
        ),
        LocalArchiveErrorKind.unsupported,
      );
      expect(_stageNames(root), isEmpty);
    });
  }

  test('rejects encrypted entries', () async {
    final archive = File(pathOf('encrypted.zip'));
    _writeZip(archive, [
      ArchiveFile.string('secret.txt', 'secret'),
    ], password: 'password');

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('output'),
      ),
      LocalArchiveErrorKind.unsupported,
    );
  });

  test('checks actual decoded CRC and removes the failed stage', () async {
    final archive = File(pathOf('bad-crc.zip'));
    _writeZip(archive, [
      ArchiveFile.noCompress('data.txt', 4, [1, 2, 3, 4]),
    ]);
    final bytes = archive.readAsBytesSync();
    final local = _findSignature(bytes, const [0x50, 0x4b, 0x03, 0x04]);
    final central = _findSignature(bytes, const [0x50, 0x4b, 0x01, 0x02]);
    _writeUint32(bytes, local + 14, 0x12345678);
    _writeUint32(bytes, central + 16, 0x12345678);
    archive.writeAsBytesSync(bytes);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('output'),
      ),
      LocalArchiveErrorKind.checksumMismatch,
    );
    expect(Directory(pathOf('output')).existsSync(), isFalse);
    expect(_stageNames(root), isEmpty);
  });

  test('reports extraction output write failures as IO errors', () async {
    if (!File('/dev/full').existsSync()) {
      markTestSkipped('/dev/full is required for a deterministic write error');
      return;
    }
    final archive = File(pathOf('write-error.zip'));
    _writeZip(archive, [
      ArchiveFile.noCompress('data', 4, [1, 2, 3, 4]),
    ]);
    final job = service.extractZip(
      archivePath: archive.path,
      destinationPath: pathOf('output'),
    );
    final subscription = job.progress.listen((progress) {
      if (progress.phase != LocalArchivePhase.preparing) return;
      final stage = Directory(p.join(root.path, _stageNames(root).single));
      final payload = Directory(p.join(stage.path, 'payload'))..createSync();
      Link(p.join(payload.path, 'data')).createSync('/dev/full');
    });

    await _expectArchiveError(job, LocalArchiveErrorKind.io);
    await subscription.cancel();
    expect(_stageNames(root), isEmpty);
  });

  test('extracts a bounded entry that uses a data descriptor', () async {
    final archive = File(pathOf('descriptor.zip'));
    _writeZip(archive, [
      ArchiveFile.noCompress('data.txt', 4, [1, 2, 3, 4]),
    ]);
    final bytes = archive.readAsBytesSync().toList();
    final oldCentral = _findSignature(bytes, const [0x50, 0x4b, 0x01, 0x02]);
    final crc32 = _readUint32(bytes, oldCentral + 16);
    final compressedSize = _readUint32(bytes, oldCentral + 20);
    final uncompressedSize = _readUint32(bytes, oldCentral + 24);
    _writeUint16(bytes, 6, _readUint16(bytes, 6) | 0x0008);
    _writeUint32(bytes, 14, 0);
    _writeUint32(bytes, 18, 0);
    _writeUint32(bytes, 22, 0);
    bytes.insertAll(oldCentral, <int>[
      0x50,
      0x4b,
      0x07,
      0x08,
      ..._uint32Bytes(crc32),
      ..._uint32Bytes(compressedSize),
      ..._uint32Bytes(uncompressedSize),
    ]);
    const descriptorLength = 16;
    final central = oldCentral + descriptorLength;
    _writeUint16(bytes, central + 8, _readUint16(bytes, central + 8) | 0x0008);
    final end = _findSignature(bytes, const [0x50, 0x4b, 0x05, 0x06]);
    _writeUint32(bytes, end + 16, central);
    archive.writeAsBytesSync(bytes);

    final result = await service
        .extractZip(
          archivePath: archive.path,
          destinationPath: pathOf('output'),
        )
        .done;

    expect(File(p.join(result.destinationPath, 'data.txt')).readAsBytesSync(), [
      1,
      2,
      3,
      4,
    ]);
  });

  test(
    'accepts an unsigned descriptor whose CRC equals the signature',
    () async {
      final archive = File(pathOf('unsigned-descriptor-crc-collision.zip'));
      const payload = <int>[172, 10, 122, 213];
      _writeZip(archive, [
        ArchiveFile.noCompress('data.bin', payload.length, payload),
      ]);
      final bytes = archive.readAsBytesSync().toList();
      final oldCentral = _findSignature(bytes, const [0x50, 0x4b, 0x01, 0x02]);
      final crc32 = _readUint32(bytes, oldCentral + 16);
      final compressedSize = _readUint32(bytes, oldCentral + 20);
      final uncompressedSize = _readUint32(bytes, oldCentral + 24);
      expect(crc32, 0x08074b50);
      _writeUint16(bytes, 6, _readUint16(bytes, 6) | 0x0008);
      _writeUint32(bytes, 14, 0);
      _writeUint32(bytes, 18, 0);
      _writeUint32(bytes, 22, 0);
      bytes.insertAll(oldCentral, <int>[
        ..._uint32Bytes(crc32),
        ..._uint32Bytes(compressedSize),
        ..._uint32Bytes(uncompressedSize),
      ]);
      const descriptorLength = 12;
      final central = oldCentral + descriptorLength;
      _writeUint16(
        bytes,
        central + 8,
        _readUint16(bytes, central + 8) | 0x0008,
      );
      final end = _findSignature(bytes, const [0x50, 0x4b, 0x05, 0x06]);
      _writeUint32(bytes, end + 16, central);
      archive.writeAsBytesSync(bytes);

      final result = await service
          .extractZip(
            archivePath: archive.path,
            destinationPath: pathOf('output'),
          )
          .done;

      expect(
        File(p.join(result.destinationPath, 'data.bin')).readAsBytesSync(),
        payload,
      );
    },
  );

  test('accepts a 32-bit descriptor with a ZIP64 local offset', () async {
    final archive = File(pathOf('zip64-offset-descriptor.zip'));
    _writeZip45DescriptorWithZip64Offset(archive);

    final result = await service
        .extractZip(
          archivePath: archive.path,
          destinationPath: pathOf('output'),
        )
        .done;

    expect(File(p.join(result.destinationPath, 'data')).readAsBytesSync(), [
      1,
      2,
      3,
      4,
    ]);
  });

  test('enforces injectable entry and byte limits', () async {
    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(
        maximumEntries: 1,
        maximumEntryBytes: 3,
        maximumTotalBytes: 3,
      ),
    );
    final archive = File(pathOf('large.zip'));
    _writeZip(archive, [ArchiveFile.string('data', 'four')]);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('output'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );
  });

  test('enforces the declared entry-count limit before extraction', () async {
    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(maximumEntries: 1),
    );
    final archive = File(pathOf('entries.zip'));
    _writeZip(archive, [
      ArchiveFile.string('one', '1'),
      ArchiveFile.string('two', '2'),
    ]);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('output'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );
  });

  test('rejects a false declared central-directory count', () async {
    final archive = File(pathOf('false-count.zip'));
    _writeZip(archive, [
      ArchiveFile.string('one', '1'),
      ArchiveFile.string('two', '2'),
    ]);
    final bytes = archive.readAsBytesSync();
    final end = _findSignature(bytes, const [0x50, 0x4b, 0x05, 0x06]);
    _writeUint16(bytes, end + 8, 1);
    _writeUint16(bytes, end + 10, 1);
    archive.writeAsBytesSync(bytes);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('output'),
      ),
      LocalArchiveErrorKind.invalidArchive,
    );
  });

  test('rejects an EOCD signature hidden in the ZIP comment', () async {
    final archive = File(pathOf('comment-eocd.zip'));
    _writeZip(archive, [ArchiveFile.string('entry', 'data')]);
    final bytes = archive.readAsBytesSync().toList();
    final end = _findSignature(bytes, const [0x50, 0x4b, 0x05, 0x06]);
    const commentLength = 30;
    _writeUint16(bytes, end + 20, commentLength);
    bytes.addAll(List<int>.filled(commentLength, 0));
    bytes.setRange(end + 22 + 5, end + 22 + 9, const [0x50, 0x4b, 0x05, 0x06]);
    archive.writeAsBytesSync(bytes);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('output'),
      ),
      LocalArchiveErrorKind.invalidArchive,
    );
  });

  test('rejects a ZIP64 locator beside a classic directory record', () async {
    final archive = File(pathOf('conflicting-zip64.zip'));
    _writeZip(archive, [ArchiveFile.string('entry', 'data')]);
    final bytes = archive.readAsBytesSync().toList();
    final end = _findSignature(bytes, const [0x50, 0x4b, 0x05, 0x06]);
    final centralSize = _readUint32(bytes, end + 12);
    final centralOffset = _readUint32(bytes, end + 16);
    final zip64Offset = end;
    bytes.insertAll(end, <int>[
      ..._uint32Bytes(0x06064b50),
      ..._uint64Bytes(44),
      45,
      0,
      45,
      0,
      ..._uint32Bytes(0),
      ..._uint32Bytes(0),
      ..._uint64Bytes(100001),
      ..._uint64Bytes(100001),
      ..._uint64Bytes(centralSize),
      ..._uint64Bytes(centralOffset),
      ..._uint32Bytes(0x07064b50),
      ..._uint32Bytes(0),
      ..._uint64Bytes(zip64Offset),
      ..._uint32Bytes(1),
    ]);
    archive.writeAsBytesSync(bytes);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('output'),
      ),
      LocalArchiveErrorKind.invalidArchive,
    );
  });

  test('rejects multi-disk fields in a ZIP64 locator', () async {
    for (final fields in const [(1, 1), (0, 2)]) {
      final archive = File(
        pathOf('zip64-locator-${fields.$1}-${fields.$2}.zip'),
      );
      _writeZip64Envelope(
        archive,
        locatorDisk: fields.$1,
        locatorDisks: fields.$2,
      );

      await _expectArchiveError(
        service.extractZip(
          archivePath: archive.path,
          destinationPath: pathOf('zip64-locator-${fields.$1}-${fields.$2}'),
        ),
        LocalArchiveErrorKind.unsupported,
      );
    }
  });

  test('rejects ZIP64 data descriptors before directory decoding', () async {
    final archive = File(pathOf('zip64-descriptor.zip'));
    _writeZip64Descriptor(archive);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('output'),
      ),
      LocalArchiveErrorKind.unsupported,
    );
  });

  test('caps aggregate ZIP header metadata before directory decode', () async {
    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(maximumMetadataBytes: 64),
    );
    final archive = File(pathOf('metadata.zip'));
    _writeZip(archive, [ArchiveFile.string('entry', 'data')]);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('output'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );
  });

  test('caps compressed entry, aggregate, and archive file bytes', () async {
    final emptyBlocks = _emptyDeflateBlocks(8);
    final one = File(pathOf('compressed-entry.zip'));
    _writePrecompressedZip(one, [emptyBlocks]);
    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(maximumCompressedEntryBytes: 32),
    );
    await _expectArchiveError(
      service.extractZip(
        archivePath: one.path,
        destinationPath: pathOf('entry-output'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );

    final two = File(pathOf('compressed-total.zip'));
    _writePrecompressedZip(two, [emptyBlocks, emptyBlocks]);
    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(
        maximumCompressedEntryBytes: 64,
        maximumCompressedTotalBytes: 64,
      ),
    );
    await _expectArchiveError(
      service.extractZip(
        archivePath: two.path,
        destinationPath: pathOf('total-output'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );

    await service.close();
    service = LocalArchiveService(
      limits: LocalArchiveLimits(maximumArchiveFileBytes: two.lengthSync() - 1),
    );
    await _expectArchiveError(
      service.extractZip(
        archivePath: two.path,
        destinationPath: pathOf('file-output'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );
  });

  test('enforces declared total and path-depth limits separately', () async {
    final archive = File(pathOf('total.zip'));
    _writeZip(archive, [
      ArchiveFile.string('one', '123'),
      ArchiveFile.string('two', '456'),
    ]);
    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(
        maximumEntryBytes: 10,
        maximumTotalBytes: 5,
      ),
    );
    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('total-output'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );

    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(maximumDepth: 1),
    );
    final deep = File(pathOf('deep.zip'));
    _writeZip(deep, [ArchiveFile.string('one/two', 'data')]);
    await _expectArchiveError(
      service.extractZip(
        archivePath: deep.path,
        destinationPath: pathOf('deep-output'),
      ),
      LocalArchiveErrorKind.unsafeEntry,
    );
  });

  test('caps aggregate archive path components', () async {
    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(maximumPathComponents: 5),
    );
    final archive = File(pathOf('components.zip'));
    _writeZip(archive, [
      ArchiveFile.string('one/two/three', 'a'),
      ArchiveFile.string('four/five/six', 'b'),
    ]);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('components-output'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );
  });

  test('caps actual output when declared size is forged smaller', () async {
    final archive = File(pathOf('forged-size.zip'));
    _writeZip(archive, [
      ArchiveFile.noCompress('data', 4, [1, 2, 3, 4]),
    ]);
    final bytes = archive.readAsBytesSync();
    final local = _findSignature(bytes, const [0x50, 0x4b, 0x03, 0x04]);
    final central = _findSignature(bytes, const [0x50, 0x4b, 0x01, 0x02]);
    _writeUint32(bytes, local + 22, 1);
    _writeUint32(bytes, central + 24, 1);
    archive.writeAsBytesSync(bytes);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('output'),
      ),
      LocalArchiveErrorKind.invalidArchive,
    );
    expect(_stageNames(root), isEmpty);
  });

  test(
    'rejects absolute, empty-component, and backslash entry paths',
    () async {
      for (final name in ['/absolute', 'folder//child']) {
        final archive = File(pathOf('${name.hashCode}.zip'));
        _writeZip(archive, [ArchiveFile.string(name, 'data')]);
        await _expectArchiveError(
          service.extractZip(
            archivePath: archive.path,
            destinationPath: pathOf('${name.hashCode}-output'),
          ),
          LocalArchiveErrorKind.unsafeEntry,
        );
      }

      final backslash = File(pathOf('backslash.zip'));
      _writeZip(backslash, [ArchiveFile.string('folder/child', 'data')]);
      final bytes = backslash.readAsBytesSync();
      _replaceAscii(bytes, 'folder/child', r'folder\child');
      backslash.writeAsBytesSync(bytes);
      await _expectArchiveError(
        service.extractZip(
          archivePath: backslash.path,
          destinationPath: pathOf('backslash-output'),
        ),
        LocalArchiveErrorKind.unsafeEntry,
      );
    },
  );

  test('rejects NEL in a materialized archive entry path', () async {
    final archive = File(pathOf('nel.zip'));
    _writeZip(archive, [ArchiveFile.string('line\u0085break', 'data')]);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('nel-output'),
      ),
      LocalArchiveErrorKind.unsafeEntry,
    );
    expect(Directory(pathOf('nel-output')).existsSync(), isFalse);
  });

  test('rejects a source symbolic link before creating output', () async {
    if (Platform.isWindows) {
      markTestSkipped('creating symbolic links requires Windows privileges');
      return;
    }
    final target = File(pathOf('target'))..writeAsStringSync('data');
    final link = Link(pathOf('link'))..createSync(target.path);

    await _expectArchiveError(
      service.createZip(
        sourcePaths: [link.path],
        destinationPath: pathOf('link.zip'),
      ),
      LocalArchiveErrorKind.unsupported,
    );
    expect(File(pathOf('link.zip')).existsSync(), isFalse);
    expect(_stageNames(root), isEmpty);
  });

  test('stops a wide directory walk at the entry limit', () async {
    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(maximumEntries: 3),
    );
    final source = Directory(pathOf('wide'))..createSync();
    for (var index = 0; index < 100; index++) {
      File(p.join(source.path, '$index')).writeAsStringSync('$index');
    }

    await _expectArchiveError(
      service.createZip(
        sourcePaths: [source.path],
        destinationPath: pathOf('wide.zip'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );
  });

  test('skips a leased live nested stage during creation', () async {
    final support = Directory(pathOf('live-stage-support'))..createSync();
    await service.close();
    service = LocalArchiveService(supportDirectoryPath: support.path);
    final seed = File(pathOf('live-stage-seed'))..writeAsStringSync('seed');
    await service
        .createZip(
          sourcePaths: [seed.path],
          destinationPath: pathOf('live-stage-seed.zip'),
        )
        .done;
    final source = Directory(pathOf('source'))..createSync();
    final ownedPath = p.join(
      source.path,
      '.poltergeist-archive-${'a' * 32}.stage',
    );
    final marker = _signedStageMarker(ownedPath, _readOwnershipKey(support));
    final helper = await _startArchiveHelper(['hold-lease', ownedPath, marker]);
    addTearDown(() => _stopHelper(helper.$1));
    await helper.$2
        .firstWhere((line) => line == 'ready')
        .timeout(_archiveHelperReadyTimeout);
    File(p.join(source.path, 'user')).writeAsStringSync('keep');

    final result = await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('nested.zip'),
        )
        .done;
    helper.$1.stdin.writeln('release');
    expect(await helper.$1.exitCode, 0);
    final archive = ZipDecoder().decodeBytes(
      File(result.destinationPath).readAsBytesSync(),
    );
    final names = archive.files.map((entry) => entry.name).toList();

    expect(names.any((name) => name.contains('${'a' * 32}.stage')), isFalse);
    expect(names, contains('source/user'));
    archive.clearSync();
  });

  test('rejects a locked stage with a forged ownership marker', () async {
    final source = Directory(pathOf('forged-stage-source'))..createSync();
    final stagePath = p.join(
      source.path,
      '.poltergeist-archive-${'9' * 32}.stage',
    );
    final helper = await _startArchiveHelper([
      'hold-lease',
      stagePath,
      _stageMarkerContents,
    ]);
    addTearDown(() => _stopHelper(helper.$1));
    await helper.$2
        .firstWhere((line) => line == 'ready')
        .timeout(_archiveHelperReadyTimeout);

    await _expectArchiveError(
      service.createZip(
        sourcePaths: [source.path],
        destinationPath: pathOf('forged-stage.zip'),
      ),
      LocalArchiveErrorKind.unsafeEntry,
    );
    expect(Directory(stagePath).existsSync(), isTrue);
  });

  test(
    'rejects a marker-only reserved stage and preserves user data',
    () async {
      final source = Directory(pathOf('source'))..createSync();
      final unowned = Directory(
        p.join(source.path, '.poltergeist-archive-${'a' * 32}.stage'),
      )..createSync();
      File(
        p.join(unowned.path, _stageMarkerName),
      ).writeAsStringSync(_stageMarkerContents);
      File(p.join(unowned.path, '.poltergeist-archive-lease')).createSync();
      final user = File(p.join(unowned.path, 'user'))
        ..writeAsStringSync('keep');

      await _expectArchiveError(
        service.createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('marker-only.zip'),
        ),
        LocalArchiveErrorKind.unsafeEntry,
      );
      expect(user.readAsStringSync(), 'keep');
    },
  );

  test('rejects unowned reserved stage names during creation', () async {
    final source = Directory(pathOf('source'))..createSync();
    final unmarked = Directory(
      p.join(source.path, '.poltergeist-archive-${'b' * 32}.stage'),
    )..createSync();
    File(p.join(unmarked.path, 'user')).writeAsStringSync('keep');

    await _expectArchiveError(
      service.createZip(
        sourcePaths: [source.path],
        destinationPath: pathOf('reserved-source.zip'),
      ),
      LocalArchiveErrorKind.unsafeEntry,
    );
  });

  test('round-trips a nested user file named like the commit lock', () async {
    final source = Directory(pathOf('source'))..createSync();
    final nested = Directory(p.join(source.path, 'nested'))..createSync();
    File(
      p.join(nested.path, '.poltergeist-archive-commit.lock'),
    ).writeAsStringSync('user data');

    final created = await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('lock-name.zip'),
        )
        .done;
    final extracted = await service
        .extractZip(
          archivePath: created.destinationPath,
          destinationPath: pathOf('lock-name-output'),
        )
        .done;

    expect(
      File(
        p.join(
          extracted.destinationPath,
          'source/nested/.poltergeist-archive-commit.lock',
        ),
      ).readAsStringSync(),
      'user data',
    );
  });

  test('detects a source changed after its bounded scan', () async {
    final source = File(pathOf('growing'))
      ..writeAsBytesSync(Uint8List(1024 * 1024));
    final job = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('growing.zip'),
    );
    final subscription = job.progress.listen((progress) {
      if (progress.phase != LocalArchivePhase.preparing) return;
      job.pause();
      source.writeAsBytesSync([1], mode: FileMode.append);
      job.resume();
    });

    await _expectArchiveError(job, LocalArchiveErrorKind.conflict);
    await subscription.cancel();
    expect(_stageNames(root), isEmpty);
  });

  test('rejects a same-metadata source replacement after its scan', () async {
    final source = File(pathOf('replace-source'))..writeAsStringSync('first');
    final originalModified = source.statSync().modified;
    final replacement = File(pathOf('replacement'))..writeAsStringSync('other');
    replacement.setLastModifiedSync(originalModified);
    final job = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('replaced.zip'),
    );
    final subscription = job.progress.listen((progress) {
      if (progress.phase != LocalArchivePhase.preparing) return;
      job.pause();
      source.deleteSync();
      replacement.renameSync(source.path);
      job.resume();
    });

    await _expectArchiveError(job, LocalArchiveErrorKind.conflict);
    await subscription.cancel();
    expect(File(pathOf('replaced.zip')).existsSync(), isFalse);
    expect(_stageNames(root), isEmpty);
  });

  test('caps creation metadata including directory suffixes', () async {
    final longName = 'a' * 200;
    final source = Directory(pathOf(longName))..createSync();
    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(maximumMetadataBytes: 622),
    );

    await _expectArchiveError(
      service.createZip(
        sourcePaths: [source.path],
        destinationPath: pathOf('metadata-create.zip'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );
    expect(File(pathOf('metadata-create.zip')).existsSync(), isFalse);
  });

  test('enforces encoded creation caps and round-trips within them', () async {
    final random = Random(7);
    final bytes = Uint8List.fromList(
      List<int>.generate(128, (_) => random.nextInt(256)),
    );
    final first = File(pathOf('encoded-first'))..writeAsBytesSync(bytes);
    final second = File(pathOf('encoded-second'))..writeAsBytesSync(bytes);

    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(
        maximumCompressedEntryBytes: 32,
        maximumCompressedTotalBytes: 512,
        maximumArchiveFileBytes: 2048,
      ),
    );
    await _expectArchiveError(
      service.createZip(
        sourcePaths: [first.path],
        destinationPath: pathOf('encoded-entry.zip'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );

    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(
        maximumCompressedEntryBytes: 256,
        maximumCompressedTotalBytes: 200,
        maximumArchiveFileBytes: 2048,
      ),
    );
    await _expectArchiveError(
      service.createZip(
        sourcePaths: [first.path, second.path],
        destinationPath: pathOf('encoded-total.zip'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );

    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(
        maximumCompressedEntryBytes: 256,
        maximumCompressedTotalBytes: 512,
        maximumArchiveFileBytes: 128,
      ),
    );
    await _expectArchiveError(
      service.createZip(
        sourcePaths: [first.path],
        destinationPath: pathOf('encoded-file.zip'),
      ),
      LocalArchiveErrorKind.limitExceeded,
    );

    await service.close();
    service = LocalArchiveService(
      limits: const LocalArchiveLimits(
        maximumCompressedEntryBytes: 256,
        maximumCompressedTotalBytes: 512,
        maximumArchiveFileBytes: 2048,
      ),
    );
    final created = await service
        .createZip(
          sourcePaths: [first.path],
          destinationPath: pathOf('encoded-ok.zip'),
        )
        .done;
    final extracted = await service
        .extractZip(
          archivePath: created.destinationPath,
          destinationPath: pathOf('encoded-ok'),
        )
        .done;

    expect(
      File(
        p.join(extracted.destinationPath, 'encoded-first'),
      ).readAsBytesSync(),
      bytes,
    );
  });

  test('pauses at an entry boundary and resumes', () async {
    final first = File(pathOf('first'))..writeAsStringSync('first');
    final second = File(pathOf('second'))..writeAsStringSync('second');
    final job = service.createZip(
      sourcePaths: [first.path, second.path],
      destinationPath: pathOf('paused.zip'),
    );
    final paused = Completer<void>();
    final subscription = job.progress.listen((progress) {
      if (progress.completedEntries != 1 || paused.isCompleted) return;
      job.pause();
      paused.complete();
    });
    await paused.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(job.isPaused, isTrue);
    job.resume();

    final result = await job.done;
    await subscription.cancel();
    expect(File(result.destinationPath).existsSync(), isTrue);
  });

  test('pause before worker ready resumes the initial boundary', () async {
    final source = File(pathOf('source'))..writeAsStringSync('data');
    final job = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('initial-pause.zip'),
    );
    job.pause();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    job.resume();

    final result = await job.done.timeout(const Duration(seconds: 5));
    expect(File(result.destinationPath).existsSync(), isTrue);
  });

  test('paused progress delivery does not stall completion or close', () async {
    final source = File(pathOf('paused-progress-source'))
      ..writeAsStringSync('data');
    final job = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('paused-progress.zip'),
    );
    final subscription = job.progress.listen((_) {})..pause();

    final result = await job.done.timeout(const Duration(seconds: 5));
    await service.close().timeout(const Duration(seconds: 5));
    await subscription.cancel();

    expect(File(result.destinationPath).existsSync(), isTrue);
  });

  test('resume during work does not bypass a later paused boundary', () async {
    final first = File(pathOf('first'))
      ..writeAsBytesSync(Uint8List(2 * 1024 * 1024));
    final second = File(pathOf('second'))..writeAsStringSync('second');
    final third = File(pathOf('third'))..writeAsStringSync('third');
    final job = service.createZip(
      sourcePaths: [first.path, second.path, third.path],
      destinationPath: pathOf('three.zip'),
    );
    var resumedDuringFirst = false;
    var thirdStarted = false;
    final pausedAfterSecond = Completer<void>();
    final subscription = job.progress.listen((progress) {
      if (progress.entryName == 'first' &&
          progress.entryProcessedBytes > 0 &&
          !resumedDuringFirst) {
        resumedDuringFirst = true;
        job.pause();
        job.resume();
      }
      if (progress.completedEntries == 2 && !pausedAfterSecond.isCompleted) {
        job.pause();
        pausedAfterSecond.complete();
      }
      if (progress.entryName == 'third') thirdStarted = true;
    });

    await pausedAfterSecond.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(thirdStarted, isFalse);
    job.resume();

    await job.done;
    await subscription.cancel();
  });

  test('escapes control and bidi text in displayed archive errors', () {
    const rawPath = 'line\nbidi\u202efile\u2028next\u2029last';
    const error = LocalArchiveException(
      LocalArchiveErrorKind.unsafeEntry,
      'bad\nmessage',
      path: rawPath,
    );

    expect(error.path, rawPath);
    expect(error.toString(), contains(r'bad\nmessage'));
    expect(
      error.toString(),
      contains(r'line\nbidi\u{202e}file\u{2028}next\u{2029}last'),
    );
    expect(error.toString(), isNot(contains('\u202e')));
    expect(error.toString(), isNot(contains('\u2028')));
    expect(error.toString(), isNot(contains('\u2029')));
    expect(error.toString(), isNot(contains('\n')));
  });

  test(
    'rejects reserved stage outputs and preserves safe marker output',
    () async {
      final archive = File(pathOf('marker.zip'));
      _writeZip(archive, [
        ArchiveFile.string(_stageMarkerName, _stageMarkerContents),
        ArchiveFile.string('user', 'data'),
      ]);
      final reserved = pathOf('.poltergeist-archive-${'d' * 32}.stage');

      await _expectArchiveError(
        service.extractZip(
          archivePath: archive.path,
          destinationPath: reserved,
        ),
        LocalArchiveErrorKind.conflict,
      );

      final safe = await service
          .extractZip(
            archivePath: archive.path,
            destinationPath: pathOf('safe-output'),
          )
          .done;
      await service.close();
      service = LocalArchiveService();
      final source = File(pathOf('source-after-marker'))
        ..writeAsStringSync('data');
      await service
          .createZip(
            sourcePaths: [source.path],
            destinationPath: pathOf('after-marker.zip'),
          )
          .done;

      expect(Directory(safe.destinationPath).existsSync(), isTrue);
      expect(
        File(p.join(safe.destinationPath, _stageMarkerName)).readAsStringSync(),
        _stageMarkerContents,
      );
    },
  );

  test('rejects nested marker-bearing reserved stage entries', () async {
    final stageName = '.poltergeist-archive-${'f' * 32}.stage';
    final archive = File(pathOf('nested-marker.zip'));
    _writeZip(archive, [
      ArchiveFile.string('$stageName/$_stageMarkerName', _stageMarkerContents),
      ArchiveFile.string('$stageName/user', 'data'),
    ]);

    await _expectArchiveError(
      service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('parent'),
      ),
      LocalArchiveErrorKind.unsafeEntry,
    );
    expect(Directory(pathOf('parent')).existsSync(), isFalse);
  });

  test('cancel interrupts active codec work and removes its stage', () async {
    const sourceBytes = 16 * 1024 * 1024;
    final bytes = Uint8List(sourceBytes);
    final random = Random(1);
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = random.nextInt(256);
    }
    final source = File(pathOf('large.bin'))..writeAsBytesSync(bytes);
    final job = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('interrupted.zip'),
    );
    await job.progress
        .firstWhere(
          (progress) =>
              progress.phase == LocalArchivePhase.compressing &&
              progress.entryProcessedBytes > 0,
        )
        .timeout(const Duration(seconds: 10));

    job.cancel();
    await _expectArchiveError(job, LocalArchiveErrorKind.cancelled);
    expect(File(pathOf('interrupted.zip')).existsSync(), isFalse);
    expect(_stageNames(root), isEmpty);
  });

  test('repeated active cancellation releases native descriptors', () async {
    if (!Platform.isLinux) {
      markTestSkipped('Linux exposes process descriptors through procfs');
      return;
    }
    const sourceBytes = 8 * 1024 * 1024;
    final bytes = Uint8List(sourceBytes);
    final random = Random(11);
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = random.nextInt(256);
    }
    final source = File(pathOf('cancel-descriptors.bin'))
      ..writeAsBytesSync(bytes);

    for (var attempt = 0; attempt < 3; attempt++) {
      final job = service.createZip(
        sourcePaths: [source.path],
        destinationPath: pathOf('cancel-descriptors-$attempt.zip'),
      );
      await job.progress
          .firstWhere(
            (progress) =>
                progress.phase == LocalArchivePhase.compressing &&
                progress.entryProcessedBytes > 0,
          )
          .timeout(const Duration(seconds: 10));
      expect(_linuxDescriptorsFor(source.path), isNotEmpty);

      job.cancel();
      await _expectArchiveError(job, LocalArchiveErrorKind.cancelled);
      expect(_linuxDescriptorsFor(source.path), isEmpty);
    }
  });

  test(
    'cancel interrupts active extraction and releases its descriptor',
    () async {
      if (!Platform.isLinux) {
        markTestSkipped('Linux exposes process descriptors through procfs');
        return;
      }
      const sourceBytes = 8 * 1024 * 1024;
      final bytes = Uint8List(sourceBytes);
      final random = Random(12);
      for (var index = 0; index < bytes.length; index++) {
        bytes[index] = random.nextInt(256);
      }
      final archive = File(pathOf('cancel-extraction.zip'));
      _writeZip(archive, [
        ArchiveFile.noCompress('large.bin', bytes.length, bytes),
      ]);
      final job = service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('cancel-extraction'),
      );
      await job.progress
          .firstWhere(
            (progress) =>
                progress.phase == LocalArchivePhase.extracting &&
                progress.entryProcessedBytes > 0,
          )
          .timeout(const Duration(seconds: 10));
      expect(_linuxDescriptorsFor(archive.path), isNotEmpty);

      job.cancel();
      await _expectArchiveError(job, LocalArchiveErrorKind.cancelled);

      expect(_linuxDescriptorsFor(archive.path), isEmpty);
      expect(Directory(pathOf('cancel-extraction')).existsSync(), isFalse);
    },
  );

  test('cancel at extraction preparation releases its descriptor', () async {
    if (!Platform.isLinux) {
      markTestSkipped('Linux exposes process descriptors through procfs');
      return;
    }
    final archive = File(pathOf('cancel-preparing-extraction.zip'));
    _writeZip(archive, [ArchiveFile.string('data.txt', 'data')]);

    for (var attempt = 0; attempt < 3; attempt++) {
      final preparing = Completer<void>();
      late final LocalArchiveJob job;
      job = service.extractZip(
        archivePath: archive.path,
        destinationPath: pathOf('cancel-preparing-extraction-$attempt'),
      );
      final progress = job.progress.listen((event) {
        if (event.phase != LocalArchivePhase.preparing ||
            preparing.isCompleted) {
          return;
        }
        job.pause();
        preparing.complete();
      });
      await preparing.future.timeout(const Duration(seconds: 10));
      expect(_linuxDescriptorsFor(archive.path), isNotEmpty);

      job.cancel();
      await _expectArchiveError(job, LocalArchiveErrorKind.cancelled);
      await progress.cancel();
      expect(_linuxDescriptorsFor(archive.path), isEmpty);
    }
  });

  test('cancel interrupts a blocked ownership key lock', () async {
    await service.close();
    final support = Directory(pathOf('ownership-lock-support'))..createSync();
    service = LocalArchiveService(supportDirectoryPath: support.path);
    final source = File(pathOf('ownership-lock-source'))
      ..writeAsStringSync('data');
    await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('ownership-lock-seed.zip'),
        )
        .done;
    await service.close();

    final keyPath = p.join(
      support.path,
      _archiveStateDirectoryName,
      _ownershipKeyName,
    );
    final helper = await _startArchiveHelper(['hold-file-lock', keyPath]);
    addTearDown(() => _stopHelper(helper.$1));
    await helper.$2
        .firstWhere((line) => line == 'ready')
        .timeout(_archiveHelperReadyTimeout);
    service = LocalArchiveService(supportDirectoryPath: support.path);
    final job = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('ownership-lock-cancelled.zip'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final stopwatch = Stopwatch()..start();
    job.cancel();

    try {
      await _expectArchiveError(
        job,
        LocalArchiveErrorKind.cancelled,
      ).timeout(const Duration(seconds: 2));
      stopwatch.stop();
    } finally {
      helper.$1.stdin.writeln('release');
      expect(await helper.$1.exitCode, 0);
    }
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(File(pathOf('ownership-lock-cancelled.zip')).existsSync(), isFalse);
  });

  test('serializes same-process ownership key lock waiters', () async {
    if (!Platform.isLinux) {
      markTestSkipped('Linux exposes process descriptors through procfs');
      return;
    }
    await service.close();
    final support = Directory(pathOf('ownership-waiter-support'))..createSync();
    service = LocalArchiveService(supportDirectoryPath: support.path);
    final source = File(pathOf('ownership-waiter-source'))
      ..writeAsStringSync('data');
    await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('ownership-waiter-seed.zip'),
        )
        .done;
    await service.close();

    final keyPath = p.join(
      support.path,
      _archiveStateDirectoryName,
      _ownershipKeyName,
    );
    final helper = await _startArchiveHelper(['hold-file-lock', keyPath]);
    addTearDown(() => _stopHelper(helper.$1));
    await helper.$2
        .firstWhere((line) => line == 'ready')
        .timeout(_archiveHelperReadyTimeout);
    final services = List<LocalArchiveService>.generate(
      8,
      (_) => LocalArchiveService(supportDirectoryPath: support.path),
    );
    service = services.first;
    addTearDown(() async {
      for (final candidate in services.skip(1)) {
        await candidate.close();
      }
    });
    final jobs = <LocalArchiveJob>[];
    for (var index = 0; index < services.length; index++) {
      jobs.add(
        services[index].createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('ownership-waiter-$index.zip'),
        ),
      );
    }

    try {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (_linuxDescriptorsFor(keyPath).isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail('ownership key waiter did not open the key');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(_linuxDescriptorsFor(keyPath), hasLength(1));
    } finally {
      for (final job in jobs) {
        job.cancel();
      }
      try {
        await Future.wait(
          jobs.map(
            (job) => _expectArchiveError(
              job,
              LocalArchiveErrorKind.cancelled,
            ).timeout(const Duration(seconds: 2)),
          ),
        );
        expect(_linuxDescriptorsFor(keyPath), isEmpty);
      } finally {
        helper.$1.stdin.writeln('release');
        expect(await helper.$1.exitCode, 0);
      }
    }
  });

  test('serializes concurrent ownership key initialization', () async {
    await service.close();
    final support = Directory(pathOf('ownership-race-support'))..createSync();
    final source = File(pathOf('ownership-race-source'))
      ..writeAsStringSync('data');
    final services = List<LocalArchiveService>.generate(
      12,
      (_) => LocalArchiveService(supportDirectoryPath: support.path),
    );
    service = services.first;
    addTearDown(() async {
      for (final candidate in services.skip(1)) {
        await candidate.close();
      }
    });

    final jobs = <LocalArchiveJob>[];
    for (var index = 0; index < services.length; index++) {
      jobs.add(
        services[index].createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('ownership-race-$index.zip'),
        ),
      );
    }
    await Future.wait(jobs.map((job) => job.done));

    expect(_readOwnershipKey(support), hasLength(_ownershipKeyBytes));
  });

  test('stage cleanup failure preserves the primary cancellation', () async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      markTestSkipped('This regression uses POSIX directory permissions');
      return;
    }
    final source = File(pathOf('cleanup-failure-source'))
      ..writeAsStringSync('data');
    final job = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('cleanup-failure.zip'),
    );
    job.pause();
    await _waitForStage(root);
    final stage = Directory(p.join(root.path, _stageNames(root).single));
    expect(Process.runSync('chmod', ['0500', root.path]).exitCode, 0);

    try {
      job.cancel();
      await _expectArchiveError(job, LocalArchiveErrorKind.cancelled);
      expect(stage.existsSync(), isTrue);
    } finally {
      expect(Process.runSync('chmod', ['0700', root.path]).exitCode, 0);
    }
  });

  test('cancel interrupts a blocked interprocess commit lock', () async {
    final source = File(pathOf('commit-lock-source'))
      ..writeAsStringSync('data');
    await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('commit-lock-seed.zip'),
        )
        .done;
    final lockDirectory = await _archiveLockDirectory();
    final parentPath = await root.resolveSymbolicLinks();
    final lockName = '${sha256.convert(utf8.encode(parentPath))}.lock';
    final helper = await _startArchiveHelper([
      'hold-file-lock',
      p.join(lockDirectory.path, lockName),
    ]);
    addTearDown(() => _stopHelper(helper.$1));
    await helper.$2
        .firstWhere((line) => line == 'ready')
        .timeout(_archiveHelperReadyTimeout);

    final job = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('commit-lock-cancelled.zip'),
    );
    await job.progress.firstWhere(
      (progress) =>
          progress.phase == LocalArchivePhase.compressing &&
          progress.completedEntries == progress.totalEntries,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final stopwatch = Stopwatch()..start();
    job.cancel();

    await _expectArchiveError(
      job,
      LocalArchiveErrorKind.cancelled,
    ).timeout(const Duration(seconds: 2));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(File(pathOf('commit-lock-cancelled.zip')).existsSync(), isFalse);
    expect(_stageNames(root), isEmpty);
    helper.$1.stdin.writeln('release');
    expect(await helper.$1.exitCode, 0);
  });

  test('a cancelled commit waiter does not poison later jobs', () async {
    final source = File(pathOf('commit-queue-source'))
      ..writeAsStringSync('data');
    await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('commit-queue-seed.zip'),
        )
        .done;
    final lockDirectory = await _archiveLockDirectory();
    final parentPath = await root.resolveSymbolicLinks();
    final lockName = '${sha256.convert(utf8.encode(parentPath))}.lock';
    final helper = await _startArchiveHelper([
      'hold-file-lock',
      p.join(lockDirectory.path, lockName),
    ]);
    addTearDown(() => _stopHelper(helper.$1));
    await helper.$2
        .firstWhere((line) => line == 'ready')
        .timeout(_archiveHelperReadyTimeout);

    final first = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('commit-queue-first.zip'),
    );
    final second = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('commit-queue-second.zip'),
    );
    await Future.wait([
      first.progress.firstWhere(
        (progress) => progress.completedEntries == progress.totalEntries,
      ),
      second.progress.firstWhere(
        (progress) => progress.completedEntries == progress.totalEntries,
      ),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    second.cancel();
    await _expectArchiveError(
      second,
      LocalArchiveErrorKind.cancelled,
    ).timeout(const Duration(seconds: 2));

    helper.$1.stdin.writeln('release');
    expect(await helper.$1.exitCode, 0);
    await first.done.timeout(const Duration(seconds: 5));
    final third = await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('commit-queue-third.zip'),
        )
        .done
        .timeout(const Duration(seconds: 5));

    expect(File(third.destinationPath).existsSync(), isTrue);
  });

  test(
    'sweeps signed abandoned stages but preserves forged user folders',
    () async {
      await service.close();
      final support = Directory(pathOf('sweep-support'))..createSync();
      service = LocalArchiveService(supportDirectoryPath: support.path);
      final source = File(pathOf('source'))..writeAsStringSync('data');
      await service
          .createZip(
            sourcePaths: [source.path],
            destinationPath: pathOf('sweep-seed.zip'),
          )
          .done;
      final key = _readOwnershipKey(support);
      final stale = Directory(pathOf('.poltergeist-archive-${'a' * 32}.stage'))
        ..createSync();
      File(
        p.join(stale.path, _stageMarkerName),
      ).writeAsStringSync(_signedStageMarker(stale.path, key));
      File(p.join(stale.path, '.poltergeist-archive-lease')).createSync();
      final forged = Directory(pathOf('.poltergeist-archive-${'d' * 32}.stage'))
        ..createSync();
      File(
        p.join(forged.path, _stageMarkerName),
      ).writeAsStringSync(_stageMarkerContents * 32768);
      final forgedUser = File(p.join(forged.path, 'user.txt'))
        ..writeAsStringSync('keep');
      final unmarked = Directory(
        pathOf('.poltergeist-archive-${'c' * 32}.stage'),
      )..createSync();
      File(p.join(unmarked.path, 'user.txt')).writeAsStringSync('keep');
      final lookalike = Directory(
        pathOf('.poltergeist-archive-${'b' * 31}.stage'),
      )..createSync();

      await service
          .createZip(
            sourcePaths: [source.path],
            destinationPath: pathOf('archive.zip'),
          )
          .done;

      expect(stale.existsSync(), isFalse);
      expect(forgedUser.readAsStringSync(), 'keep');
      expect(
        File(p.join(unmarked.path, 'user.txt')).readAsStringSync(),
        'keep',
      );
      expect(lookalike.existsSync(), isTrue);
    },
  );

  test('a startup sweep preserves another process live stage lease', () async {
    await service.close();
    final support = Directory(pathOf('lease-support'))..createSync();
    service = LocalArchiveService(supportDirectoryPath: support.path);
    final source = File(pathOf('lease-source'))..writeAsStringSync('data');
    await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('lease-seed.zip'),
        )
        .done;
    final live = pathOf('.poltergeist-archive-${'e' * 32}.stage');
    final marker = _signedStageMarker(live, _readOwnershipKey(support));
    final helper = await _startArchiveHelper(['hold-lease', live, marker]);
    addTearDown(() => _stopHelper(helper.$1));
    await helper.$2
        .firstWhere((line) => line == 'ready')
        .timeout(_archiveHelperReadyTimeout);
    await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('lease-trigger.zip'),
        )
        .done;

    expect(Directory(live).existsSync(), isTrue);
    helper.$1.stdin.writeln('release');
    expect(await helper.$1.exitCode, 0);
    await service.close();
    service = LocalArchiveService(supportDirectoryPath: support.path);
    await service
        .createZip(
          sourcePaths: [source.path],
          destinationPath: pathOf('lease-trigger-2.zip'),
        )
        .done;

    expect(Directory(live).existsSync(), isFalse);
  });

  test('cancel waits for worker exit and stage deletion', () async {
    final source = File(pathOf('data.bin'))
      ..writeAsBytesSync(Uint8List(1024 * 1024));
    final job = service.createZip(
      sourcePaths: [source.path],
      destinationPath: pathOf('cancelled.zip'),
    );
    job.pause();
    await _waitForStage(root);
    if (Platform.isLinux || Platform.isMacOS) {
      final stage = Directory(p.join(root.path, _stageNames(root).single));
      expect((await stage.stat()).mode & 0x1ff, 0x1c0);
    }

    job.cancel();
    await _expectArchiveError(job, LocalArchiveErrorKind.cancelled);

    expect(File(pathOf('cancelled.zip')).existsSync(), isFalse);
    expect(_stageNames(root), isEmpty);
  });
}

void _writeZip(File file, List<ArchiveFile> entries, {String? password}) {
  final archive = Archive();
  for (final entry in entries) {
    archive.add(entry);
  }
  final output = OutputFileStream(file.path);
  try {
    ZipEncoder(password: password).encodeStream(archive, output);
  } finally {
    output.closeSync();
    archive.clearSync();
  }
}

void _writePrecompressedZip(File file, List<List<int>> compressedEntries) {
  final entries = <ArchiveFile>[];
  for (var index = 0; index < compressedEntries.length; index++) {
    entries.add(
      ArchiveFile.file(
          'entry-$index',
          0,
          _PrecompressedContent(compressedEntries[index]),
        )
        ..compression = CompressionType.deflate
        ..crc32 = 0,
    );
  }
  _writeZip(file, entries);
}

List<int> _emptyDeflateBlocks(int count) {
  final bytes = <int>[];
  for (var index = 0; index < count; index++) {
    final isFinal = index + 1 == count;
    bytes.addAll([isFinal ? 1 : 0, 0, 0, 0xff, 0xff]);
  }
  return bytes;
}

void _writeZip64Envelope(
  File file, {
  required int locatorDisk,
  required int locatorDisks,
}) {
  _writeZip(file, [ArchiveFile.string('data', 'value')]);
  final bytes = file.readAsBytesSync().toList();
  final end = _findSignature(bytes, const [0x50, 0x4b, 0x05, 0x06]);
  final entries = _readUint16(bytes, end + 10);
  final centralSize = _readUint32(bytes, end + 12);
  final centralOffset = _readUint32(bytes, end + 16);
  bytes.insertAll(end, <int>[
    ..._uint32Bytes(0x06064b50),
    ..._uint64Bytes(44),
    45,
    0,
    45,
    0,
    ..._uint32Bytes(0),
    ..._uint32Bytes(0),
    ..._uint64Bytes(entries),
    ..._uint64Bytes(entries),
    ..._uint64Bytes(centralSize),
    ..._uint64Bytes(centralOffset),
    ..._uint32Bytes(0x07064b50),
    ..._uint32Bytes(locatorDisk),
    ..._uint64Bytes(end),
    ..._uint32Bytes(locatorDisks),
  ]);
  final movedEnd = end + 76;
  _writeUint16(bytes, movedEnd + 8, 0xffff);
  _writeUint16(bytes, movedEnd + 10, 0xffff);
  _writeUint32(bytes, movedEnd + 12, 0xffffffff);
  _writeUint32(bytes, movedEnd + 16, 0xffffffff);
  file.writeAsBytesSync(bytes);
}

void _writeZip64Descriptor(File file) {
  _writeZip(file, [
    ArchiveFile.noCompress('data', 4, [1, 2, 3, 4]),
  ]);
  final bytes = file.readAsBytesSync().toList();
  final oldCentral = _findSignature(bytes, const [0x50, 0x4b, 0x01, 0x02]);
  final crc32 = _readUint32(bytes, oldCentral + 16);
  final compressedSize = _readUint32(bytes, oldCentral + 20);
  final uncompressedSize = _readUint32(bytes, oldCentral + 24);
  _writeUint16(bytes, 4, 45);
  _writeUint16(bytes, 6, _readUint16(bytes, 6) | 0x0008);
  _writeUint32(bytes, 14, 0);
  _writeUint32(bytes, 18, 0);
  _writeUint32(bytes, 22, 0);
  bytes.insertAll(oldCentral, <int>[
    ..._uint32Bytes(0x08074b50),
    ..._uint32Bytes(crc32),
    ..._uint64Bytes(compressedSize),
    ..._uint64Bytes(uncompressedSize),
  ]);

  const descriptorLength = 24;
  final central = oldCentral + descriptorLength;
  _writeUint16(bytes, central + 6, 45);
  _writeUint16(bytes, central + 8, _readUint16(bytes, central + 8) | 0x0008);
  _writeUint32(bytes, central + 20, 0xffffffff);
  _writeUint32(bytes, central + 24, 0xffffffff);
  _writeUint16(bytes, central + 30, 20);
  final nameLength = _readUint16(bytes, central + 28);
  bytes.insertAll(central + 46 + nameLength, <int>[
    1,
    0,
    16,
    0,
    ..._uint64Bytes(uncompressedSize),
    ..._uint64Bytes(compressedSize),
  ]);

  final end = _findSignature(bytes, const [0x50, 0x4b, 0x05, 0x06]);
  _writeUint32(bytes, end + 12, _readUint32(bytes, end + 12) + 20);
  _writeUint32(bytes, end + 16, central);
  file.writeAsBytesSync(bytes);
}

void _writeZip45DescriptorWithZip64Offset(File file) {
  _writeZip(file, [
    ArchiveFile.noCompress('data', 4, [1, 2, 3, 4]),
  ]);
  final bytes = file.readAsBytesSync().toList();
  final oldCentral = _findSignature(bytes, const [0x50, 0x4b, 0x01, 0x02]);
  final crc32 = _readUint32(bytes, oldCentral + 16);
  final compressedSize = _readUint32(bytes, oldCentral + 20);
  final uncompressedSize = _readUint32(bytes, oldCentral + 24);
  _writeUint16(bytes, 4, 45);
  _writeUint16(bytes, 6, _readUint16(bytes, 6) | 0x0008);
  _writeUint32(bytes, 14, 0);
  _writeUint32(bytes, 18, 0);
  _writeUint32(bytes, 22, 0);
  bytes.insertAll(oldCentral, <int>[
    ..._uint32Bytes(0x08074b50),
    ..._uint32Bytes(crc32),
    ..._uint32Bytes(compressedSize),
    ..._uint32Bytes(uncompressedSize),
  ]);

  const descriptorLength = 16;
  final central = oldCentral + descriptorLength;
  _writeUint16(bytes, central + 6, 45);
  _writeUint16(bytes, central + 8, _readUint16(bytes, central + 8) | 0x0008);
  _writeUint32(bytes, central + 42, 0xffffffff);
  _writeUint16(bytes, central + 30, 12);
  final nameLength = _readUint16(bytes, central + 28);
  bytes.insertAll(central + 46 + nameLength, <int>[
    1,
    0,
    8,
    0,
    ..._uint64Bytes(0),
  ]);

  final end = _findSignature(bytes, const [0x50, 0x4b, 0x05, 0x06]);
  _writeUint32(bytes, end + 12, _readUint32(bytes, end + 12) + 12);
  _writeUint32(bytes, end + 16, central);
  file.writeAsBytesSync(bytes);
}

Future<void> _expectArchiveError(
  LocalArchiveJob job,
  LocalArchiveErrorKind kind,
) async {
  await expectLater(
    job.done,
    throwsA(
      isA<LocalArchiveException>().having((error) => error.kind, 'kind', kind),
    ),
  );
}

Uint8List _readOwnershipKey(Directory support) => File(
  p.join(support.path, _archiveStateDirectoryName, _ownershipKeyName),
).readAsBytesSync();

String _signedStageMarker(String stagePath, List<int> key) {
  final digest = Hmac(sha256, key).convert(utf8.encode(stagePath));
  return '$_stageMarkerPrefix$digest\n';
}

List<String> _stageNames(Directory root) => root
    .listSync(followLinks: false)
    .map((entry) => p.basename(entry.path))
    .where(
      (name) =>
          RegExp(r'^\.poltergeist-archive-[0-9a-f]{32}\.stage$').hasMatch(name),
    )
    .toList();

List<String> _linuxDescriptorsFor(String path) {
  final expected = File(path).resolveSymbolicLinksSync();
  final descriptors = <String>[];

  // Other test isolates share this process, so match targets instead of counts.
  for (final entry in Directory('/proc/self/fd').listSync(followLinks: false)) {
    try {
      if (Link(entry.path).targetSync() != expected) continue;
      descriptors.add(p.basename(entry.path));
    } on FileSystemException {
      // A concurrent close can remove a descriptor after the directory scan.
    }
  }
  return descriptors;
}

Future<void> _waitForStage(Directory root) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final names = _stageNames(root);
    if (names.length == 1 &&
        FileSystemEntity.typeSync(
              p.join(root.path, names.single, _stageMarkerName),
              followLinks: false,
            ) ==
            FileSystemEntityType.file) {
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('archive stage was not initialized');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

int _findSignature(List<int> bytes, List<int> signature) {
  for (var offset = 0; offset <= bytes.length - signature.length; offset++) {
    var matches = true;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return offset;
  }
  throw StateError('ZIP signature not found');
}

void _writeUint32(List<int> bytes, int offset, int value) {
  for (var index = 0; index < 4; index++) {
    bytes[offset + index] = (value >> (index * 8)) & 0xff;
  }
}

int _readUint16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _readUint32(List<int> bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

void _writeUint16(List<int> bytes, int offset, int value) {
  for (var index = 0; index < 2; index++) {
    bytes[offset + index] = (value >> (index * 8)) & 0xff;
  }
}

List<int> _uint32Bytes(int value) => List<int>.generate(
  4,
  (index) => (value >> (index * 8)) & 0xff,
  growable: false,
);

List<int> _uint64Bytes(int value) => List<int>.generate(
  8,
  (index) => (value >> (index * 8)) & 0xff,
  growable: false,
);

void _replaceAscii(List<int> bytes, String before, String after) {
  expect(after.length, before.length);
  final beforeBytes = before.codeUnits;
  final afterBytes = after.codeUnits;
  var replacements = 0;
  for (var offset = 0; offset <= bytes.length - beforeBytes.length; offset++) {
    var matches = true;
    for (var index = 0; index < beforeBytes.length; index++) {
      if (bytes[offset + index] != beforeBytes[index]) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;
    bytes.setRange(offset, offset + afterBytes.length, afterBytes);
    replacements++;
  }
  expect(replacements, 2);
}

Future<(Process, Stream<String>)> _startArchiveHelper(
  List<String> arguments,
) async {
  final packageRelative = p.join(
    'test',
    'archive',
    'archive_process_helper.dart',
  );
  final workspaceRelative = p.join(
    'packages',
    'poltergeist_core',
    packageRelative,
  );
  final helperPath = <String>[
    p.join(Directory.current.path, workspaceRelative),
    p.join(Directory.current.path, packageRelative),
  ].firstWhere((path) => File(path).existsSync());
  final packageConfig = Isolate.packageConfigSync;
  final process = await Process.start(Platform.resolvedExecutable, [
    if (packageConfig != null) '--packages=${packageConfig.toFilePath()}',
    helperPath,
    ...arguments,
  ]);
  final lines = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .asBroadcastStream();
  unawaited(process.stderr.drain<void>());
  return (process, lines);
}

Future<Directory> _archiveLockDirectory() async {
  final environment = Platform.environment;
  String? supportRoot;
  var supportName = 'poltergeist';
  if (Platform.isWindows) {
    supportRoot = environment['LOCALAPPDATA'] ?? environment['APPDATA'];
  } else if (Platform.isMacOS) {
    final home = environment['HOME'];
    if (home != null && home.isNotEmpty) {
      supportRoot = p.join(home, 'Library', 'Caches');
    }
  } else {
    supportRoot = environment['XDG_RUNTIME_DIR'];
    if (supportRoot == null || supportRoot.isEmpty) {
      supportRoot = environment['XDG_CACHE_HOME'];
    }
    if (supportRoot == null || supportRoot.isEmpty) {
      final home = environment['HOME'];
      if (home != null && home.isNotEmpty) {
        supportRoot = p.join(home, '.cache');
      }
    }
  }
  if (supportRoot == null || supportRoot.isEmpty) {
    supportRoot = await Directory.systemTemp.resolveSymbolicLinks();
    supportName = 'poltergeist-${await _testUserScope()}';
  }
  final base = Directory(supportRoot);
  await base.create(recursive: true);
  final resolvedBase = await base.resolveSymbolicLinks();
  return Directory(p.join(resolvedBase, supportName, 'archive-locks-v1'));
}

Future<String> _testUserScope() async {
  if (Platform.isLinux || Platform.isMacOS) {
    for (final executable in const ['/usr/bin/id', '/bin/id']) {
      if (!File(executable).existsSync()) continue;
      final result = await Process.run(executable, const ['-u']);
      final value = '${result.stdout}'.trim();
      if (result.exitCode == 0 && RegExp(r'^\d+$').hasMatch(value)) {
        return value;
      }
    }
  }
  final identity =
      Platform.environment['USERNAME'] ??
      Platform.environment['USER'] ??
      Platform.executable;
  return sha256.convert(utf8.encode(identity)).toString().substring(0, 16);
}

Future<void> _stopHelper(Process process) async {
  try {
    process.stdin.writeln('stop');
    await process.stdin.close();
  } on SocketException {
    // The helper already exited.
  }
  try {
    await process.exitCode.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    process.kill();
    await process.exitCode;
  }
}

final class _PrecompressedContent extends FileContent {
  _PrecompressedContent(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  Uint8List? _bytes;

  @override
  bool get isCompressed => true;

  @override
  int get length => _bytes?.length ?? 0;

  @override
  InputStream getStream({bool decompress = true}) {
    if (decompress) throw StateError('Test data is raw deflate.');
    return InputMemoryStream(_bytes ?? Uint8List(0));
  }

  @override
  void write(OutputStream output) => output.writeBytes(_bytes ?? Uint8List(0));

  @override
  Future<void> close() async => _bytes = null;

  @override
  void closeSync() => _bytes = null;
}
