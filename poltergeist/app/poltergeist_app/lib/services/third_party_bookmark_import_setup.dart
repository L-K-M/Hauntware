import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'uuid.dart';

typedef ThirdPartyBookmarkFilePicker =
    Future<List<ThirdPartyBookmarkImportFile>?> Function(
      ThirdPartyBookmarkFormat format,
    );

typedef ThirdPartyBookmarkPreviewStarter =
    Future<ThirdPartyBookmarkPreviewTask> Function({
      required ThirdPartyBookmarkFormat format,
      required List<ThirdPartyBookmarkImportFile> files,
      required List<Bookmark> existingBookmarks,
    });

/// One cancellable parse. Dialog teardown kills production's worker isolate.
final class ThirdPartyBookmarkPreviewTask {
  ThirdPartyBookmarkPreviewTask._(
    Future<ThirdPartyBookmarkImportPreview> source,
    this._onCancel,
  ) {
    source.then(_complete, onError: _completeError);
  }

  factory ThirdPartyBookmarkPreviewTask.fromFuture(
    Future<ThirdPartyBookmarkImportPreview> source, {
    void Function()? onCancel,
  }) => ThirdPartyBookmarkPreviewTask._(source, onCancel ?? _ignoreCancel);

  final _completer = Completer<ThirdPartyBookmarkImportPreview>();
  final void Function() _onCancel;
  bool _finished = false;

  Future<ThirdPartyBookmarkImportPreview> get result => _completer.future;

  void cancel() {
    if (_finished) return;

    _finished = true;
    try {
      _onCancel();
    } finally {
      _completer.completeError(
        const ThirdPartyBookmarkImportCancelledException(),
      );
    }
  }

  void _complete(ThirdPartyBookmarkImportPreview preview) {
    if (_finished) return;

    _finished = true;
    _completer.complete(preview);
  }

  void _completeError(Object error, StackTrace stackTrace) {
    if (_finished) return;

    _finished = true;
    _completer.completeError(error, stackTrace);
  }
}

void _ignoreCancel() {}

final class ThirdPartyBookmarkImportCancelledException implements Exception {
  const ThirdPartyBookmarkImportCancelledException();
}

/// Cross-platform wiring for D22's FileZilla, WinSCP, and Cyberduck imports.
class ThirdPartyBookmarkImportSetup {
  const ThirdPartyBookmarkImportSetup({
    required this.bookmarks,
    required this.pickFiles,
    required this.startPreview,
  });

  final BookmarkRepository bookmarks;
  final ThirdPartyBookmarkFilePicker pickFiles;
  final ThirdPartyBookmarkPreviewStarter startPreview;
}

ThirdPartyBookmarkImportSetup buildThirdPartyBookmarkImportSetup({
  required BookmarkRepository bookmarks,
  ThirdPartyBookmarkFilePicker pickFiles = pickThirdPartyBookmarkFiles,
  ThirdPartyBookmarkPreviewStarter startPreview =
      startThirdPartyBookmarkImportPreview,
}) {
  return ThirdPartyBookmarkImportSetup(
    bookmarks: bookmarks,
    pickFiles: pickFiles,
    startPreview: startPreview,
  );
}

/// Starts the bounded parser in a worker that the dialog can kill on cancel.
Future<ThirdPartyBookmarkPreviewTask> startThirdPartyBookmarkImportPreview({
  required ThirdPartyBookmarkFormat format,
  required List<ThirdPartyBookmarkImportFile> files,
  required List<Bookmark> existingBookmarks,
}) async {
  final messages = ReceivePort();
  final errors = ReceivePort();
  final workerResult = Completer<ThirdPartyBookmarkImportPreview>();
  var portsClosed = false;

  late final Isolate worker;
  try {
    worker = await Isolate.spawn(
      _runThirdPartyBookmarkImportPreview,
      _ThirdPartyBookmarkWorkerRequest(
        messages.sendPort,
        format,
        files,
        existingBookmarks,
      ),
      onError: errors.sendPort,
      errorsAreFatal: true,
      debugName: _thirdPartyBookmarkWorkerName,
    );
  } on Object {
    messages.close();
    errors.close();
    rethrow;
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (workerResult.isCompleted) return;
    workerResult.completeError(error, stackTrace);
  }

  messages.listen((message) {
    switch (message) {
      case _ThirdPartyBookmarkWorkerSuccess(:final preview):
        if (!workerResult.isCompleted) workerResult.complete(preview);
      case _ThirdPartyBookmarkWorkerFailure(:final error, :final stackTrace):
        completeError(error, StackTrace.fromString(stackTrace));
      default:
        completeError(
          StateError('the bookmark import worker returned an invalid result'),
          StackTrace.current,
        );
    }
  });
  errors.listen((message) {
    final parts = message is List ? message : const [];
    final error = parts.isEmpty
        ? StateError('the bookmark import worker failed')
        : StateError('${parts.first}');
    final stackTrace = parts.length < 2
        ? StackTrace.current
        : StackTrace.fromString('${parts[1]}');
    completeError(error, stackTrace);
  });
  void closePorts() {
    if (portsClosed) return;

    portsClosed = true;
    messages.close();
    errors.close();
  }

  final result = workerResult.future.whenComplete(closePorts);
  return ThirdPartyBookmarkPreviewTask.fromFuture(
    result,
    onCancel: () {
      worker.kill(priority: Isolate.immediate);
      completeError(
        const ThirdPartyBookmarkImportCancelledException(),
        StackTrace.current,
      );
      closePorts();
    },
  );
}

