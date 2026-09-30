part of 'local_archive_service.dart';

const int _workerProceed = 1;
const int _workerTerminalAcknowledged = 2;
const int _workerCancel = 3;
const String _workerPayloadArchive = 'payload.zip';
const String _workerPayloadDirectory = 'payload';
const int _zipEncryptionFlag = 0x0001;
const int _zipStrongEncryptionFlag = 0x0040;
const int _zipCentralDirectoryEncryptionFlag = 0x2000;
const int _zipStoredMethod = 0;
const int _zipDeflateMethod = 8;
const int _zipDataDescriptorFlag = 0x0008;
const int _zipDataDescriptorSignature = 0x08074b50;
const int _maximumZip32Value = 0xffffffff;
const int _unixFileTypeMask = 0xf000;
const int _unixRegularFileType = 0x8000;
const int _unixDirectoryType = 0x4000;
const int _unixSymbolicLinkType = 0xa000;
const int _progressByteInterval = 1024 * 1024;
const int _zipLocalHeaderBytes = 30;
const int _zipCentralHeaderBytes = 46;
const int _zip64LocalExtraBytes = 20;
const int _zip64CentralExtraBytes = 28;
const int _zipEndRecordBytes = 22;
const int _zip64EndRecordBytes = 76;

Pointer<Uint8> _workerCancellationSignal = nullptr;

final class _WorkerRequest {
  const _WorkerRequest({
    required this.events,
    required this.operation,
    required this.sourcePaths,
    required this.sourceArchivePath,
    required this.stagePath,
    required this.ownershipKey,
    required this.limits,
    required this.cancellationAddress,
  });

  final SendPort events;
  final LocalArchiveOperation operation;
  final List<String> sourcePaths;
  final String? sourceArchivePath;
  final String stagePath;
  final Uint8List ownershipKey;
  final LocalArchiveLimits limits;
  final int cancellationAddress;
}

final class _WorkerReady {
  const _WorkerReady(this.commands);

  final SendPort commands;
}

final class _WorkerProgressEvent {
  const _WorkerProgressEvent(this.progress);

  final LocalArchiveProgress progress;
}

final class _WorkerBoundary {
  const _WorkerBoundary();
}

final class _WorkerStageProbe {
  const _WorkerStageProbe(this.path, this.reply);

  final String path;
  final SendPort reply;
}

final class _WorkerCompleted {
  const _WorkerCompleted({
    required this.entries,
    required this.uncompressedBytes,
    required this.acknowledgement,
  });

  final int entries;
  final int uncompressedBytes;
  final SendPort acknowledgement;
}

final class _WorkerFailed {
  const _WorkerFailed({
    required this.kind,
    required this.message,
    required this.acknowledgement,
    this.path,
  });

  final LocalArchiveErrorKind kind;
  final String message;
  final String? path;
  final SendPort acknowledgement;
}

final class _WorkerAbort implements Exception {
  const _WorkerAbort(this.kind, this.message, {this.path});

  final LocalArchiveErrorKind kind;
  final String message;
  final String? path;
}

void _throwIfWorkerCancelled() {
  if (_workerCancellationSignal == nullptr ||
      _workerCancellationSignal.value == 0) {
    return;
  }
  throw const _WorkerAbort(
    LocalArchiveErrorKind.cancelled,
    'Archive operation was cancelled.',
  );
}

Future<void> _runArchiveWorker(_WorkerRequest request) async {
  _workerCancellationSignal = Pointer<Uint8>.fromAddress(
    request.cancellationAddress,
  );
  final commands = ReceivePort();
  final commandIterator = StreamIterator<Object?>(commands);
  request.events.send(_WorkerReady(commands.sendPort));

  try {
    await _waitForWorkerCommand(commandIterator, _workerProceed);
    final result = switch (request.operation) {
      LocalArchiveOperation.createZip => await _createZipInWorker(
        request,
        commandIterator,
      ),
      LocalArchiveOperation.extractZip => await _extractZipInWorker(
        request,
        commandIterator,
      ),
    };
    final acknowledgement = ReceivePort();
    request.events.send(
      _WorkerCompleted(
        entries: result.$1,
        uncompressedBytes: result.$2,
        acknowledgement: acknowledgement.sendPort,
      ),
    );
    await _waitForTerminalAcknowledgement(acknowledgement);
  } on _WorkerAbort catch (error) {
    await _sendWorkerFailure(
      request.events,
      error.kind,
      error.message,
      path: error.path,
    );
  } on FileSystemException catch (error) {
    await _sendWorkerFailure(
      request.events,
      LocalArchiveErrorKind.io,
      error.message,
      path: error.path,
    );
  } on ArchiveException catch (error) {
    await _sendWorkerFailure(
      request.events,
      LocalArchiveErrorKind.invalidArchive,
      '$error',
      path: request.sourceArchivePath,
    );
  } on FormatException catch (error) {
    await _sendWorkerFailure(
      request.events,
      LocalArchiveErrorKind.unsafeEntry,
      error.message,
      path: error.source is String ? error.source as String : null,
    );
  } catch (error) {
    await _sendWorkerFailure(
      request.events,
      LocalArchiveErrorKind.io,
      '$error',
    );
  } finally {
    await commandIterator.cancel();
    commands.close();
  }
}

Future<void> _sendWorkerFailure(
  SendPort events,
  LocalArchiveErrorKind kind,
  String message, {
  String? path,
}) async {
  final acknowledgement = ReceivePort();
  events.send(
    _WorkerFailed(
      kind: kind,
      message: message,
      path: path,
      acknowledgement: acknowledgement.sendPort,
    ),
  );
  await _waitForTerminalAcknowledgement(acknowledgement);
}

Future<void> _waitForTerminalAcknowledgement(ReceivePort port) async {
  try {
    await for (final message in port) {
      if (message == _workerTerminalAcknowledged) return;
    }
  } finally {
    port.close();
  }
}

Future<void> _waitForWorkerCommand(
  StreamIterator<Object?> commands,
  int expected,
) async {
  _throwIfWorkerCancelled();
  while (await commands.moveNext()) {
    _throwIfWorkerCancelled();
    if (commands.current == _workerCancel) break;
    if (commands.current == expected) return;
  }
  throw const _WorkerAbort(
    LocalArchiveErrorKind.cancelled,
    'Archive operation was cancelled.',
  );
}

