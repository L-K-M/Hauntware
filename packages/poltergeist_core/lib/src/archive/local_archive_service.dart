library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../fs/local_fs_safety.dart';
import '../transfer/conflict_policy.dart';
import '../transfer/destination_name_key.dart';

part 'local_archive_native_io.dart';
part 'local_archive_worker.dart';

const int _defaultMaximumArchiveEntries = 100000;
const int _defaultMaximumArchiveEntryBytes = 16 * 1024 * 1024 * 1024;
const int _defaultMaximumArchiveTotalBytes = 64 * 1024 * 1024 * 1024;
const int _defaultMaximumArchiveDepth = 128;
const int _defaultMaximumArchivePathComponents = 1000000;
const int _defaultMaximumArchiveMetadataBytes = 256 * 1024 * 1024;
// Raw DEFLATE may expand incompressible input. These ceilings leave framing
// headroom while the public 16/64 GiB limits remain uncompressed-byte limits.
const int _defaultMaximumCompressedEntryBytes =
    _defaultMaximumArchiveEntryBytes +
    (_defaultMaximumArchiveEntryBytes >> 3) +
    (_defaultMaximumArchiveEntryBytes >> 6) +
    64;
const int _defaultMaximumCompressedTotalBytes =
    _defaultMaximumArchiveTotalBytes +
    (_defaultMaximumArchiveTotalBytes >> 3) +
    (_defaultMaximumArchiveTotalBytes >> 6) +
    (_defaultMaximumArchiveEntries * 64);
const int _defaultMaximumArchiveFileBytes =
    _defaultMaximumCompressedTotalBytes +
    _defaultMaximumArchiveMetadataBytes +
    (1024 * 1024);
const String _archiveStagePrefix = '.poltergeist-archive-';
const String _archiveStageSuffix = '.stage';
const int _archiveStageIdBytes = 16;
const String _archiveStageMarkerName = '.poltergeist-archive-owner';
const String _archiveStageMarkerPrefix = 'poltergeist-archive-stage-v2:';
const String _archiveStageLeaseName = '.poltergeist-archive-lease';
const String _archiveOwnershipKeyName = 'archive-owner.key';
const int _archiveOwnershipKeyBytes = 32;
const String _archiveStateDirectoryName = 'local-archive-state-v1';
const String _archiveCommitLockDirectoryName = 'archive-locks-v1';
const String _archiveSupportDirectoryName = 'poltergeist';
const String _archiveCommitLockSuffix = '.lock';
const String _ownerDirectoryMode = '700';
const String _ownerFileMode = '600';
const int _ownerDirectoryModeBits = 0x1c0;
const int _ownerFileModeBits = 0x180;
const Duration _archiveCommitLockRetryDelay = Duration(milliseconds: 25);
const Duration _archiveCommitLockTimeout = Duration(seconds: 30);

final RegExp _archiveStagePattern = RegExp(
  '^${RegExp.escape(_archiveStagePrefix)}'
  '[0-9a-f]{${_archiveStageIdBytes * 2}}'
  '${RegExp.escape(_archiveStageSuffix)}\$',
);
final Random _archiveRandom = Random.secure();
final Set<String> _activeArchiveStages = <String>{};
Future<void> _archiveCommitTail = Future<void>.value();

/// Completes a native read request across legal short reads.
///
/// Public only so the internal driver loop can be regression-tested without
/// exposing native handles through [LocalArchiveService].
@visibleForTesting
int readNativeFileFully(
  int count,
  int Function(int offset, int remaining) readChunk,
) {
  if (count < 0) throw RangeError.range(count, 0, null, 'count');

  var total = 0;
  while (total < count) {
    final remaining = count - total;
    final chunk = readChunk(total, remaining);
    if (chunk == 0) return total;
    if (chunk < 0 || chunk > remaining) {
      throw StateError('Native archive read returned an invalid byte count.');
    }
    total += chunk;
  }
  return total;
}

/// Resource ceilings enforced both before and while archive data is decoded.
final class LocalArchiveLimits {
  const LocalArchiveLimits({
    this.maximumEntries = _defaultMaximumArchiveEntries,
    this.maximumEntryBytes = _defaultMaximumArchiveEntryBytes,
    this.maximumTotalBytes = _defaultMaximumArchiveTotalBytes,
    this.maximumDepth = _defaultMaximumArchiveDepth,
    this.maximumPathComponents = _defaultMaximumArchivePathComponents,
    this.maximumMetadataBytes = _defaultMaximumArchiveMetadataBytes,
    this.maximumCompressedEntryBytes = _defaultMaximumCompressedEntryBytes,
    this.maximumCompressedTotalBytes = _defaultMaximumCompressedTotalBytes,
    this.maximumArchiveFileBytes = _defaultMaximumArchiveFileBytes,
  });

