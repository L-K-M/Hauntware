/// The JSON document behind each of the engine's sync state files (03
/// §4.10, D62): the pin verdicts, the decode tripwires and the enrollment
/// state. One place for how they open, set a damaged file aside, refuse
/// to replace a file they could not read, and write only while this
/// process holds the support directory alone.
library;

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../settings/device_settings_store.dart'
    show unusedCorruptCopyPath, writeFileAtomically;
import '../settings/instance_lock.dart' show SupportDirectoryAccess;

/// Every sync state file names its schema under this key.
const String _versionKey = 'version';

/// The schema this build reads and writes; a higher one came from a newer
/// build and is never rewritten by this one.
const int syncStateSchemaVersion = 1;

/// Replaces a file's contents: [writeFileAtomically] outside tests.
typedef SyncStateWriter = Future<void> Function(File target, List<int> bytes);

/// What went wrong with a sync state file when its store opened.
enum SyncStateIssueKind {
  /// The file was not a document this build can read. It was renamed to
  /// [SyncStateIssue.preservedAs], bytes untouched, and the store started
  /// empty; the next change writes a new file.
  recovered,

  /// The file could not be read, or was damaged and could not be renamed
  /// aside. It is left as it is, the store started empty, and no change
  /// is saved this session.
  leftAsIs,

  /// A newer build wrote the file. What this build knows was read from
  /// it; it is left as it is, and no change is saved this session.
  newerVersion;

  /// Whether the store refuses to write for the rest of the session.
  bool get readOnly => switch (this) {
    leftAsIs || newerVersion => true,
    recovered => false,
  };
}

/// The one problem a sync state store met while opening, for the engine
/// to report.
@immutable
final class SyncStateIssue {
  const SyncStateIssue(this.kind, {this.preservedAs, this.detail});

  final SyncStateIssueKind kind;

  /// Where the damaged file went; set for [SyncStateIssueKind.recovered]
  /// only.
  final String? preservedAs;

  /// The failure behind [kind], for diagnostics.
  final String? detail;
}

/// A change a sync state store applied in memory but did not save, because
/// this session leaves the file as it is ([SyncStateIssueKind.readOnly]).
final class SyncStateReadOnlyException implements Exception {
  const SyncStateReadOnlyException(this.path, this.kind);

  final String path;
  final SyncStateIssueKind kind;

  @override
  String toString() =>
      'SyncStateReadOnlyException: $path is left as it is this session '
      '(${kind.name}), so the change was not saved';
}

/// One sync state file: the store holds its values in memory and hands
/// [save] the whole document after each change.
///
/// Writes replace the file atomically ([writeFileAtomically]: a sibling
/// temp file, flushed, renamed over the target, then the directory synced)
/// and queue, so the file holds the last change. With
/// [SupportDirectoryAccess.unguarded] another instance may use the same
/// files, so the store reads the file and never touches it again: no
/// write, and no rename of a damaged file; changes stay in memory for the
/// session, as the capability cache's do (D59).
final class SyncStateFile {
  SyncStateFile._(this._file, this._access, this._writer, this.issue);

  final File _file;
  final SupportDirectoryAccess _access;
  final SyncStateWriter _writer;

  /// The problem met while opening, or null when the file was fine or
  /// absent.
  final SyncStateIssue? issue;

  Future<void> _tail = Future<void>.value();
  int _queuedWrites = 0;
  bool _unsaved = false;

  /// Whether memory holds a change the file lacks: a write is queued, or
  /// the latest one failed. A store's change that changes nothing in
  /// memory still saves then, so retrying a failed change persists it.
  bool get hasUnsavedChanges => _unsaved;