Future<(int, int)> _createZipInWorker(
  _WorkerRequest request,
  StreamIterator<Object?> commands,
) async {
  _throwIfWorkerCancelled();
  if (request.sourcePaths.isEmpty) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.conflict,
      'Select at least one file or folder to archive.',
    );
  }

  final entries = await _scanCreationEntries(request);
  final totalBytes = entries.fold<int>(0, (sum, entry) => sum + entry.size);
  request.events.send(
    _WorkerProgressEvent(
      LocalArchiveProgress(
        operation: request.operation,
        phase: LocalArchivePhase.preparing,
        completedEntries: 0,
        totalEntries: entries.length,
        processedBytes: 0,
        totalBytes: totalBytes,
      ),
    ),
  );
  request.events.send(const _WorkerBoundary());
  await _waitForWorkerCommand(commands, _workerProceed);

  final outputPath = p.join(request.stagePath, _workerPayloadArchive);
  final output = _BoundedArchiveOutput(
    outputPath,
    request.limits.maximumArchiveFileBytes,
  );
  final encoder = ZipEncoder();
  var processedBytes = 0;
  var completedEntries = 0;
  final compressedBudget = _CompressedCreationBudget(request.limits);

  try {
    encoder.startEncode(output, level: DeflateLevel.defaultCompression);
    for (var index = 0; index < entries.length; index++) {
      _throwIfWorkerCancelled();
      final entry = entries[index];
      if (entry.isDirectory) {
        final archiveEntry = ArchiveFile.directory(entry.archivePath)
          ..lastModTime = entry.modified.millisecondsSinceEpoch ~/ 1000
          ..mode = entry.mode;
        encoder.add(archiveEntry);
      } else {
        final scratchPath = p.join(request.stagePath, 'scratch-$index.deflate');
        final initial = _verifyCreationFile(entry);
        if (initial.size != entry.size || initial.modified != entry.modified) {
          throw _WorkerAbort(
            LocalArchiveErrorKind.conflict,
            'A source file changed while it was being archived.',
            path: entry.sourcePath,
          );
        }
        var entryProcessedBytes = 0;
        final input = _ProgressInputFileStream(entry, (count) {
          processedBytes += count;
          entryProcessedBytes += count;
          if (entryProcessedBytes > request.limits.maximumEntryBytes ||
              processedBytes > request.limits.maximumTotalBytes) {
            throw _WorkerAbort(
              LocalArchiveErrorKind.limitExceeded,
              'A growing source exceeded an archive byte limit.',
              path: entry.sourcePath,
            );
          }
          if (entryProcessedBytes > entry.size || processedBytes > totalBytes) {
            throw _WorkerAbort(
              LocalArchiveErrorKind.conflict,
              'A source file grew while it was being archived.',
              path: entry.sourcePath,
            );
          }
          if (processedBytes % _progressByteInterval < count) {
            _sendCreationProgress(
              request,
              entry,
              completedEntries,
              entries.length,
              processedBytes,
              totalBytes,
              entryProcessedBytes,
            );
          }
        });
        late final Deflate deflate;
        try {
          final scratch = _BoundedCompressedOutput(
            scratchPath,
            entry.sourcePath,
            compressedBudget,
          );
          try {
            deflate = Deflate.stream(
              input,
              level: DeflateLevel.defaultCompression,
              output: scratch,
            );
            scratch.flush();
          } finally {
            scratch.closeSync();
          }
        } finally {
          input.closeSync();
        }

        final finalStat = _verifyCreationFile(entry);
        if (initial.size != entry.size ||
            initial.modified != entry.modified ||
            finalStat.size != entry.size ||
            finalStat.modified != entry.modified ||
            entryProcessedBytes != entry.size ||
            initial.modified != finalStat.modified ||
            processedBytes > totalBytes) {
          throw _WorkerAbort(
            LocalArchiveErrorKind.conflict,
            'A source file changed while it was being archived.',
            path: entry.sourcePath,
          );
        }

        final content = _CompressedFileContent(scratchPath);
        final archiveEntry =
            ArchiveFile.file(entry.archivePath, entry.size, content)
              ..compression = CompressionType.deflate
              ..crc32 = deflate.crc32
              ..lastModTime = entry.modified.millisecondsSinceEpoch ~/ 1000
              ..mode = entry.mode;
        try {
          encoder.add(archiveEntry);
        } finally {
          archiveEntry.closeSync();
          File(scratchPath).deleteSync();
        }
      }

      completedEntries++;
      _sendCreationProgress(
        request,
        entry,
        completedEntries,
        entries.length,
        processedBytes,
        totalBytes,
        entry.size,
      );
      if (index + 1 < entries.length) {
        request.events.send(const _WorkerBoundary());
        await _waitForWorkerCommand(commands, _workerProceed);
      }
    }
    encoder.endEncode();
    output.flush();
  } finally {
    output.closeSync();
  }
  if (File(outputPath).lengthSync() > request.limits.maximumArchiveFileBytes) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.limitExceeded,
      'Created ZIP archive exceeds the file-size limit.',
    );
  }

  return (entries.length, totalBytes);
}

void _sendCreationProgress(
  _WorkerRequest request,
  _CreationEntry entry,
  int completedEntries,
  int totalEntries,
  int processedBytes,
  int totalBytes,
  int entryProcessedBytes,
) {
  request.events.send(
    _WorkerProgressEvent(
      LocalArchiveProgress(
        operation: request.operation,
        phase: LocalArchivePhase.compressing,
        entryName: entry.archivePath,
        entryIsDirectory: entry.isDirectory,
        entryProcessedBytes: entryProcessedBytes,
        entryTotalBytes: entry.size,
        completedEntries: completedEntries,
        totalEntries: totalEntries,
        processedBytes: processedBytes,
        totalBytes: totalBytes,
      ),
    ),
  );
}