  final int maximumEntries;
  final int maximumEntryBytes;
  final int maximumTotalBytes;
  final int maximumDepth;
  final int maximumPathComponents;
  final int maximumMetadataBytes;
  final int maximumCompressedEntryBytes;
  final int maximumCompressedTotalBytes;
  final int maximumArchiveFileBytes;

  void _validate() {
    if (maximumEntries < 1) {
      throw RangeError.range(maximumEntries, 1, null, 'maximumEntries');
    }
    if (maximumEntryBytes < 1) {
      throw RangeError.range(maximumEntryBytes, 1, null, 'maximumEntryBytes');
    }
    if (maximumTotalBytes < 1) {
      throw RangeError.range(maximumTotalBytes, 1, null, 'maximumTotalBytes');
    }
    if (maximumDepth < 1) {
      throw RangeError.range(maximumDepth, 1, null, 'maximumDepth');
    }
    if (maximumPathComponents < 1) {
      throw RangeError.range(
        maximumPathComponents,
        1,
        null,
        'maximumPathComponents',
      );
    }
    if (maximumMetadataBytes < 1) {
      throw RangeError.range(
        maximumMetadataBytes,
        1,
        null,
        'maximumMetadataBytes',
      );
    }
    if (maximumCompressedEntryBytes < 1) {
      throw RangeError.range(
        maximumCompressedEntryBytes,
        1,
        null,
        'maximumCompressedEntryBytes',
      );
    }
    if (maximumCompressedTotalBytes < 1) {
      throw RangeError.range(
        maximumCompressedTotalBytes,
        1,
        null,
        'maximumCompressedTotalBytes',
      );
    }
    if (maximumArchiveFileBytes < 1) {
      throw RangeError.range(
        maximumArchiveFileBytes,
        1,
        null,
        'maximumArchiveFileBytes',
      );
    }
  }
}

enum LocalArchiveOperation { createZip, extractZip }

enum LocalArchivePhase { preparing, compressing, extracting, committing }

enum LocalArchiveErrorKind {
  cancelled,
  invalidArchive,
  unsafeEntry,
  limitExceeded,
  checksumMismatch,
  unsupported,
  conflict,
  io,
}

final class LocalArchiveException implements Exception {
  const LocalArchiveException(this.kind, this.message, {this.path});

  final LocalArchiveErrorKind kind;
  final String message;
  final String? path;

  @override
  String toString() {
    final safeMessage = _escapeArchiveDisplay(message);
    final suffix = path == null ? '' : ' (${_escapeArchiveDisplay(path!)})';
    return 'LocalArchiveException.${kind.name}: $safeMessage$suffix';
  }
}

final class LocalArchiveProgress {
  const LocalArchiveProgress({
    required this.operation,
    required this.phase,
    required this.completedEntries,
    required this.totalEntries,
    required this.processedBytes,
    required this.totalBytes,
    this.entryName,
    this.entryIsDirectory,
    this.entryProcessedBytes = 0,
    this.entryTotalBytes = 0,
  });

  final LocalArchiveOperation operation;
  final LocalArchivePhase phase;
  final String? entryName;
  final bool? entryIsDirectory;
  final int entryProcessedBytes;
  final int entryTotalBytes;
  final int completedEntries;
  final int totalEntries;
  final int processedBytes;
  final int totalBytes;
}

final class LocalArchiveResult {
  const LocalArchiveResult({
    required this.operation,
    required this.requestedDestinationPath,
    required this.destinationPath,
    required this.entries,
    required this.uncompressedBytes,
  });

  final LocalArchiveOperation operation;
  final String requestedDestinationPath;
  final String destinationPath;
  final int entries;
  final int uncompressedBytes;
}

/// A running local archive operation.
///
/// Pause takes effect at the next entry boundary. Cancel kills the retained
/// worker isolate and never claims success for a partially written stage.
abstract interface class LocalArchiveJob {
  String get id;

  LocalArchiveOperation get operation;

  Stream<LocalArchiveProgress> get progress;

  Future<LocalArchiveResult> get done;

  bool get isPaused;

  bool get isCancelled;

  void pause();

  void resume();

  void cancel();
}

/// Runs ZIP work off the caller isolate and commits completed stages atomically.
final class LocalArchiveService {
  factory LocalArchiveService({
    LocalArchiveLimits limits = const LocalArchiveLimits(),
    String? supportDirectoryPath,
  }) => LocalArchiveService._(limits, supportDirectoryPath);