  /// Opens [file] and decodes its body (the document without its version)
  /// with [decode], which throws a [FormatException] for a body it cannot
  /// use. Returns the body, or null when the store starts empty: no file,
  /// or a file this build cannot use, which [SyncStateFile.issue] then
  /// names. Never throws.
  ///
  /// A damaged file is renamed to `<name>.corrupt-<UTC time>` (with a
  /// counter when that name is taken) when [access] is exclusive, so the
  /// next change writes a fresh file at the freed path and the damaged
  /// bytes stay for diagnosis. [writer] and [now] are seams for tests.
  static Future<(SyncStateFile, T?)> open<T extends Object>(
    File file, {
    required SupportDirectoryAccess access,
    required T Function(Map<String, Object?> body) decode,
    SyncStateWriter writer = writeFileAtomically,
    DateTime Function() now = DateTime.now,
  }) async {
    SyncStateFile store([SyncStateIssue? issue]) =>
        SyncStateFile._(file, access, writer, issue);

    final List<int> raw;
    try {
      raw = await file.readAsBytes();
    } on PathNotFoundException {
      return (store(), null);
    } on FileSystemException catch (error) {
      return (
        store(SyncStateIssue(SyncStateIssueKind.leftAsIs, detail: '$error')),
        null,
      );
    }

    final int version;
    final T body;
    try {
      final document = jsonDecode(utf8.decode(raw));
      if (document is! Map<String, Object?>) {
        throw const FormatException('not a JSON object');
      }
      final found = document.remove(_versionKey);
      if (found is! int || found < 1) {
        throw const FormatException('no usable version');
      }
      version = found;
      if (version > syncStateSchemaVersion) {
        return (
          store(
            SyncStateIssue(
              SyncStateIssueKind.newerVersion,
              detail: 'schema $version',
            ),
          ),
          _tryDecode(decode, document),
        );
      }
      body = decode(document);
    } on FormatException catch (error) {
      return (await _setAside(file, access, writer, error, now()), null);
    }

    return (store(), body);
  }

  /// What [decode] makes of a newer build's [body], or null when it cannot
  /// read it.
  static T? _tryDecode<T extends Object>(
    T Function(Map<String, Object?>) decode,
    Map<String, Object?> body,
  ) {
    try {
      return decode(body);
    } on FormatException {
      return null;
    }
  }

  /// Renames a damaged [file] aside, or leaves it in place, and the store
  /// read-only, when the rename fails or another instance may use it.
  static Future<SyncStateFile> _setAside(
    File file,
    SupportDirectoryAccess access,
    SyncStateWriter writer,
    FormatException error,
    DateTime time,
  ) async {
    if (access == SupportDirectoryAccess.unguarded) {
      return SyncStateFile._(
        file,
        access,
        writer,
        SyncStateIssue(
          SyncStateIssueKind.leftAsIs,
          detail: '${error.message}; not renamed aside: unguarded',
        ),
      );
    }

    final String preservedAs;
    try {
      preservedAs = await unusedCorruptCopyPath(file, time);
      await file.rename(preservedAs);
    } on FileSystemException catch (renameError) {
      return SyncStateFile._(
        file,
        access,
        writer,
        SyncStateIssue(
          SyncStateIssueKind.leftAsIs,
          detail: '${error.message}; not renamed aside: $renameError',
        ),
      );
    }

    return SyncStateFile._(
      file,
      access,
      writer,
      SyncStateIssue(
        SyncStateIssueKind.recovered,
        preservedAs: preservedAs,
        detail: error.message,
      ),
    );
  }

  /// Queues a write of [body] under the current schema version. Completes
  /// at once, writing nothing, when access is unguarded. Throws
  /// [SyncStateReadOnlyException] when this session leaves the file as it
  /// is, and the write's own error when it fails; the caller's change stays
  /// in memory either way, and the next save carries it.
  Future<void> save(Map<String, Object?> body) {
    if (_access == SupportDirectoryAccess.unguarded) return Future.value();
    if (issue case SyncStateIssue(:final kind) when kind.readOnly) {
      return Future.error(SyncStateReadOnlyException(_file.path, kind));
    }

    // The stores build their bodies; none may shadow the version.
    assert(!body.containsKey(_versionKey), 'the body holds "$_versionKey"');
    final bytes = utf8.encode(
      jsonEncode({_versionKey: syncStateSchemaVersion, ...body}),
    );
    final generation = ++_queuedWrites;
    _unsaved = true;
    final write = _tail.then((_) => _writer(_file, bytes));
    // Each caller gets its own write's failure; the queue itself moves on.
    // Only the latest write's success clears the flag: it carries every
    // earlier change, while an earlier success says nothing of later ones.
    _tail = write.then<void>((_) {
      if (generation == _queuedWrites) _unsaved = false;
    }, onError: (Object _) {});
    return write;
  }
}

/// The strings of [body]'s [key], or a [FormatException] when it is not a
/// list of non-empty strings; an absent key is an empty list.
List<String> decodeStringList(Map<String, Object?> body, String key) =>
    switch (body[key]) {
      null => const [],
      final List<Object?> list => [
        for (final item in list)
          if (item is String && item.isNotEmpty)
            item
          else
            throw FormatException('$key holds a value that is not a name'),
      ],
      _ => throw FormatException('$key is not a list'),
    };