Future<List<_CreationEntry>> _scanCreationEntries(
  _WorkerRequest request,
) async {
  final entries = <_CreationEntry>[];
  final paths = _ArchivePathRegistry();
  final ownStagePath = p.normalize(p.absolute(request.stagePath));
  var totalBytes = 0;
  var pathComponents = 0;
  var metadataBytes = _zipEndRecordBytes + _zip64EndRecordBytes;

  void add(String sourcePath, String archivePath, FileSystemEntityType type) {
    _throwIfWorkerCancelled();
    final isDirectory = type == FileSystemEntityType.directory;
    final components = _validatedWorkerPath(
      archivePath,
      request.limits.maximumDepth,
    );
    pathComponents += components.length;
    if (pathComponents > request.limits.maximumPathComponents) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'Selected paths exceed the archive component limit.',
      );
    }
    paths.add(
      components,
      kind: isDirectory ? _ArchivePathKind.directory : _ArchivePathKind.file,
      displayPath: archivePath,
    );
    final encodedPath = isDirectory ? '$archivePath/' : archivePath;
    final nameBytes = utf8.encode(encodedPath).length;
    metadataBytes +=
        _zipLocalHeaderBytes +
        _zipCentralHeaderBytes +
        _zip64LocalExtraBytes +
        _zip64CentralExtraBytes +
        (nameBytes * 2);
    if (metadataBytes > request.limits.maximumMetadataBytes) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'Selected paths exceed the archive metadata limit.',
      );
    }

    final stat = FileStat.statSync(sourcePath);
    final finalType = FileSystemEntity.typeSync(sourcePath, followLinks: false);
    if (stat.type != type || finalType != type) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.conflict,
        'A source changed type while the archive was being prepared.',
        path: sourcePath,
      );
    }
    final size = isDirectory ? 0 : stat.size;
    if (size > request.limits.maximumEntryBytes) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'A source exceeds the per-entry archive limit.',
        path: sourcePath,
      );
    }
    totalBytes += size;
    if (totalBytes > request.limits.maximumTotalBytes) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'Selected sources exceed the total archive limit.',
      );
    }
    if (entries.length >= request.limits.maximumEntries) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'Selected sources exceed the archive entry limit.',
      );
    }

    final identity = isDirectory
        ? null
        : _inspectCreationFile(sourcePath, stat);

    entries.add(
      _CreationEntry(
        sourcePath: sourcePath,
        archivePath: archivePath,
        isDirectory: isDirectory,
        size: size,
        modified: stat.modified,
        mode: stat.mode,
        identity: identity,
      ),
    );
  }

  Future<void> walk(String sourcePath, String archivePath) async {
    _throwIfWorkerCancelled();
    final absolute = p.normalize(p.absolute(sourcePath));
    if (p.equals(absolute, ownStagePath)) return;
    final type = FileSystemEntity.typeSync(absolute, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      final reason = type == FileSystemEntityType.link
          ? 'Symbolic links cannot be added to local ZIP archives.'
          : 'Only regular files and folders can be added to ZIP archives.';
      throw _WorkerAbort(
        LocalArchiveErrorKind.unsupported,
        reason,
        path: absolute,
      );
    }

    if (type == FileSystemEntityType.directory &&
        await _isLiveOwnedArchiveStage(request, absolute)) {
      return;
    }

    add(absolute, archivePath, type);
    if (type != FileSystemEntityType.directory) return;

    await for (final child in Directory(absolute).list(followLinks: false)) {
      _throwIfWorkerCancelled();
      await walk(child.path, '$archivePath/${p.basename(child.path)}');
    }
  }

  for (final source in request.sourcePaths) {
    _throwIfWorkerCancelled();
    if (source.isEmpty) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.unsafeEntry,
        'An archive source path is empty.',
      );
    }
    final absolute = p.normalize(p.absolute(source));
    final basename = p.basename(absolute);
    if (basename.isEmpty || basename == p.separator) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.unsafeEntry,
        'A filesystem root cannot be archived as one entry.',
        path: absolute,
      );
    }
    await walk(absolute, basename);
  }
  return entries;
}

Future<bool> _isLiveOwnedArchiveStage(
  _WorkerRequest request,
  String path,
) async {
  if (!_archiveStagePattern.hasMatch(p.basename(path))) return false;
  final markerPath = p.join(path, _archiveStageMarkerName);
  if (!_workerHasStageMarker(
    markerPath,
    _archiveStageMarker(path, request.ownershipKey),
  )) {
    return false;
  }

  final reply = ReceivePort();
  request.events.send(_WorkerStageProbe(path, reply.sendPort));
  try {
    if (await reply.first == true) return true;
  } finally {
    reply.close();
  }

  final leasePath = p.join(path, _archiveStageLeaseName);
  if (FileSystemEntity.typeSync(leasePath, followLinks: false) !=
      FileSystemEntityType.file) {
    return false;
  }
  RandomAccessFile lease;
  try {
    lease = File(leasePath).openSync(mode: FileMode.append);
  } on FileSystemException {
    return false;
  }
  try {
    lease.lockSync(FileLock.exclusive);
  } on FileSystemException {
    lease.closeSync();
    return true;
  }
  try {
    lease.unlockSync();
  } finally {
    lease.closeSync();
  }
  return false;
}

bool _workerHasStageMarker(String path, String expected) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    return false;
  }
  final expectedBytes = utf8.encode(expected);
  RandomAccessFile? marker;
  try {
    marker = File(path).openSync();
    if (marker.lengthSync() != expectedBytes.length) return false;
    final actual = marker.readSync(expectedBytes.length);
    if (actual.length != expectedBytes.length) return false;
    if (marker.lengthSync() != expectedBytes.length) return false;

    var difference = 0;
    for (var index = 0; index < expectedBytes.length; index++) {
      difference |= actual[index] ^ expectedBytes[index];
    }
    return difference == 0;
  } on FileSystemException {
    return false;
  } finally {
    marker?.closeSync();
  }
}

FileStat _verifyCreationFile(_CreationEntry entry) {
  final type = FileSystemEntity.typeSync(entry.sourcePath, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.conflict,
      'A source file changed while it was being archived.',
      path: entry.sourcePath,
    );
  }
  final stat = FileStat.statSync(entry.sourcePath);
  if (FileSystemEntity.typeSync(entry.sourcePath, followLinks: false) !=
      FileSystemEntityType.file) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.conflict,
      'A source file changed while it was being archived.',
      path: entry.sourcePath,
    );
  }
  return stat;
}

final class _CreationEntry {
  const _CreationEntry({
    required this.sourcePath,
    required this.archivePath,
    required this.isDirectory,
    required this.size,
    required this.modified,
    required this.mode,
    required this.identity,
  });

  final String sourcePath;
  final String archivePath;
  final bool isDirectory;
  final int size;
  final DateTime modified;
  final int mode;
  final _CreationFileIdentity? identity;
}