  LocalArchiveService._(this._limits, this._supportDirectoryPath) {
    _limits._validate();
  }

  final LocalArchiveLimits _limits;
  final String? _supportDirectoryPath;
  final Set<_LocalArchiveJob> _jobs = <_LocalArchiveJob>{};
  Future<Uint8List>? _ownershipKey;
  bool _closed = false;

  LocalArchiveJob createZip({
    required List<String> sourcePaths,
    required String destinationPath,
  }) {
    _checkOpen();
    final sourceSnapshot = List<String>.unmodifiable(sourcePaths);
    final job = _LocalArchiveJob(
      id: _newArchiveId(),
      operation: LocalArchiveOperation.createZip,
    );
    _jobs.add(job);

    unawaited(
      Future<void>(() async {
        await _run(
          job,
          sourcePaths: sourceSnapshot,
          sourceArchivePath: null,
          destinationPath: destinationPath,
        );
      }),
    );
    return job;
  }

  LocalArchiveJob extractZip({
    required String archivePath,
    required String destinationPath,
  }) {
    _checkOpen();
    final job = _LocalArchiveJob(
      id: _newArchiveId(),
      operation: LocalArchiveOperation.extractZip,
    );
    _jobs.add(job);

    unawaited(
      Future<void>(() async {
        await _run(
          job,
          sourcePaths: const <String>[],
          sourceArchivePath: archivePath,
          destinationPath: destinationPath,
        );
      }),
    );
    return job;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    final jobs = List<_LocalArchiveJob>.of(_jobs);
    for (final job in jobs) {
      job.cancel();
    }
    await Future.wait<void>(
      jobs.map((job) => job.done.then<void>((_) {}, onError: (_) {})),
    );
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('LocalArchiveService is closed.');
    }
  }

  Future<void> _run(
    _LocalArchiveJob job, {
    required List<String> sourcePaths,
    required String? sourceArchivePath,
    required String destinationPath,
  }) async {
    _ArchiveStage? stage;
    ReceivePort? events;
    ReceivePort? exits;
    ReceivePort? errors;
    StreamSubscription<Object?>? eventSubscription;
    StreamSubscription<Object?>? exitSubscription;
    StreamSubscription<Object?>? errorSubscription;
    Pointer<Uint8>? cancellationSignal;
    LocalArchiveResult? result;
    Object? terminalError;
    StackTrace? terminalStack;

    try {
      _throwIfCancelled(job);
      final destination = await _prepareDestination(destinationPath);
      await _sweepOldStages(destination.parent, job);
      _throwIfCancelled(job);

      final ownershipKey = await _archiveOwnershipKey();
      stage = await _createStage(destination.parent, ownershipKey);

      events = ReceivePort();
      exits = ReceivePort();
      errors = ReceivePort();
      final exitCompleter = Completer<void>();
      _WorkerCompleted? workerCompleted;
      LocalArchiveException? workerFailure;
      Object? isolateError;
      StackTrace? isolateStack;

      exitSubscription = exits.listen((_) {
        if (!exitCompleter.isCompleted) exitCompleter.complete();
      });
      errorSubscription = errors.listen((message) {
        if (message is List<Object?> && message.isNotEmpty) {
          isolateError = message.first;
          if (message.length > 1) {
            isolateStack = StackTrace.fromString('${message[1]}');
          }
        } else {
          isolateError = message;
        }
      });
      eventSubscription = events.listen((message) {
        switch (message) {
          case _WorkerReady(:final commands):
            job._attachWorker(commands);
          case _WorkerProgressEvent(:final progress):
            job._emit(progress);
          case _WorkerBoundary():
            job._continueWorkerAtBoundary();
          case _WorkerStageProbe(:final path, :final reply):
            reply.send(_activeArchiveStages.contains(path));
          case _WorkerCompleted(:final acknowledgement):
            workerCompleted ??= message;
            acknowledgement.send(_workerTerminalAcknowledged);
          case _WorkerFailed(
            :final kind,
            :final message,
            :final path,
            :final acknowledgement,
          ):
            workerFailure ??= LocalArchiveException(kind, message, path: path);
            acknowledgement.send(_workerTerminalAcknowledged);
          default:
            workerFailure ??= const LocalArchiveException(
              LocalArchiveErrorKind.io,
              'Archive worker sent an invalid response.',
            );
        }
      });

      cancellationSignal = calloc<Uint8>();
      job._attachCancellationSignal(cancellationSignal);
      await Isolate.spawn<_WorkerRequest>(
        _runArchiveWorker,
        _WorkerRequest(
          events: events.sendPort,
          operation: job.operation,
          sourcePaths: sourcePaths,
          sourceArchivePath: sourceArchivePath,
          stagePath: stage.path,
          ownershipKey: ownershipKey,
          limits: _limits,
          cancellationAddress: cancellationSignal.address,
        ),
        onExit: exits.sendPort,
        onError: errors.sendPort,
        errorsAreFatal: true,
        debugName: 'archive-${job.id}',
      );

      // Terminal messages carry an acknowledgement port. The worker cannot
      // exit normally until this listener records and acknowledges its result.
      await exitCompleter.future;
      _throwIfCancelled(job);
      if (workerFailure case final LocalArchiveException failure) {
        throw failure;
      }
      final completed = workerCompleted;
      if (completed == null) {
        Error.throwWithStackTrace(
          LocalArchiveException(
            LocalArchiveErrorKind.io,
            'Archive worker exited without a result${isolateError == null ? '' : ': $isolateError'}',
          ),
          isolateStack ?? StackTrace.current,
        );
      }

      final committed = await _serializeCommit(
        destination.parent,
        job,
        () async {
          _throwIfCancelled(job);
          job._beginCommit();
          job._emit(
            LocalArchiveProgress(
              operation: job.operation,
              phase: LocalArchivePhase.committing,
              completedEntries: completed.entries,
              totalEntries: completed.entries,
              processedBytes: completed.uncompressedBytes,
              totalBytes: completed.uncompressedBytes,
            ),
          );
          return _commitStage(stage!, destination, operation: job.operation);
        },
      );
      stage = null;
      result = LocalArchiveResult(
        operation: job.operation,
        requestedDestinationPath: destinationPath,
        destinationPath: committed,
        entries: completed.entries,
        uncompressedBytes: completed.uncompressedBytes,
      );
    } on LocalArchiveException catch (error, stack) {
      terminalError = error;
      terminalStack = stack;
    } on FormatException catch (error, stack) {
      terminalError = LocalArchiveException(
        LocalArchiveErrorKind.unsafeEntry,
        error.message,
        path: error.source is String ? error.source as String : null,
      );
      terminalStack = stack;
    } on FileSystemException catch (error, stack) {
      terminalError = LocalArchiveException(
        LocalArchiveErrorKind.io,
        error.message,
        path: error.path,
      );
      terminalStack = stack;
    } catch (error, stack) {
      terminalError = LocalArchiveException(LocalArchiveErrorKind.io, '$error');
      terminalStack = stack;
    } finally {
      job._detachWorker();
      await eventSubscription?.cancel();
      await exitSubscription?.cancel();
      await errorSubscription?.cancel();
      events?.close();
      exits?.close();
      errors?.close();
      if (cancellationSignal != null) calloc.free(cancellationSignal);
      if (stage != null) {
        try {
          await _deleteOwnedStage(stage);
        } on FileSystemException catch (error, stack) {
          result = null;
          terminalError = LocalArchiveException(
            LocalArchiveErrorKind.io,
            'Could not clean the archive stage: ${error.message}',
            path: error.path ?? stage.path,
          );
          terminalStack = stack;
        }
      }
      job._closeProgress();
    }

    if (terminalError != null) {
      job._completeError(terminalError, terminalStack ?? StackTrace.current);
      _jobs.remove(job);
      return;
    }
    job._complete(result!);
    _jobs.remove(job);
  }

  Future<File> _prepareDestination(String destinationPath) async {
    if (destinationPath.isEmpty) {
      throw const LocalArchiveException(
        LocalArchiveErrorKind.conflict,
        'Archive destination is empty.',
      );
    }
    final absolute = File(p.absolute(destinationPath));
    try {
      validateLocalName(p.basename(absolute.path));
    } on FormatException catch (error) {
      throw LocalArchiveException(
        LocalArchiveErrorKind.conflict,
        error.message,
        path: absolute.path,
      );
    }
    if (_archiveStagePattern.hasMatch(p.basename(absolute.path))) {
      throw LocalArchiveException(
        LocalArchiveErrorKind.conflict,
        'Archive destination uses a reserved internal name.',
        path: absolute.path,
      );
    }
    final parent = Directory(p.dirname(absolute.path));
    final parentType = await FileSystemEntity.type(
      parent.path,
      followLinks: true,
    );
    if (parentType != FileSystemEntityType.directory) {
      throw LocalArchiveException(
        LocalArchiveErrorKind.conflict,
        'Archive destination parent is not a directory.',
        path: parent.path,
      );
    }
    final canonicalParent = await parent.resolveSymbolicLinks();
    return File(p.join(canonicalParent, p.basename(absolute.path)));
  }

  Future<_ArchiveStage> _createStage(
    Directory parent,
    Uint8List ownershipKey,
  ) async {
    final resolvedParent = Directory(await parent.resolveSymbolicLinks());
    while (true) {
      final name = '$_archiveStagePrefix${_newArchiveId()}$_archiveStageSuffix';
      final candidate = Directory(p.join(resolvedParent.path, name));
      if (await FileSystemEntity.type(candidate.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      try {
        await candidate.create();
      } on FileSystemException {
        if (await candidate.exists()) continue;
        rethrow;
      }
      _activeArchiveStages.add(candidate.path);
      _ArchiveStage? stage;
      try {
        await _restrictAndVerifyArchivePath(
          candidate.path,
          mode: _ownerDirectoryMode,
          modeBits: _ownerDirectoryModeBits,
          type: FileSystemEntityType.directory,
        );
        final lease = await File(
          p.join(candidate.path, _archiveStageLeaseName),
        ).open(mode: FileMode.append);
        try {
          await lease.lock(FileLock.exclusive);
        } on Object {
          await lease.close();
          rethrow;
        }
        stage = _ArchiveStage(candidate, lease);
        await File(
          p.join(candidate.path, _archiveStageMarkerName),
        ).writeAsString(
          _archiveStageMarker(candidate.path, ownershipKey),
          flush: true,
        );
        return stage;
      } on Object {
        _activeArchiveStages.remove(candidate.path);
        try {
          await stage?.release();
          await candidate.delete(recursive: true);
        } on FileSystemException {
          // Preserve the marker-write failure that made the stage unusable.
        }
        rethrow;
      }
    }
  }

  Future<void> _sweepOldStages(Directory parent, _LocalArchiveJob job) async {
    if (!await parent.exists()) return;
    final ownershipKey = await _archiveOwnershipKey();

    await for (final entity in parent.list(followLinks: false)) {
      _throwIfCancelled(job);
      if (!_archiveStagePattern.hasMatch(p.basename(entity.path))) continue;
      if (_activeArchiveStages.contains(entity.path)) continue;
      if (entity is! Directory) continue;

      try {
        final marker = File(p.join(entity.path, _archiveStageMarkerName));
        if (await FileSystemEntity.type(marker.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        if (!await _hasArchiveStageMarker(
          marker,
          _archiveStageMarker(entity.path, ownershipKey),
        )) {
          continue;
        }
        final lease = await File(
          p.join(entity.path, _archiveStageLeaseName),
        ).open(mode: FileMode.append);
        try {
          await lease.lock(FileLock.exclusive);
          await lease.unlock();
        } on FileSystemException {
          await lease.close();
          continue;
        }
        await lease.close();
        await entity.delete(recursive: true);
      } on FileSystemException {
        // A startup sweep is best-effort; a live owner or permissions may win.
      }
    }
  }

  Future<String> _commitStage(
    _ArchiveStage stage,
    File requested, {
    required LocalArchiveOperation operation,
  }) async {
    final isDirectory = operation == LocalArchiveOperation.extractZip;
    final source = isDirectory
        ? Directory(p.join(stage.path, _workerPayloadDirectory))
        : File(p.join(stage.path, _workerPayloadArchive));
    final sourceType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    final expectedType = isDirectory
        ? FileSystemEntityType.directory
        : FileSystemEntityType.file;
    if (sourceType != expectedType) {
      throw LocalArchiveException(
        LocalArchiveErrorKind.io,
        'Archive worker did not produce its staged payload.',
        path: source.path,
      );
    }

    var candidate = requested.path;
    var attempt = 2;
    while (true) {
      while (await FileSystemEntity.type(candidate, followLinks: false) !=
          FileSystemEntityType.notFound) {
        final candidateName = numberedConflictName(
          p.basename(requested.path),
          attempt,
          isDirectory: isDirectory,
        );
        validateLocalName(candidateName);
        candidate = p.join(p.dirname(requested.path), candidateName);
        attempt++;
      }
      if (_renameArchivePayloadNoReplace(source.path, candidate)) break;
    }
    _activeArchiveStages.remove(stage.path);
    try {
      await stage.release();
      await _deleteStage(stage.directory);
    } on FileSystemException {
      // The payload is committed. Its owned stage is swept next start.
    }
    return candidate;
  }

  Future<T> _serializeCommit<T>(
    Directory parent,
    _LocalArchiveJob job,
    Future<T> Function() commit,
  ) async {
    final previous = _archiveCommitTail;
    final release = Completer<void>();
    _archiveCommitTail = release.future;
    var reachedPredecessor = false;
    try {
      var previousCompleted = false;
      unawaited(previous.then<void>((_) => previousCompleted = true));
      while (!previousCompleted) {
        _throwIfCancelled(job);
        await Future.any<void>([
          previous,
          Future<void>.delayed(_archiveCommitLockRetryDelay),
        ]);
      }
      reachedPredecessor = true;
      return await _withParentCommitLock(parent, job, commit);
    } finally {
      if (reachedPredecessor) {
        release.complete();
      } else {
        unawaited(previous.then<void>((_) => release.complete()));
      }
    }
  }

  Future<T> _withParentCommitLock<T>(
    Directory parent,
    _LocalArchiveJob job,
    Future<T> Function() commit,
  ) async {
    final lockDirectory = await _archiveCommitLockDirectory();
    final lockKey = sha256.convert(utf8.encode(parent.path)).toString();
    final lockPath = p.join(
      lockDirectory.path,
      '$lockKey$_archiveCommitLockSuffix',
    );
    final type = await FileSystemEntity.type(lockPath, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw LocalArchiveException(
        LocalArchiveErrorKind.conflict,
        'Archive commit lock is not a regular file.',
        path: lockPath,
      );
    }

    final lock = await File(lockPath).open(mode: FileMode.append);
    var locked = false;
    try {
      await _restrictAndVerifyArchivePath(
        lockPath,
        mode: _ownerFileMode,
        modeBits: _ownerFileModeBits,
        type: FileSystemEntityType.file,
      );
      final deadline = DateTime.now().add(_archiveCommitLockTimeout);
      while (!locked) {
        _throwIfCancelled(job);
        try {
          await lock.lock(FileLock.exclusive);
          locked = true;
        } on FileSystemException {
          if (DateTime.now().isAfter(deadline)) rethrow;
          await Future<void>.delayed(_archiveCommitLockRetryDelay);
        }
      }
      return await commit();
    } finally {
      try {
        if (locked) await lock.unlock();
      } finally {
        await lock.close();
      }
    }
  }

  Future<void> _deleteOwnedStage(_ArchiveStage stage) async {
    _activeArchiveStages.remove(stage.path);
    await stage.release();
    await _deleteStage(stage.directory);
  }

  Future<void> _deleteStage(Directory stage) async {
    if (await stage.exists()) await stage.delete(recursive: true);
  }

  Future<void> _restrictAndVerifyArchivePath(
    String path, {
    required String mode,
    required int modeBits,
    required FileSystemEntityType type,
  }) async {
    if (await FileSystemEntity.type(path, followLinks: false) != type) {
      throw FileSystemException(
        'Archive private path has an unsafe filesystem type.',
        path,
      );
    }
    await restrictLocalPathPermissions(path, mode);
    if (!Platform.isLinux && !Platform.isMacOS) return;

    final stat = await FileStat.stat(path);
    if (stat.type == type && (stat.mode & 0x1ff) == modeBits) return;
    throw FileSystemException(
      'Archive private-path permissions could not be verified.',
      path,
    );
  }

  Future<Directory> _archiveCommitLockDirectory() async {
    final support = await _archiveSupportDirectory();
    final locks = Directory(
      p.join(support.path, _archiveCommitLockDirectoryName),
    );
    await _ensurePrivateArchiveDirectory(locks);
    return locks;
  }

  Future<Directory> _archiveStateDirectory() async {
    final configured = _supportDirectoryPath;
    if (configured != null && configured.isNotEmpty) {
      final base = Directory(p.absolute(configured));
      await base.create(recursive: true);
      final resolved = Directory(await base.resolveSymbolicLinks());
      final state = Directory(
        p.join(resolved.path, _archiveStateDirectoryName),
      );
      await _ensurePrivateArchiveDirectory(state);
      return state;
    }

    final environment = Platform.environment;
    String? stateRoot;
    if (Platform.isWindows) {
      stateRoot = environment['LOCALAPPDATA'] ?? environment['APPDATA'];
    } else if (Platform.isMacOS) {
      final home = environment['HOME'];
      if (home != null && home.isNotEmpty) {
        stateRoot = p.join(home, 'Library', 'Application Support');
      }
    } else {
      stateRoot = environment['XDG_STATE_HOME'];
      if (stateRoot == null || stateRoot.isEmpty) {
        final home = environment['HOME'];
        if (home != null && home.isNotEmpty) {
          stateRoot = p.join(home, '.local', 'state');
        }
      }
    }
    var stateName = _archiveSupportDirectoryName;
    if (stateRoot == null || stateRoot.isEmpty) {
      stateRoot = await Directory.systemTemp.resolveSymbolicLinks();
      stateName = '$_archiveSupportDirectoryName-${await _localUserScope()}';
    }

    final base = Directory(stateRoot);
    await base.create(recursive: true);
    final resolvedBase = Directory(await base.resolveSymbolicLinks());
    final state = Directory(
      p.join(resolvedBase.path, stateName, _archiveStateDirectoryName),
    );
    await state.parent.create(recursive: true);
    await _ensurePrivateArchiveDirectory(state);
    return state;
  }

  Future<Directory> _archiveSupportDirectory() async {
    final environment = Platform.environment;
    String? supportRoot;
    var supportName = _archiveSupportDirectoryName;
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
      supportName = '$_archiveSupportDirectoryName-${await _localUserScope()}';
    }

    final base = Directory(supportRoot);
    await base.create(recursive: true);
    final resolvedBase = Directory(await base.resolveSymbolicLinks());
    final support = Directory(p.join(resolvedBase.path, supportName));
    await _ensurePrivateArchiveDirectory(support);
    return support;
  }

  Future<Uint8List> _archiveOwnershipKey() =>
      _ownershipKey ??= _loadArchiveOwnershipKey();

  Future<Uint8List> _loadArchiveOwnershipKey() async {
    final state = await _archiveStateDirectory();
    final keyPath = p.join(state.path, _archiveOwnershipKeyName);
    final type = await FileSystemEntity.type(keyPath, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Archive ownership key has an unsafe filesystem type.',
        keyPath,
      );
    }

    final file = await File(keyPath).open(mode: FileMode.append);
    var locked = false;
    try {
      await _restrictAndVerifyArchivePath(
        keyPath,
        mode: _ownerFileMode,
        modeBits: _ownerFileModeBits,
        type: FileSystemEntityType.file,
      );
      await file.lock(FileLock.blockingExclusive);
      locked = true;
      final length = await file.length();
      if (length == 0) {
        final key = Uint8List.fromList(
          List<int>.generate(
            _archiveOwnershipKeyBytes,
            (_) => _archiveRandom.nextInt(256),
          ),
        );
        await file.writeFrom(key);
        await file.flush();
      } else if (length != _archiveOwnershipKeyBytes) {
        throw FileSystemException(
          'Archive ownership key has an invalid length.',
          keyPath,
        );
      }
      await file.setPosition(0);
      final key = await file.read(_archiveOwnershipKeyBytes);
      if (key.length != _archiveOwnershipKeyBytes) {
        throw FileSystemException(
          'Archive ownership key could not be read.',
          keyPath,
        );
      }
      return key;
    } finally {
      try {
        if (locked) await file.unlock();
      } finally {
        await file.close();
      }
    }
  }

  Future<void> _ensurePrivateArchiveDirectory(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      final temporary = await directory.parent.createTemp(
        '.poltergeist-private-',
      );
      try {
        await _restrictAndVerifyArchivePath(
          temporary.path,
          mode: _ownerDirectoryMode,
          modeBits: _ownerDirectoryModeBits,
          type: FileSystemEntityType.directory,
        );
        try {
          await temporary.rename(directory.path);
        } on FileSystemException {
          if (await FileSystemEntity.type(directory.path, followLinks: false) !=
              FileSystemEntityType.directory) {
            rethrow;
          }
        }
      } finally {
        if (await temporary.exists()) {
          await temporary.delete(recursive: true);
        }
      }
    }
    await _restrictAndVerifyArchivePath(
      directory.path,
      mode: _ownerDirectoryMode,
      modeBits: _ownerDirectoryModeBits,
      type: FileSystemEntityType.directory,
    );
  }

  Future<String> _localUserScope() async {
    if (Platform.isLinux || Platform.isMacOS) {
      for (final executable in const ['/usr/bin/id', '/bin/id']) {
        if (!await File(executable).exists()) continue;
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
}

final class _ArchiveStage {
  _ArchiveStage(this.directory, this._lease);

  final Directory directory;
  RandomAccessFile? _lease;

  String get path => directory.path;

  Future<void> release() async {
    final lease = _lease;
    if (lease == null) return;
    _lease = null;

    try {
      await lease.unlock();
    } finally {
      await lease.close();
    }
  }
}

final class _LocalArchiveJob implements LocalArchiveJob {
  _LocalArchiveJob({required this.id, required this.operation});

  @override
  final String id;

  @override
  final LocalArchiveOperation operation;

  final StreamController<LocalArchiveProgress> _progress =
      StreamController<LocalArchiveProgress>.broadcast(sync: true);
  final Completer<LocalArchiveResult> _done = Completer<LocalArchiveResult>();
  SendPort? _commands;
  Pointer<Uint8>? _cancellationSignal;
  bool _paused = false;
  bool _cancelled = false;
  bool _commitStarted = false;
  bool _waitingAtBoundary = false;

  @override
  Stream<LocalArchiveProgress> get progress => _progress.stream;

  @override
  Future<LocalArchiveResult> get done => _done.future;

  @override
  bool get isPaused => _paused;

  @override
  bool get isCancelled => _cancelled;

  @override
  void pause() {
    if (_done.isCompleted || _cancelled || _commitStarted) return;
    _paused = true;
  }

  @override
  void resume() {
    if (_done.isCompleted || _cancelled || _commitStarted || !_paused) return;
    _paused = false;
    if (_waitingAtBoundary) {
      _waitingAtBoundary = false;
      _commands?.send(_workerProceed);
    }
  }

  @override
  void cancel() {
    if (_done.isCompleted || _cancelled || _commitStarted) return;
    _cancelled = true;
    _cancellationSignal?.value = 1;
    _commands?.send(_workerCancel);
  }

  void _attachCancellationSignal(Pointer<Uint8> signal) {
    _cancellationSignal = signal;
    if (_cancelled) signal.value = 1;
  }

  void _attachWorker(SendPort commands) {
    _commands = commands;
    if (_cancelled) {
      commands.send(_workerCancel);
      return;
    }
    if (_paused) {
      _waitingAtBoundary = true;
      return;
    }
    commands.send(_workerProceed);
  }

  void _continueWorkerAtBoundary() {
    if (_cancelled) {
      _commands?.send(_workerCancel);
      return;
    }
    if (!_paused) {
      _commands?.send(_workerProceed);
      return;
    }
    _waitingAtBoundary = true;
  }

  void _beginCommit() {
    _commitStarted = true;
    _paused = false;
  }

  void _detachWorker() {
    _commands = null;
    _cancellationSignal = null;
    _waitingAtBoundary = false;
  }

  void _emit(LocalArchiveProgress value) {
    if (!_progress.isClosed) _progress.add(value);
  }

  void _complete(LocalArchiveResult result) {
    if (!_done.isCompleted) _done.complete(result);
  }

  void _completeError(Object error, StackTrace stack) {
    if (!_done.isCompleted) _done.completeError(error, stack);
  }

  void _closeProgress() {
    unawaited(_progress.close());
  }
}

void _throwIfCancelled(_LocalArchiveJob job) {
  if (!job.isCancelled) return;
  throw const LocalArchiveException(
    LocalArchiveErrorKind.cancelled,
    'Archive operation was cancelled.',
  );
}

String _newArchiveId() => List<String>.generate(
  _archiveStageIdBytes,
  (_) => _archiveRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

String _archiveStageMarker(String stagePath, List<int> ownershipKey) {
  final digest = Hmac(sha256, ownershipKey).convert(utf8.encode(stagePath));
  return '$_archiveStageMarkerPrefix$digest\n';
}

Future<bool> _hasArchiveStageMarker(File marker, String expected) async {
  final expectedBytes = utf8.encode(expected);
  final file = await marker.open();
  try {
    if (await file.length() != expectedBytes.length) return false;
    final actual = await file.read(expectedBytes.length);
    if (actual.length != expectedBytes.length) return false;
    if (await file.length() != expectedBytes.length) return false;

    var difference = 0;
    for (var index = 0; index < expectedBytes.length; index++) {
      difference |= actual[index] ^ expectedBytes[index];
    }
    return difference == 0;
  } finally {
    await file.close();
  }
}

String _escapeArchiveDisplay(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x5c) {
      buffer.write(r'\\');
      continue;
    }
    if (rune == 0x0a) {
      buffer.write(r'\n');
      continue;
    }
    if (rune == 0x0d) {
      buffer.write(r'\r');
      continue;
    }
    if (rune == 0x09) {
      buffer.write(r'\t');
      continue;
    }
    final isControl = rune < 0x20 || (rune >= 0x7f && rune <= 0x9f);
    final isBidi =
        rune == 0x061c ||
        rune == 0x200e ||
        rune == 0x200f ||
        rune == 0x2028 ||
        rune == 0x2029 ||
        (rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2066 && rune <= 0x2069);
    if (isControl || isBidi) {
      buffer.write('\\u{${rune.toRadixString(16).padLeft(4, '0')}}');
      continue;
    }
    buffer.writeCharCode(rune);
  }
  return buffer.toString();
}