const _thirdPartyBookmarkWorkerName = 'third-party-bookmark-import';

final class _ThirdPartyBookmarkWorkerRequest {
  const _ThirdPartyBookmarkWorkerRequest(
    this.replyTo,
    this.format,
    this.files,
    this.existingBookmarks,
  );

  final SendPort replyTo;
  final ThirdPartyBookmarkFormat format;
  final List<ThirdPartyBookmarkImportFile> files;
  final List<Bookmark> existingBookmarks;
}

sealed class _ThirdPartyBookmarkWorkerMessage {
  const _ThirdPartyBookmarkWorkerMessage();
}

final class _ThirdPartyBookmarkWorkerSuccess
    extends _ThirdPartyBookmarkWorkerMessage {
  const _ThirdPartyBookmarkWorkerSuccess(this.preview);

  final ThirdPartyBookmarkImportPreview preview;
}

final class _ThirdPartyBookmarkWorkerFailure
    extends _ThirdPartyBookmarkWorkerMessage {
  const _ThirdPartyBookmarkWorkerFailure(this.error, this.stackTrace);

  final Object error;
  final String stackTrace;
}

void _runThirdPartyBookmarkImportPreview(
  _ThirdPartyBookmarkWorkerRequest request,
) {
  try {
    final preview = ThirdPartyBookmarkImportService(mintId: uuidV4).loadPreview(
      format: request.format,
      files: request.files,
      existingBookmarks: request.existingBookmarks,
    );
    Isolate.exit(request.replyTo, _ThirdPartyBookmarkWorkerSuccess(preview));
  } on Object catch (error, stackTrace) {
    Isolate.exit(
      request.replyTo,
      _ThirdPartyBookmarkWorkerFailure(error, '$stackTrace'),
    );
  }
}

/// Reads bytes because mobile document providers need not expose local paths.
Future<List<ThirdPartyBookmarkImportFile>?> pickThirdPartyBookmarkFiles(
  ThirdPartyBookmarkFormat format,
) async {
  final allowedExtensions = switch (format) {
    ThirdPartyBookmarkFormat.fileZilla => const ['xml'],
    ThirdPartyBookmarkFormat.winScp => const ['ini'],
    ThirdPartyBookmarkFormat.cyberduck => const ['duck'],
  };
  const windowsOptions = WindowsOptions(lockParentWindow: true);
  // Cyberduck keeps one bookmark per file, so only it picks several.
  final List<PlatformFile> picked;
  if (format == ThirdPartyBookmarkFormat.cyberduck) {
    picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      windowsOptions: windowsOptions,
    );
  } else {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      windowsOptions: windowsOptions,
    );
    picked = [?file];
  }
  if (picked.isEmpty) return null;

  return readThirdPartyBookmarkImportFiles(picked);
}

/// Applies the core bounds before and during streaming so picker buffers cannot
/// bypass them. The reported length is only a hint; the stream is bounded.
Future<List<ThirdPartyBookmarkImportFile>> readThirdPartyBookmarkImportFiles(
  List<PlatformFile> pickedFiles,
) async {
  if (pickedFiles.length > thirdPartyBookmarkImportMaxFiles) {
    throw const ThirdPartyBookmarkImportException(
      ThirdPartyBookmarkImportFailure.tooManyFiles,
    );
  }

  final files = <ThirdPartyBookmarkImportFile>[];
  var totalBytes = 0;
  for (final file in pickedFiles) {
    final sourceName = ThirdPartyBookmarkImportFile.normalizeName(file.name);

    // Unknown counts as 0 here; the bounded stream still catches it.
    final reported = file.lengthSync() ?? 0;
    if (reported > thirdPartyBookmarkImportMaxFileBytes) {
      throw ThirdPartyBookmarkImportException(
        ThirdPartyBookmarkImportFailure.fileTooLarge,
        sourceName: sourceName,
      );
    }
    if (reported > 0 &&
        totalBytes + reported > thirdPartyBookmarkImportMaxTotalBytes) {
      throw const ThirdPartyBookmarkImportException(
        ThirdPartyBookmarkImportFailure.totalSizeExceeded,
      );
    }

    final bytes = await _readPickedBookmarkFile(file, sourceName, totalBytes);
    totalBytes += bytes.length;
    files.add(ThirdPartyBookmarkImportFile(sourceName, bytes));
  }

  return List.unmodifiable(files);
}

Future<Uint8List> _readPickedBookmarkFile(
  PlatformFile file,
  String sourceName,
  int previousBytes,
) async {
  final stream = file.readAsByteStream();
  final bytes = BytesBuilder(copy: false);

  await for (final chunk in stream) {
    final fileBytes = bytes.length + chunk.length;
    if (fileBytes > thirdPartyBookmarkImportMaxFileBytes) {
      throw ThirdPartyBookmarkImportException(
        ThirdPartyBookmarkImportFailure.fileTooLarge,
        sourceName: sourceName,
      );
    }
    if (previousBytes + fileBytes > thirdPartyBookmarkImportMaxTotalBytes) {
      throw const ThirdPartyBookmarkImportException(
        ThirdPartyBookmarkImportFailure.totalSizeExceeded,
      );
    }

    bytes.add(chunk);
  }

  return bytes.takeBytes();
}