Future<(int, int)> _extractZipInWorker(
  _WorkerRequest request,
  StreamIterator<Object?> commands,
) async {
  _throwIfWorkerCancelled();
  final requestedArchivePath = request.sourceArchivePath;
  if (requestedArchivePath == null || requestedArchivePath.isEmpty) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'Archive path is empty.',
    );
  }
  final archivePath = p.normalize(p.absolute(requestedArchivePath));
  if (FileSystemEntity.typeSync(archivePath, followLinks: false) !=
      FileSystemEntityType.file) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'Archive is not a regular file.',
      path: archivePath,
    );
  }

  final archiveStat = FileStat.statSync(archivePath);
  final archiveHandle = _openArchiveInput(archivePath, archiveStat);
  late final InputFileStream input;
  try {
    input = InputFileStream.withFileHandle(archiveHandle);
  } on Object {
    archiveHandle.closeSync();
    rethrow;
  }
  try {
    final ZipDirectory directory;
    final List<_ExtractionEntry> entries;
    try {
      final envelope = _preflightZipEnvelope(input, request.limits);
      _scanZipStructure(input, envelope, request.limits);
      input.setPosition(0);
      directory = ZipDirectory()..read(input);
      if (directory.filePosition != envelope.eocdOffset) {
        throw const _WorkerAbort(
          LocalArchiveErrorKind.invalidArchive,
          'ZIP end-of-directory records are ambiguous.',
        );
      }
      entries = _preflightZip(directory, input, request.limits);
    } on _WorkerAbort {
      rethrow;
    } on Object catch (error) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'Could not read the ZIP directory: $error',
        path: archivePath,
      );
    }

    final totalBytes = entries.fold<int>(0, (sum, entry) => sum + entry.size);
    request.events.send(
      _WorkerProgressEvent(
        LocalArchiveProgress(
          operation: request.operation,
          phase: LocalArchivePhase.preparing,
          completedEntries: 0,
          totalEntries: entries.length,
          processedBytes: 0,
          totalBytes: totalBytes,
        ),
      ),
    );
    request.events.send(const _WorkerBoundary());
    await _waitForWorkerCommand(commands, _workerProceed);

    final outputRoot = Directory(
      p.join(request.stagePath, _workerPayloadDirectory),
    );
    outputRoot.createSync();
    final budget = _ActualOutputBudget(request.limits.maximumTotalBytes);
    var processedBytes = 0;
    var completedEntries = 0;

    for (var index = 0; index < entries.length; index++) {
      _throwIfWorkerCancelled();
      final entry = entries[index];
      final outputPath = p.joinAll(<String>[
        outputRoot.path,
        ...entry.components,
      ]);
      if (entry.isDirectory) {
        await ensureSafeLocalDirectory(outputPath);
      } else {
        await ensureSafeLocalDirectory(p.dirname(outputPath));
        var entryProcessedBytes = 0;
        final output = _CheckedOutputStream(outputPath, entry.size, budget, (
          count,
        ) {
          processedBytes += count;
          entryProcessedBytes += count;
          if (processedBytes % _progressByteInterval < count) {
            _sendExtractionProgress(
              request,
              entry,
              completedEntries,
              entries.length,
              processedBytes,
              totalBytes,
              entryProcessedBytes,
            );
          }
        });
        try {
          entry.file.decompress(output);
          output.flush();
        } on _WorkerAbort {
          rethrow;
        } on FileSystemException {
          rethrow;
        } on Object {
          throw _WorkerAbort(
            LocalArchiveErrorKind.invalidArchive,
            'Could not decode a ZIP entry.',
            path: entry.name,
          );
        } finally {
          output.closeSync();
        }
        if (output.length != entry.size) {
          throw _WorkerAbort(
            LocalArchiveErrorKind.invalidArchive,
            'ZIP entry size does not match its directory record.',
            path: entry.name,
          );
        }
        if (output.crc32 != entry.crc32) {
          throw _WorkerAbort(
            LocalArchiveErrorKind.checksumMismatch,
            'ZIP entry checksum does not match its directory record.',
            path: entry.name,
          );
        }
      }

      completedEntries++;
      _sendExtractionProgress(
        request,
        entry,
        completedEntries,
        entries.length,
        processedBytes,
        totalBytes,
        entry.size,
      );
      if (index + 1 < entries.length) {
        request.events.send(const _WorkerBoundary());
        await _waitForWorkerCommand(commands, _workerProceed);
      }
    }

    return (entries.length, totalBytes);
  } finally {
    input.closeSync();
  }
}

_ZipEnvelope _preflightZipEnvelope(
  InputFileStream input,
  LocalArchiveLimits limits,
) {
  const fixedEndLength = 22;
  const maximumCommentLength = 0xffff;
  const zip64LocatorLength = 20;
  final archiveLength = input.fileLength;
  if (archiveLength > limits.maximumArchiveFileBytes) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.limitExceeded,
      'ZIP archive file exceeds the size limit.',
    );
  }
  if (archiveLength < fixedEndLength) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'The file is too short to be a ZIP archive.',
    );
  }

  final tailStart = max(
    0,
    archiveLength - fixedEndLength - maximumCommentLength,
  );
  final tail = input
      .subset(position: tailStart, length: archiveLength - tailStart)
      .toUint8List();
  final bytes = ByteData.sublistView(tail);
  final rawOffsets = <int>[];
  final validOffsets = <int>[];
  for (var offset = 0; offset <= tail.length - fixedEndLength; offset++) {
    if (bytes.getUint32(offset, Endian.little) != ZipDirectory.eocdSignature) {
      continue;
    }
    rawOffsets.add(offset);
    final commentLength = bytes.getUint16(offset + 20, Endian.little);
    if (tailStart + offset + fixedEndLength + commentLength != archiveLength) {
      continue;
    }
    validOffsets.add(offset);
  }
  if (validOffsets.isEmpty) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'The file has no valid ZIP end-of-directory record.',
    );
  }
  if (validOffsets.length != 1 ||
      rawOffsets.any((offset) => offset > validOffsets.single)) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP end-of-directory records are ambiguous.',
    );
  }
  final endOffset = tailStart + validOffsets.single;

  final tailOffset = endOffset - tailStart;
  final diskNumber = bytes.getUint16(tailOffset + 4, Endian.little);
  final centralDisk = bytes.getUint16(tailOffset + 6, Endian.little);
  final entriesOnDisk = bytes.getUint16(tailOffset + 8, Endian.little);
  final totalEntries = bytes.getUint16(tailOffset + 10, Endian.little);
  final centralSize = bytes.getUint32(tailOffset + 12, Endian.little);
  final centralOffset = bytes.getUint32(tailOffset + 16, Endian.little);
  final usesZip64 =
      entriesOnDisk == 0xffff ||
      totalEntries == 0xffff ||
      centralSize == 0xffffffff ||
      centralOffset == 0xffffffff;
  final locatorOffset = endOffset - zip64LocatorLength;
  var hasZip64Locator = false;
  if (locatorOffset >= 0) {
    input.setPosition(locatorOffset);
    hasZip64Locator =
        input.readUint32() == ZipDirectory.zip64EocdLocatorSignature;
  }
  if (hasZip64Locator && !usesZip64) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP64 locator conflicts with the classic directory record.',
    );
  }
  if (!usesZip64) {
    if (diskNumber != 0 || centralDisk != 0 || entriesOnDisk != totalEntries) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.unsupported,
        'Multi-disk ZIP archives are not supported.',
      );
    }
    if (totalEntries > limits.maximumEntries) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'ZIP archive exceeds the entry limit.',
      );
    }
    return _ZipEnvelope(
      entriesOnDisk: entriesOnDisk,
      totalEntries: totalEntries,
      centralDirectoryOffset: centralOffset,
      centralDirectorySize: centralSize,
      endOffset: endOffset,
      eocdOffset: endOffset,
    );
  }

  if (!hasZip64Locator) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP64 entry count has no locator.',
    );
  }
  input.setPosition(locatorOffset);
  if (input.readUint32() != ZipDirectory.zip64EocdLocatorSignature) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP64 entry count has no locator.',
    );
  }
  final locatorDisk = input.readUint32();
  final zip64Offset = input.readUint64();
  final locatorDisks = input.readUint32();
  if (locatorDisk != 0 || locatorDisks != 1) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.unsupported,
      'Multi-disk ZIP archives are not supported.',
    );
  }
  if (zip64Offset < 0 ||
      zip64Offset + ZipDirectory.zip64EocdSize > locatorOffset) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP64 end-of-directory bounds are invalid.',
    );
  }
  input.setPosition(zip64Offset);
  if (input.readUint32() != ZipDirectory.zip64EocdSignature) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP64 end-of-directory signature is invalid.',
    );
  }
  final recordSize = input.readUint64();
  if (recordSize < 44 || zip64Offset + 12 + recordSize > locatorOffset) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP64 end-of-directory bounds are invalid.',
    );
  }
  input.readUint16();
  input.readUint16();
  final zip64Disk = input.readUint32();
  final zip64CentralDisk = input.readUint32();
  final zip64EntriesOnDisk = input.readUint64();
  final zip64TotalEntries = input.readUint64();
  final zip64CentralSize = input.readUint64();
  final zip64CentralOffset = input.readUint64();
  if (zip64Disk != 0 ||
      zip64CentralDisk != 0 ||
      zip64EntriesOnDisk != zip64TotalEntries) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.unsupported,
      'Multi-disk ZIP archives are not supported.',
    );
  }
  if (zip64TotalEntries > limits.maximumEntries) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.limitExceeded,
      'ZIP archive exceeds the entry limit.',
    );
  }
  return _ZipEnvelope(
    entriesOnDisk: zip64EntriesOnDisk,
    totalEntries: zip64TotalEntries,
    centralDirectoryOffset: zip64CentralOffset,
    centralDirectorySize: zip64CentralSize,
    endOffset: zip64Offset,
    eocdOffset: endOffset,
  );
}

