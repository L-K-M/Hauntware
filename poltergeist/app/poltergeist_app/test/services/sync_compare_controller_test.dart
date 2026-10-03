import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/sync_compare_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

const _serverId = 'server-a';
const _thresholdBytes = 64;

void main() {
  late Directory temporaryDirectory;
  late Directory filesDirectory;
  late PreviewCache cache;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'sync_compare_controller_test_',
    );
    filesDirectory = Directory('${temporaryDirectory.path}/files');
    await filesDirectory.create();
    cache = PreviewCache(
      directory: Directory('${temporaryDirectory.path}/cache'),
    );
    await cache.open();
    _activeCache = cache;
  });

  tearDown(() async {
    _activeCache = null;
    await temporaryDirectory.delete(recursive: true);
  });

  test('loads sides independently when one loader fails', () async {
    final invalid = await _writeFile(filesDirectory, 'invalid.txt', [0xff]);
    final readable = await _writeText(filesDirectory, 'readable.txt', 'right');
    final controller = _controller(
      left: _local(SyncSide.left, invalid),
      right: _local(SyncSide.right, readable),
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.left.phase, SyncComparePhase.failed);
    expect(controller.left.failure, SyncCompareFailure.invalidUtf8);
    expect(controller.right.phase, SyncComparePhase.ready);
    expect(controller.right.document?.text, 'right');
  });

  test('classifies a vanished side without exposing loader copy', () async {
    final readable = await _writeText(filesDirectory, 'readable.txt', 'right');
    final controller = _controller(
      left: LocalSyncCompareSource(
        side: SyncSide.left,
        fullPath: '${filesDirectory.path}/missing.txt',
        snapshot: const EntrySnapshot(kind: EntryKind.file, size: 4),
      ),
      right: _local(SyncSide.right, readable),
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.left.phase, SyncComparePhase.failed);
    expect(controller.left.failure, SyncCompareFailure.missing);
  });

  test('loads local bytes instead of refusing stale scan size', () async {
    final readable = await _writeText(filesDirectory, 'readable.txt', 'small');
    final controller = _controller(
      left: LocalSyncCompareSource(
        side: SyncSide.left,
        fullPath: readable.path,
        snapshot: const EntrySnapshot(
          kind: EntryKind.file,
          size: builtInEditorMaximumBytes + 1,
        ),
      ),
      right: _local(SyncSide.right, readable),
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.left.phase, SyncComparePhase.ready);
    expect(controller.left.document?.text, 'small');
  });

  test('refuses a known over-limit side before cache or producer', () async {
    final readable = await _writeText(filesDirectory, 'readable.txt', 'right');
    final producer = _RecordingProducer();
    final remote = _remote(
      SyncSide.left,
      '/remote/large.txt',
      size: builtInEditorMaximumBytes + 1,
    );
    final controller = _controller(
      left: remote,
      right: _local(SyncSide.right, readable),
      cache: null,
      producer: producer,
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.left.phase, SyncComparePhase.refused);
    expect(controller.left.refusal, SyncCompareRefusal.editorLimit);
    expect(producer.specs, isEmpty);
    expect(controller.right.phase, SyncComparePhase.ready);
  });

  test('a cache hit skips confirmation and production', () async {
    final producer = _RecordingProducer();
    final remote = _remote(
      SyncSide.left,
      '/remote/cached.txt',
      size: 12,
      mtimeSecs: 123,
    );
    await _seedCache(cache, remote, utf8.encode('cached text'));
    final readable = await _writeText(filesDirectory, 'readable.txt', 'right');
    final controller = _controller(
      left: remote,
      right: _local(SyncSide.right, readable),
      producer: producer,
      thresholdBytes: 1,
    );
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.left.phase, SyncComparePhase.ready);
    expect(controller.left.document?.text, 'cached text');
    expect(producer.specs, isEmpty);
  });

  test(
    'confirms a known lowered-threshold download and reports progress',
    () async {
      final producer = _RecordingProducer();
      final remote = _remote(SyncSide.left, '/remote/known.txt', size: 12);
      final readable = await _writeText(
        filesDirectory,
        'readable.txt',
        'right',
      );
      final controller = _controller(
        left: remote,
        right: _local(SyncSide.right, readable),
        producer: producer,
        thresholdBytes: 4,
      );
      addTearDown(controller.dispose);

      final started = controller.start();
      await _until(
        () =>
            controller.left.phase == SyncComparePhase.confirming &&
            controller.right.phase == SyncComparePhase.ready,
      );
      expect(producer.specs, isEmpty);
      expect(controller.right.phase, SyncComparePhase.ready);

      controller.confirm(SyncSide.left);
      await _until(() => producer.specs.isNotEmpty);
      final spec = producer.specs.single;
      expect(spec.serverId, _serverId);
      expect(spec.remotePath, remote.fullPath);
      expect(spec.expectedSize, 12);
      expect(spec.maximumBytes, builtInEditorMaximumBytes);
      expect(spec.gate, isNull);

      producer.progress(0, 7, 12);
      expect(controller.left.transferred, 7);
      expect(controller.left.totalBytes, 12);

      await producer.complete(0, utf8.encode('remote text'));
      await started;

      expect(controller.left.phase, SyncComparePhase.ready);
      expect(controller.left.document?.text, 'remote text');
    },
  );

  test('guards a known-size download whose remote bytes grow', () async {
    final producer = _RecordingProducer();
    final remote = _remote(SyncSide.left, '/remote/grown.txt', size: 2);
    final readable = await _writeText(filesDirectory, 'readable.txt', 'right');
    final controller = _controller(
      left: remote,
      right: _local(SyncSide.right, readable),
      producer: producer,
      thresholdBytes: 3,
    );
    addTearDown(controller.dispose);

    final started = controller.start();
    await _until(() => producer.specs.isNotEmpty);
    final spec = producer.specs.single;
    expect(spec.maximumBytes, builtInEditorMaximumBytes);
    expect(spec.gate, isNotNull);

    final streamed = producer.stream(0, [utf8.encode('ab'), utf8.encode('cd')]);
    await _until(() => controller.left.phase == SyncComparePhase.gateConfirm);

    controller.confirm(SyncSide.left);
    await streamed;
    await started;

    expect(controller.left.document?.text, 'abcd');
  });

  test('maps the tightest stream ceiling to its refusal', () async {
    final smallCache = PreviewCache(
      directory: Directory('${temporaryDirectory.path}/stream-cap-cache'),
      capacityBytes: 5,
    );
    await smallCache.open();
    final producer = _RecordingProducer();
    final readable = await _writeText(filesDirectory, 'readable.txt', 'right');
    final controller = _controller(
      left: _remote(SyncSide.left, '/remote/grown.txt', size: 2),
      right: _local(SyncSide.right, readable),
      cache: smallCache,
      producer: producer,
    );
    addTearDown(controller.dispose);

    final started = controller.start();
    await _until(() => producer.specs.isNotEmpty);
    expect(producer.specs.single.maximumBytes, 5);
    producer.fail(0, const CheckoutLimitException('stream limit exceeded'));
    await started;

    expect(controller.left.refusal, SyncCompareRefusal.cacheLimit);
  });

  test(
    'unknown size pauses inline and resumes through its byte gate',
    () async {
      final producer = _RecordingProducer();
      final remote = _remote(SyncSide.left, '/remote/unknown.txt');
      final readable = await _writeText(
        filesDirectory,
        'readable.txt',
        'right',
      );
      final controller = _controller(
        left: remote,
        right: _local(SyncSide.right, readable),
        producer: producer,
        thresholdBytes: 3,
      );
      addTearDown(controller.dispose);

      final started = controller.start();
      await _until(() => producer.specs.isNotEmpty);
      final spec = producer.specs.single;
      expect(spec.maximumBytes, builtInEditorMaximumBytes);
      expect(spec.gate, isNotNull);

      final streamed = producer.stream(0, [
        utf8.encode('ab'),
        utf8.encode('cdef'),
      ]);
      await _until(() => controller.left.phase == SyncComparePhase.gateConfirm);
      expect(controller.left.transferred, 6);
      expect(controller.right.phase, SyncComparePhase.ready);

      controller.confirm(SyncSide.left);
      await streamed;
      await started;

      expect(controller.left.phase, SyncComparePhase.ready);
      expect(controller.left.document?.text, 'abcdef');
    },
  );

  test('cancelling one side leaves its peer running', () async {
    final producer = _RecordingProducer();
    final controller = _controller(
      left: _remote(SyncSide.left, '/remote/left.txt', size: 4),
      right: _remote(SyncSide.right, '/remote/right.txt', size: 5),
      producer: producer,
    );
    addTearDown(controller.dispose);

    final started = controller.start();
    await _until(() => producer.specs.length == 2);
    final leftIndex = producer.indexOf('/remote/left.txt');
    final rightIndex = producer.indexOf('/remote/right.txt');

    controller.cancel(SyncSide.left);
    await producer.complete(rightIndex, utf8.encode('right'));
    await started;

    expect(controller.left.phase, SyncComparePhase.cancelled);
    expect(producer.cancels, ['produce-$leftIndex']);
    expect(controller.right.phase, SyncComparePhase.ready);
    expect(controller.right.document?.text, 'right');
  });

  test('maps an unknown-size stream cap failure to editor refusal', () async {
    final producer = _RecordingProducer();
    final readable = await _writeText(filesDirectory, 'readable.txt', 'right');
    final controller = _controller(
      left: _remote(SyncSide.left, '/remote/unknown.txt'),
      right: _local(SyncSide.right, readable),
      producer: producer,
    );
    addTearDown(controller.dispose);

    final started = controller.start();
    await _until(() => producer.specs.isNotEmpty);
    producer.fail(0, const CheckoutLimitException('editor limit exceeded'));
    await started;

    expect(controller.left.phase, SyncComparePhase.refused);
    expect(controller.left.refusal, SyncCompareRefusal.editorLimit);
    expect(controller.right.phase, SyncComparePhase.ready);
  });

  test('maps a vanished remote side to the missing reason', () async {
    final producer = _RecordingProducer();
    final readable = await _writeText(filesDirectory, 'readable.txt', 'right');
    final controller = _controller(
      left: _remote(SyncSide.left, '/remote/vanished.txt', size: 4),
      right: _local(SyncSide.right, readable),
      producer: producer,
    );
    addTearDown(controller.dispose);

    final started = controller.start();
    await _until(() => producer.specs.isNotEmpty);
    producer.fail(
      0,
      const RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'sync compare',
        message: 'remote file vanished',
      ),
    );
    await started;

    expect(controller.left.phase, SyncComparePhase.failed);
    expect(controller.left.failure, SyncCompareFailure.missing);
  });

  test('distinguishes unavailable dependencies and cache capacity', () async {
    final readable = await _writeText(filesDirectory, 'readable.txt', 'right');
    final remote = _remote(SyncSide.left, '/remote/file.txt', size: 8);
    final noCache = _controller(
      left: remote,
      right: _local(SyncSide.right, readable),
      cache: null,
    );
    addTearDown(noCache.dispose);
    await noCache.start();
    expect(noCache.left.refusal, SyncCompareRefusal.cacheUnavailable);

    final noProducer = _controller(
      left: remote,
      right: _local(SyncSide.right, readable),
      producer: null,
    );
    addTearDown(noProducer.dispose);
    await noProducer.start();
    expect(noProducer.left.refusal, SyncCompareRefusal.producerUnavailable);

    final smallCache = PreviewCache(
      directory: Directory('${temporaryDirectory.path}/small-cache'),
      capacityBytes: 4,
    );
    await smallCache.open();
    final recording = _RecordingProducer();
    final overCapacity = _controller(
      left: remote,
      right: _local(SyncSide.right, readable),
      cache: smallCache,
      producer: recording,
    );
    addTearDown(overCapacity.dispose);
    await overCapacity.start();
    expect(overCapacity.left.refusal, SyncCompareRefusal.cacheLimit);
    expect(recording.specs, isEmpty);
  });

  test('serializes identical cache keys into one production', () async {
    final producer = _RecordingProducer();
    final snapshot = const EntrySnapshot(
      kind: EntryKind.file,
      size: 4,
      mtimeSecs: 456,
    );
    final controller = _controller(
      left: RemoteSyncCompareSource(
        side: SyncSide.left,
        fullPath: '/remote/same.txt',
        snapshot: snapshot,
        serverId: _serverId,
      ),
      right: RemoteSyncCompareSource(
        side: SyncSide.right,
        fullPath: '/remote/same.txt',
        snapshot: snapshot,
        serverId: _serverId,
      ),
      producer: producer,
    );
    addTearDown(controller.dispose);

    final started = controller.start();
    await _until(() => producer.specs.isNotEmpty);
    await producer.complete(0, utf8.encode('same'));
    await started;

    expect(producer.specs, hasLength(1));
    expect(controller.left.document?.text, 'same');
    expect(controller.right.document?.text, 'same');
  });

  test('deduplicates a cache key across comparison controllers', () async {
    final producer = _RecordingProducer();
    final firstLocal = await _writeText(filesDirectory, 'first.txt', 'first');
    final secondLocal = await _writeText(
      filesDirectory,
      'second.txt',
      'second',
    );
    final remote = _remote(
      SyncSide.left,
      '/remote/shared.txt',
      size: 6,
      mtimeSecs: 789,
    );
    final first = _controller(
      left: remote,
      right: _local(SyncSide.right, firstLocal),
      producer: producer,
    );
    final second = _controller(
      left: remote,
      right: _local(SyncSide.right, secondLocal),
      producer: producer,
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    final started = Future.wait([first.start(), second.start()]);
    await _until(() => producer.specs.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final productionCount = producer.specs.length;
    for (var index = 0; index < productionCount; index++) {
      await producer.complete(index, utf8.encode('shared'));
    }
    await started;

    expect(productionCount, 1);
    expect(first.left.document?.text, 'shared');
    expect(second.left.document?.text, 'shared');
  });

  test('dispose cancels tickets and aborts open cache slots', () async {
    final producer = _RecordingProducer();
    final readable = await _writeText(filesDirectory, 'readable.txt', 'right');
    final controller = _controller(
      left: _remote(SyncSide.left, '/remote/held.txt', size: 4),
      right: _local(SyncSide.right, readable),
      producer: producer,
    );

    final started = controller.start();
    await _until(() => producer.specs.isNotEmpty);
    final destination = File(producer.specs.single.destinationPath);
    expect(await destination.exists(), isTrue);

    controller.dispose();
    await started;
    await _until(() async => !await destination.exists());

    expect(producer.cancels, ['produce-0']);
  });
}

SyncCompareController _controller({
  required SyncCompareSource left,
  required SyncCompareSource right,
  Object? cache = _fixtureDependency,
  Object? producer = _fixtureDependency,
  int thresholdBytes = _thresholdBytes,
}) {
  final resolvedCache = identical(cache, _fixtureDependency)
      ? _activeCache
      : cache as PreviewCache?;
  final resolvedProducer = identical(producer, _fixtureDependency)
      ? _RecordingProducer()
      : producer as PreviewProducer?;
  return SyncCompareController(
    request: SyncCompareRequest(
      relativePath: 'file.txt',
      left: left,
      right: right,
    ),
    previewCache: resolvedCache,
    previewProducer: resolvedProducer,
    largeDownloadThresholdBytes: () => thresholdBytes,
  );
}

PreviewCache? _activeCache;
const _fixtureDependency = Object();

LocalSyncCompareSource _local(SyncSide side, File file) =>
    LocalSyncCompareSource(
      side: side,
      fullPath: file.path,
      snapshot: EntrySnapshot(kind: EntryKind.file, size: file.lengthSync()),
    );

RemoteSyncCompareSource _remote(
  SyncSide side,
  String path, {
  int? size,
  int? mtimeSecs,
}) => RemoteSyncCompareSource(
  side: side,
  fullPath: path,
  snapshot: EntrySnapshot(
    kind: EntryKind.file,
    size: size,
    mtimeSecs: mtimeSecs,
  ),
  serverId: _serverId,
);

Future<File> _writeText(Directory parent, String name, String text) =>
    _writeFile(parent, name, utf8.encode(text));

Future<File> _writeFile(Directory parent, String name, List<int> bytes) async {
  final file = File('${parent.path}/$name');
  await file.writeAsBytes(bytes);
  return file;
}

Future<void> _seedCache(
  PreviewCache cache,
  RemoteSyncCompareSource source,
  List<int> bytes,
) async {
  final slot = await cache.prepare(
    _keyFor(source),
    extension: previewRawExtension(source.fullPath),
    expectedBytes: source.snapshot.size,
  );
  await slot.tempFile.writeAsBytes(bytes);
  await slot.commit();
}

String _keyFor(RemoteSyncCompareSource source) => previewCacheKey(
  source.serverId,
  source.fullPath,
  source.snapshot.mtimeSecs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          source.snapshot.mtimeSecs! * Duration.millisecondsPerSecond,
          isUtc: true,
        ),
  source.snapshot.size,
);