void _scanZipStructure(
  InputFileStream input,
  _ZipEnvelope envelope,
  LocalArchiveLimits limits,
) {
  const fixedCentralHeaderLength = 46;
  const fixedLocalHeaderLength = 30;
  final centralStart = envelope.centralDirectoryOffset;
  final centralEnd = centralStart + envelope.centralDirectorySize;
  if (centralStart < 0 ||
      envelope.centralDirectorySize < 0 ||
      centralEnd > envelope.endOffset ||
      envelope.endOffset > input.fileLength) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP central-directory bounds are invalid.',
    );
  }
  if (envelope.centralDirectorySize > limits.maximumMetadataBytes) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.limitExceeded,
      'ZIP archive metadata exceeds the limit.',
    );
  }

  var offset = centralStart;
  var count = 0;
  var metadataBytes = envelope.centralDirectorySize;
  while (offset < centralEnd) {
    if (centralEnd - offset < fixedCentralHeaderLength) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'ZIP central-directory entry is truncated.',
      );
    }
    input.setPosition(offset);
    if (input.readUint32() != ZipFileHeader.signature) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'ZIP central-directory signature is invalid.',
      );
    }
    input.setPosition(offset + 28);
    final nameLength = input.readUint16();
    final extraLength = input.readUint16();
    final commentLength = input.readUint16();
    input.setPosition(offset + 6);
    input.readUint16();
    final flags = input.readUint16();
    input.setPosition(offset + 20);
    final compressedSize = input.readUint32();
    final uncompressedSize = input.readUint32();
    input.setPosition(offset + 34);
    final diskStart = input.readUint16();
    input.setPosition(offset + 42);
    var localOffset = input.readUint32();
    final centralLength =
        fixedCentralHeaderLength + nameLength + extraLength + commentLength;
    if (centralLength > centralEnd - offset) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'ZIP central-directory entry is truncated.',
      );
    }
    if ((flags & _zipDataDescriptorFlag) != 0 &&
        (compressedSize == 0xffffffff || uncompressedSize == 0xffffffff)) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.unsupported,
        'ZIP64 data descriptors are not supported.',
      );
    }
    if (localOffset == 0xffffffff) {
      localOffset = _readZip64LocalOffset(
        input,
        extraOffset: offset + fixedCentralHeaderLength + nameLength,
        extraLength: extraLength,
        uncompressedSize: uncompressedSize,
        compressedSize: compressedSize,
        diskStart: diskStart,
      );
    }

    count++;
    if (count > limits.maximumEntries) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'ZIP archive exceeds the entry limit.',
      );
    }
    if (localOffset < 0 ||
        localOffset + fixedLocalHeaderLength > centralStart) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'ZIP local entry header is out of bounds.',
      );
    }
    input.setPosition(localOffset);
    if (input.readUint32() != ZipFile.zipSignature) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'ZIP local entry signature is invalid.',
      );
    }
    input.setPosition(localOffset + 26);
    final localNameLength = input.readUint16();
    final localExtraLength = input.readUint16();
    final localMetadataLength =
        fixedLocalHeaderLength + localNameLength + localExtraLength;
    if (localMetadataLength > centralStart - localOffset) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'ZIP local entry header is truncated.',
      );
    }
    metadataBytes += localMetadataLength;
    if (metadataBytes > limits.maximumMetadataBytes) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'ZIP archive metadata exceeds the limit.',
      );
    }

    offset += centralLength;
  }
  if (offset != centralEnd ||
      count != envelope.totalEntries ||
      count != envelope.entriesOnDisk) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP central-directory entry count is inconsistent.',
    );
  }
}

int _readZip64LocalOffset(
  InputFileStream input, {
  required int extraOffset,
  required int extraLength,
  required int uncompressedSize,
  required int compressedSize,
  required int diskStart,
}) {
  const zip64ExtraId = 1;
  var offset = extraOffset;
  final end = extraOffset + extraLength;
  while (end - offset >= 4) {
    input.setPosition(offset);
    final id = input.readUint16();
    final length = input.readUint16();
    offset += 4;
    if (length > end - offset) break;
    if (id != zip64ExtraId) {
      offset += length;
      continue;
    }

    var cursor = offset;
    final fieldEnd = offset + length;
    if (uncompressedSize == 0xffffffff) cursor += 8;
    if (compressedSize == 0xffffffff) cursor += 8;
    if (cursor + 8 > fieldEnd) break;
    input.setPosition(cursor);
    final localOffset = input.readUint64();
    if (diskStart == 0xffff && cursor + 12 > fieldEnd) break;
    return localOffset;
  }
  throw const _WorkerAbort(
    LocalArchiveErrorKind.invalidArchive,
    'ZIP64 local entry offset is missing.',
  );
}

final class _ZipEnvelope {
  const _ZipEnvelope({
    required this.entriesOnDisk,
    required this.totalEntries,
    required this.centralDirectoryOffset,
    required this.centralDirectorySize,
    required this.endOffset,
    required this.eocdOffset,
  });

  final int entriesOnDisk;
  final int totalEntries;
  final int centralDirectoryOffset;
  final int centralDirectorySize;
  final int endOffset;
  final int eocdOffset;
}

void _sendExtractionProgress(
  _WorkerRequest request,
  _ExtractionEntry entry,
  int completedEntries,
  int totalEntries,
  int processedBytes,
  int totalBytes,
  int entryProcessedBytes,
) {
  request.events.send(
    _WorkerProgressEvent(
      LocalArchiveProgress(
        operation: request.operation,
        phase: LocalArchivePhase.extracting,
        entryName: entry.name,
        entryIsDirectory: entry.isDirectory,
        entryProcessedBytes: entryProcessedBytes,
        entryTotalBytes: entry.size,
        completedEntries: completedEntries,
        totalEntries: totalEntries,
        processedBytes: processedBytes,
        totalBytes: totalBytes,
      ),
    ),
  );
}

List<_ExtractionEntry> _preflightZip(
  ZipDirectory directory,
  InputFileStream input,
  LocalArchiveLimits limits,
) {
  final archiveLength = input.fileLength;
  if (directory.filePosition < 0) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'The file has no ZIP end-of-directory record.',
    );
  }
  if (directory.numberOfThisDisk != 0 ||
      directory.diskWithTheStartOfTheCentralDirectory != 0 ||
      directory.totalCentralDirectoryEntriesOnThisDisk !=
          directory.totalCentralDirectoryEntries) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.unsupported,
      'Multi-disk ZIP archives are not supported.',
    );
  }
  if (directory.totalCentralDirectoryEntries > limits.maximumEntries ||
      directory.fileHeaders.length > limits.maximumEntries) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.limitExceeded,
      'ZIP archive exceeds the entry limit.',
    );
  }
  if (directory.fileHeaders.length != directory.totalCentralDirectoryEntries) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP central-directory entry count is inconsistent.',
    );
  }
  if (directory.centralDirectoryOffset < 0 ||
      directory.centralDirectorySize < 0 ||
      directory.centralDirectoryOffset + directory.centralDirectorySize >
          directory.filePosition ||
      directory.filePosition > archiveLength) {
    throw const _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP central-directory bounds are invalid.',
    );
  }

  final entries = <_ExtractionEntry>[];
  final paths = _ArchivePathRegistry();
  final localHeaderOffsets = <int>{};
  var totalBytes = 0;
  var totalCompressedBytes = 0;
  var pathComponents = 0;
  for (final header in directory.fileHeaders) {
    final file = header.file;
    if (file == null || file.filename != header.filename) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'ZIP local and central entry names differ.',
        path: header.filename,
      );
    }
    if (header.diskNumberStart != 0) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.unsupported,
        'Multi-disk ZIP entries are not supported.',
        path: header.filename,
      );
    }
    if ((header.generalPurposeBitFlag &
            (_zipEncryptionFlag |
                _zipStrongEncryptionFlag |
                _zipCentralDirectoryEncryptionFlag)) !=
        0) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.unsupported,
        'Encrypted ZIP entries are not supported.',
        path: header.filename,
      );
    }
    if (header.compressionMethod != _zipStoredMethod &&
        header.compressionMethod != _zipDeflateMethod) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.unsupported,
        'ZIP compression method ${header.compressionMethod} is not supported.',
        path: header.filename,
      );
    }
    if (header.uncompressedSize < 0) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'ZIP entry exceeds the per-entry extraction limit.',
        path: header.filename,
      );
    }
    if (header.compressedSize < 0) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'ZIP entry exceeds the compressed-size limit.',
        path: header.filename,
      );
    }
    final expectedCompression = header.compressionMethod == _zipDeflateMethod
        ? CompressionType.deflate
        : CompressionType.none;
    _validateLocalZipBounds(input, directory, header);

    // archive 4.3.0 treats a matching CRC as the optional descriptor
    // signature. Restore the independently validated central values.
    if ((header.generalPurposeBitFlag & _zipDataDescriptorFlag) != 0) {
      file
        ..crc32 = header.crc32
        ..compressedSize = header.compressedSize
        ..uncompressedSize = header.uncompressedSize;
    }
    if (file.flags != header.generalPurposeBitFlag ||
        file.compressionMethod != expectedCompression ||
        file.compressedSize != header.compressedSize ||
        file.uncompressedSize != header.uncompressedSize ||
        file.crc32 != header.crc32) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'ZIP local and central entry metadata differ.',
        path: header.filename,
      );
    }
    if (header.localHeaderOffset < 0 ||
        header.localHeaderOffset >= directory.centralDirectoryOffset ||
        !localHeaderOffsets.add(header.localHeaderOffset)) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'ZIP entry points outside the local-file area.',
        path: header.filename,
      );
    }
    final unixType = (header.externalFileAttributes >> 16) & _unixFileTypeMask;
    if (unixType == _unixSymbolicLinkType) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.unsupported,
        'Symbolic links in ZIP archives are not supported.',
        path: header.filename,
      );
    }
    if (unixType != 0 &&
        unixType != _unixRegularFileType &&
        unixType != _unixDirectoryType) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.unsupported,
        'Special filesystem entries in ZIP archives are not supported.',
        path: header.filename,
      );
    }

    final slashDirectory = header.filename.endsWith('/');
    final isDirectory = slashDirectory || unixType == _unixDirectoryType;
    if ((unixType == _unixDirectoryType && !slashDirectory) ||
        (unixType == _unixRegularFileType && slashDirectory)) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'ZIP entry type and path disagree.',
        path: header.filename,
      );
    }
    if (isDirectory &&
        (header.uncompressedSize != 0 || header.compressedSize != 0)) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'ZIP directory entries must not contain data.',
        path: header.filename,
      );
    }
    if (header.uncompressedSize > limits.maximumEntryBytes) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'ZIP entry exceeds the per-entry extraction limit.',
        path: header.filename,
      );
    }
    if (header.compressedSize > limits.maximumCompressedEntryBytes) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'ZIP entry exceeds the compressed-size limit.',
        path: header.filename,
      );
    }
    totalBytes += header.uncompressedSize;
    if (totalBytes > limits.maximumTotalBytes) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'ZIP archive exceeds the total extraction limit.',
      );
    }
    totalCompressedBytes += header.compressedSize;
    if (totalCompressedBytes > limits.maximumCompressedTotalBytes) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'ZIP archive exceeds the compressed-size limit.',
      );
    }

    final components = _validatedWorkerPath(
      header.filename,
      limits.maximumDepth,
    );
    pathComponents += components.length;
    if (pathComponents > limits.maximumPathComponents) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'ZIP paths exceed the component limit.',
      );
    }
    paths.add(
      components,
      kind: isDirectory ? _ArchivePathKind.directory : _ArchivePathKind.file,
      displayPath: header.filename,
    );
    entries.add(
      _ExtractionEntry(
        name: header.filename,
        components: components,
        isDirectory: isDirectory,
        size: header.uncompressedSize,
        crc32: header.crc32,
        file: file,
      ),
    );
  }
  return entries;
}