Future<void> _until(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was not reached');
}

final class _RecordingProducer implements PreviewProducer {
  final specs = <PreviewProduceSpec>[];
  final cancels = <String>[];
  final _completers = <Completer<RemoteFileEntry>>[];

  @override
  PreviewProduceTicket start(PreviewProduceSpec spec) {
    final index = specs.length;
    specs.add(spec);
    _completers.add(Completer<RemoteFileEntry>());
    return PreviewProduceTicket(
      taskId: 'produce-$index',
      result: _completers[index].future,
    );
  }

  @override
  void cancel(String taskId) {
    cancels.add(taskId);
    final index = int.parse(taskId.substring('produce-'.length));
    final completer = _completers[index];
    if (completer.isCompleted) return;
    completer.completeError(
      const RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: 'sync compare',
        message: 'cancelled',
      ),
    );
  }

  int indexOf(String remotePath) =>
      specs.indexWhere((spec) => spec.remotePath == remotePath);

  void progress(int index, int transferred, int? total) =>
      specs[index].onProgress?.call(transferred, total);

  Future<void> complete(int index, List<int> bytes) async {
    final spec = specs[index];
    await File(spec.destinationPath).writeAsBytes(bytes, flush: true);
    _complete(index, bytes.length);
  }

  Future<void> stream(int index, List<List<int>> chunks) async {
    final spec = specs[index];
    final fileSink = File(spec.destinationPath).openWrite();
    final sink = spec.gate?.wrap(fileSink) ?? fileSink;
    await sink.addStream(Stream.fromIterable(chunks));
    await sink.close();
    _complete(index, chunks.fold(0, (sum, chunk) => sum + chunk.length));
  }

  void fail(int index, Object error) => _completers[index].completeError(error);

  void _complete(int index, int size) {
    final spec = specs[index];
    _completers[index].complete(
      RemoteFileEntry(
        path: spec.remotePath,
        name: spec.remotePath.split('/').last,
        type: RemoteFileType.file,
        size: size,
      ),
    );
  }
}