void _validateLocalZipBounds(
  InputFileStream input,
  ZipDirectory directory,
  ZipFileHeader header,
) {
  const fixedLocalHeaderLength = 30;
  final offset = header.localHeaderOffset;
  if (offset + fixedLocalHeaderLength > directory.centralDirectoryOffset) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP local entry header is truncated.',
      path: header.filename,
    );
  }

  input.setPosition(offset);
  if (input.readUint32() != ZipFile.zipSignature) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP local entry signature is invalid.',
      path: header.filename,
    );
  }
  input.readUint16();
  final flags = input.readUint16();
  final method = input.readUint16();
  input.readUint16();
  input.readUint16();
  final crc32 = input.readUint32();
  final compressedSize = input.readUint32();
  final uncompressedSize = input.readUint32();
  final nameLength = input.readUint16();
  final extraLength = input.readUint16();
  final dataStart = offset + fixedLocalHeaderLength + nameLength + extraLength;
  final dataEnd = dataStart + header.compressedSize;
  if (dataStart > directory.centralDirectoryOffset ||
      dataEnd > directory.centralDirectoryOffset) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP compressed entry data is out of bounds.',
      path: header.filename,
    );
  }
  if (flags != header.generalPurposeBitFlag ||
      method != header.compressionMethod) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP local and central entry metadata differ.',
      path: header.filename,
    );
  }

  if ((flags & _zipDataDescriptorFlag) != 0) {
    _validateZipDataDescriptor(
      input,
      header,
      dataEnd,
      directory.centralDirectoryOffset,
    );
    return;
  }
  final expectedCompressedSize = header.compressedSize > _maximumZip32Value
      ? _maximumZip32Value
      : header.compressedSize;
  final expectedUncompressedSize = header.uncompressedSize > _maximumZip32Value
      ? _maximumZip32Value
      : header.uncompressedSize;
  if (crc32 != header.crc32 ||
      compressedSize != expectedCompressedSize ||
      uncompressedSize != expectedUncompressedSize) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP local and central entry sizes or checksum differ.',
      path: header.filename,
    );
  }
}

void _validateZipDataDescriptor(
  InputFileStream input,
  ZipFileHeader header,
  int descriptorOffset,
  int maximumOffset,
) {
  const descriptorWithoutSignatureLength = 12;
  const descriptorWithSignatureLength = 16;
  if (descriptorOffset + descriptorWithoutSignatureLength > maximumOffset) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP entry data descriptor is truncated.',
      path: header.filename,
    );
  }

  input.setPosition(descriptorOffset);
  final first = input.readUint32();
  final second = input.readUint32();
  final third = input.readUint32();
  final usesZip32Sizes =
      header.compressedSize <= _maximumZip32Value &&
      header.uncompressedSize <= _maximumZip32Value;
  final unsignedMatches =
      usesZip32Sizes &&
      first == header.crc32 &&
      second == header.compressedSize &&
      third == header.uncompressedSize;
  if (unsignedMatches) return;

  if (first != _zipDataDescriptorSignature) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP data descriptor and central entry metadata differ.',
      path: header.filename,
    );
  }
  if (descriptorOffset + descriptorWithSignatureLength > maximumOffset) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP entry data descriptor is truncated.',
      path: header.filename,
    );
  }
  final fourth = input.readUint32();
  final signedMatches =
      usesZip32Sizes &&
      second == header.crc32 &&
      third == header.compressedSize &&
      fourth == header.uncompressedSize;
  if (!signedMatches) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.invalidArchive,
      'ZIP data descriptor and central entry metadata differ.',
      path: header.filename,
    );
  }
}

List<String> _validatedWorkerPath(String value, int maximumDepth) {
  try {
    final components = validateRelativeLocalPath(
      value,
      maximumDepth: maximumDepth,
    );
    if (components.any(_archiveStagePattern.hasMatch)) {
      throw const FormatException();
    }
    return components;
  } on FormatException {
    throw _WorkerAbort(
      LocalArchiveErrorKind.unsafeEntry,
      'ZIP entry path is unsafe.',
      path: value,
    );
  }
}

final class _ExtractionEntry {
  const _ExtractionEntry({
    required this.name,
    required this.components,
    required this.isDirectory,
    required this.size,
    required this.crc32,
    required this.file,
  });

  final String name;
  final List<String> components;
  final bool isDirectory;
  final int size;
  final int crc32;
  final ZipFile file;
}

enum _ArchivePathKind { file, directory }

final class _ArchivePathRegistry {
  final _ArchivePathNode _root = _ArchivePathNode();

  void add(
    List<String> components, {
    required _ArchivePathKind kind,
    required String displayPath,
  }) {
    final isDirectory = kind == _ArchivePathKind.directory;
    var node = _root;
    for (var index = 0; index < components.length; index++) {
      if (node.isFile) {
        throw _WorkerAbort(
          LocalArchiveErrorKind.unsafeEntry,
          'ZIP entry descends through a file path.',
          path: displayPath,
        );
      }
      final key = conservativeDestinationNameKey(components[index]);
      node = node.children.putIfAbsent(key, _ArchivePathNode.new);
    }
    if (node.isExplicit || (!isDirectory && node.children.isNotEmpty)) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.unsafeEntry,
        'ZIP entries have duplicate or conflicting destination paths.',
        path: displayPath,
      );
    }
    node.isExplicit = true;
    node.isFile = !isDirectory;
  }
}

final class _ArchivePathNode {
  final Map<String, _ArchivePathNode> children = <String, _ArchivePathNode>{};
  bool isExplicit = false;
  bool isFile = false;
}

final class _ProgressInputFileStream extends InputFileStream {
  factory _ProgressInputFileStream(
    _CreationEntry entry,
    void Function(int count) onBytes,
  ) {
    final handle = _openCreationInput(entry);
    try {
      return _ProgressInputFileStream._(handle, onBytes);
    } on Object {
      handle.closeSync();
      rethrow;
    }
  }

  _ProgressInputFileStream._(super.fh, this._onBytes) : super.withFileHandle();

  final void Function(int count) _onBytes;

  @override
  InputStream readBytes(int count) {
    final bytes = super.readBytes(count);
    _onBytes(bytes.length);
    return bytes;
  }
}

final class _CompressedFileContent extends FileContent {
  _CompressedFileContent(this.path);

  final String path;
  InputFileStream? _stream;

  @override
  bool get isCompressed => true;

  @override
  int get length => File(path).lengthSync();

  @override
  InputStream getStream({bool decompress = true}) {
    if (decompress) {
      throw StateError('Compressed ZIP scratch cannot be decoded directly.');
    }
    return _stream ??= InputFileStream(path);
  }

  @override
  void write(OutputStream output) {
    output.writeStream(getStream(decompress: false));
  }

  @override
  Future<void> close() async {
    await _stream?.close();
    _stream = null;
  }

  @override
  void closeSync() {
    _stream?.closeSync();
    _stream = null;
  }
}

final class _CompressedCreationBudget {
  _CompressedCreationBudget(this.limits);

  final LocalArchiveLimits limits;
  int written = 0;

  void reserve(String sourcePath, int entryWritten, int count) {
    if (entryWritten + count > limits.maximumCompressedEntryBytes) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'Compressed source exceeds the per-entry archive limit.',
        path: sourcePath,
      );
    }
    if (written + count > limits.maximumCompressedTotalBytes) {
      throw const _WorkerAbort(
        LocalArchiveErrorKind.limitExceeded,
        'Compressed sources exceed the total archive limit.',
      );
    }
    written += count;
  }
}

final class _BoundedCompressedOutput extends OutputStream {
  _BoundedCompressedOutput(String path, this.sourcePath, this._budget)
    : _output = OutputFileStream(path),
      super(byteOrder: ByteOrder.littleEndian);

  final String sourcePath;
  final _CompressedCreationBudget _budget;
  final OutputFileStream _output;

  @override
  int get length => _output.length;

  @override
  bool get isOpen => _output.isOpen;

  @override
  void clear() => _output.clear();

  @override
  Future<void> close() => _output.close();

  @override
  void closeSync() => _output.closeSync();

  @override
  void flush() => _output.flush();

  @override
  void writeByte(int value) {
    _throwIfWorkerCancelled();
    _budget.reserve(sourcePath, length, 1);
    _output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _throwIfWorkerCancelled();
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw RangeError.range(count, 0, bytes.length, 'length');
    }
    _budget.reserve(sourcePath, this.length, count);
    _output.writeBytes(bytes, length: count);
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      _throwIfWorkerCancelled();
      final count = min(_progressByteInterval, stream.length);
      if (count <= 0) break;
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);
}

final class _BoundedArchiveOutput extends OutputStream {
  _BoundedArchiveOutput(String path, this.maximumLength)
    : _output = OutputFileStream(path),
      super(byteOrder: ByteOrder.littleEndian);

  final int maximumLength;
  final OutputFileStream _output;

  @override
  int get length => _output.length;

  @override
  bool get isOpen => _output.isOpen;

  @override
  void clear() => _output.clear();

  @override
  Future<void> close() => _output.close();

  @override
  void closeSync() => _output.closeSync();

  @override
  void flush() => _output.flush();

  @override
  void writeByte(int value) {
    _throwIfWorkerCancelled();
    _reserve(1);
    _output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _throwIfWorkerCancelled();
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw RangeError.range(count, 0, bytes.length, 'length');
    }
    _reserve(count);
    _output.writeBytes(bytes, length: count);
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      _throwIfWorkerCancelled();
      final count = min(_progressByteInterval, stream.length);
      if (count <= 0) break;
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);

  void _reserve(int count) {
    if (length + count <= maximumLength) return;
    throw const _WorkerAbort(
      LocalArchiveErrorKind.limitExceeded,
      'Created ZIP archive exceeds the file-size limit.',
    );
  }
}

final class _ActualOutputBudget {
  _ActualOutputBudget(this.maximumBytes);

  final int maximumBytes;
  int written = 0;

  void add(int count) {
    written += count;
    if (written <= maximumBytes) return;
    throw const _WorkerAbort(
      LocalArchiveErrorKind.limitExceeded,
      'Decoded ZIP data exceeds the total extraction limit.',
    );
  }
}

final class _CheckedOutputStream extends OutputStream {
  _CheckedOutputStream(
    this.path,
    this.maximumLength,
    this._budget,
    this._onBytes,
  ) : _output = OutputFileStream(path),
      super(byteOrder: ByteOrder.littleEndian);

  final String path;
  final int maximumLength;
  final _ActualOutputBudget _budget;
  final void Function(int count) _onBytes;
  final OutputFileStream _output;
  int _crcState = 0xffffffff;

  int get crc32 => _crcState ^ 0xffffffff;

  @override
  int get length => _output.length;

  @override
  bool get isOpen => _output.isOpen;

  @override
  void clear() {
    _output.clear();
  }

  @override
  Future<void> close() => _output.close();

  @override
  void closeSync() => _output.closeSync();

  @override
  void flush() => _output.flush();

  @override
  void writeByte(int value) {
    _throwIfWorkerCancelled();
    if (length + 1 > maximumLength) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'Decoded ZIP entry exceeds its declared size.',
        path: path,
      );
    }
    _budget.add(1);
    _crcState = getCrc32Byte(_crcState, value);
    _output.writeByte(value);
    _onBytes(1);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _throwIfWorkerCancelled();
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw RangeError.range(count, 0, bytes.length, 'length');
    }
    if (this.length + count > maximumLength) {
      throw _WorkerAbort(
        LocalArchiveErrorKind.invalidArchive,
        'Decoded ZIP entry exceeds its declared size.',
        path: path,
      );
    }
    _budget.add(count);
    if (count == bytes.length) {
      _crcState = getCrc32(bytes, _crcState ^ 0xffffffff) ^ 0xffffffff;
    } else {
      for (var index = 0; index < count; index++) {
        _crcState = getCrc32Byte(_crcState, bytes[index]);
      }
    }
    _output.writeBytes(bytes, length: count);
    _onBytes(count);
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      _throwIfWorkerCancelled();
      final count = min(_progressByteInterval, stream.length);
      if (count <= 0) break;
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);
}
