import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';

/// The path grammar used by one trash side.
enum SyncTrashPathStyle { posix, windows }

/// Whether that side distinguishes path case.
enum SyncTrashPathCase { sensitive, insensitive }

/// Whether a caller may create or adopt an unmarked trash directory.
enum SyncTrashRootAccess { openExisting, createOrClaim }

/// The fixed ownership-marker directory. Its random identity file identifies
/// the physical root across endpoint aliases without exposing credentials.
const String syncTrashRootMarkerName = '.poltergeist-root';

const String _markerPrefix = 'poltergeist-sync-trash-v1:';
const String _markerIdentityName = 'identity';
const String _markerCandidateSeparator = '.init-';
const int _markerRandomBytes = 16;
const int _maxMarkerBytes = 128;
const int _privateDirectoryMode = 0x1C0; // 0700

final RegExp _markerPattern = RegExp(
  '^${RegExp.escape(_markerPrefix)}([0-9a-f]{32})\\n?\$',
);
final RegExp _syncRunPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{8}-[0-9a-f]{4}-'
  r'4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final RegExp _rsyncRunPattern = RegExp(r'^rsync-[0-9]{8}-[0-9]{6}$');
final RegExp _trashIdentityKeyPattern = RegExp(r'^[0-9a-f]{64}$');

/// A validated marker and canonical directory identity.
final class SyncTrashRootIdentity {
  const SyncTrashRootIdentity({
    required this.canonicalRoot,
    required this.rootId,
  });

  final String canonicalRoot;
  final String rootId;

  /// Stable journal and lock identity shared by aliases of this root.
  String get scopeKey => sha256
      .convert(utf8.encode('poltergeist-sync-trash\u0000$rootId'))
      .toString();
}

/// Opens an owned root, or safely claims a dedicated legacy/new directory.
///
/// Adoption refuses filesystem roots and non-empty directories unless their
/// only occupants are valid interrupted marker claims. This prevents a custom
/// path such as `/` or `/tmp` from becoming an explicit-purge candidate.
Future<SyncTrashRootIdentity> resolveSyncTrashRoot(
  RemoteFileSystem fileSystem,
  String trashRoot, {
  required SyncTrashPathStyle pathStyle,
  required SyncTrashRootAccess access,
}) async {
  final context = syncTrashPathContext(pathStyle);
  final normalizedRoot = context.normalize(trashRoot);
  final markerPath = context.join(normalizedRoot, syncTrashRootMarkerName);
  var createdRoot = false;

  RemoteFileEntry? rootEntry;
  try {
    rootEntry = await fileSystem.stat(normalizedRoot, followLinks: false);
  } on RemoteFileException catch (error) {
    if (error.kind != RemoteFileErrorKind.notFound) rethrow;
  }

  if (rootEntry == null) {
    if (access == SyncTrashRootAccess.openExisting) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'open sync trash',
        path: normalizedRoot,
        message: 'Sync trash does not exist at "$normalizedRoot".',
      );
    }
    if (_isFileSystemRoot(context, normalizedRoot)) {
      throw _unsafeRoot(normalizedRoot);
    }

    createdRoot = await _createDirectoryChain(
      fileSystem,
      context,
      normalizedRoot,
    );
    rootEntry = await fileSystem.stat(normalizedRoot, followLinks: false);
  }

  if (!rootEntry.isDirectory) {
    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'open sync trash',
      path: normalizedRoot,
      message: '"$normalizedRoot" is not a directory.',
    );
  }
  if (_isFileSystemRoot(context, normalizedRoot)) {
    throw _unsafeRoot(normalizedRoot);
  }

  final existingMarker = await _markerEntry(fileSystem, markerPath);
  String rootId;
  if (existingMarker != null) {
    rootId = await _readMarker(fileSystem, context, markerPath);
  } else {
    if (access == SyncTrashRootAccess.openExisting) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'open sync trash',
        path: normalizedRoot,
        message: '"$normalizedRoot" is not owned by Poltergeist.',
      );
    }
    if (!createdRoot) {
      await _validateLegacyRoot(fileSystem, context, normalizedRoot);
    }
    await _makePrivate(fileSystem, normalizedRoot, pathStyle);
    rootId = await _claimMarker(fileSystem, context, markerPath, pathStyle);
  }

  final canonicalRoot = await fileSystem.canonicalize(normalizedRoot);
  return SyncTrashRootIdentity(
    canonicalRoot: context.normalize(canonicalRoot),
    rootId: rootId,
  );
}

/// True only for directory names created by sync or the rsync exporter.
bool isSyncTrashRunDirectoryName(String name) =>
    isSyncTrashRunId(name) || _rsyncRunPattern.hasMatch(name);

/// True only for `<device-prefix>-<uuid-v4>` sync run ids.
bool isSyncTrashRunId(String name) => _syncRunPattern.hasMatch(name);

/// True for marker scopes and endpoint/path slot keys derived from SHA-256.
bool isSyncTrashIdentityKey(String value) =>
    _trashIdentityKeyPattern.hasMatch(value);

p.Context syncTrashPathContext(SyncTrashPathStyle style) => p.Context(
  style: switch (style) {
    SyncTrashPathStyle.posix => p.Style.posix,
    SyncTrashPathStyle.windows => p.Style.windows,
  },
);

String normalizeSyncTrashPath(
  String path,
  SyncTrashPathStyle style,
  SyncTrashPathCase pathCase,
) {
  final normalized = syncTrashPathContext(style).normalize(path);
  return pathCase == SyncTrashPathCase.sensitive
      ? normalized
      : normalized.toLowerCase();
}

Future<RemoteFileEntry?> _markerEntry(
  RemoteFileSystem fileSystem,
  String markerPath,
) async {
  try {
    final entry = await fileSystem.stat(markerPath, followLinks: false);
    if (entry.isDirectory) return entry;

    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'open sync trash',
      path: markerPath,
      message: 'The sync-trash ownership marker is not a directory.',
    );
  } on RemoteFileException catch (error) {
    if (error.kind == RemoteFileErrorKind.notFound) return null;
    rethrow;
  }
}

Future<bool> _createDirectoryChain(
  RemoteFileSystem fileSystem,
  p.Context context,
  String path,
) async {
  final missing = <String>[];
  var createdTarget = false;
  var candidate = path;
  while (true) {
    try {
      final entry = await fileSystem.stat(candidate, followLinks: false);
      if (!entry.isDirectory) throw _unsafeRoot(path);
      break;
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound) rethrow;
    }

    missing.add(candidate);
    final parent = context.dirname(candidate);
    if (parent == candidate) throw _unsafeRoot(path);
    candidate = parent;
  }

  for (final directory in missing.reversed) {
    try {
      await fileSystem.createDirectory(directory);
      if (directory == path) createdTarget = true;
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.conflict) rethrow;
      final winner = await fileSystem.stat(directory, followLinks: false);
      if (!winner.isDirectory) throw _unsafeRoot(path);
    }
  }
  return createdTarget;
}

Future<void> _validateLegacyRoot(
  RemoteFileSystem fileSystem,
  p.Context context,
  String trashRoot,
) async {
  final children = await fileSystem.listDirectory(trashRoot);
  for (final child in children) {
    if (!child.isDirectory) throw _unsafeRoot(trashRoot);
    if (!child.name.startsWith(
      '$syncTrashRootMarkerName$_markerCandidateSeparator',
    )) {
      throw _unsafeRoot(trashRoot);
    }

    // A valid staged marker is evidence of an interrupted concurrent claim.
    await _readMarker(fileSystem, context, context.join(trashRoot, child.name));
  }
}

Future<String> _claimMarker(
  RemoteFileSystem fileSystem,
  p.Context context,
  String markerPath,
  SyncTrashPathStyle pathStyle,
) async {
  final rootId = secureRandomBytes(
    _markerRandomBytes,
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final candidatePath =
      '$markerPath$_markerCandidateSeparator${_randomHex(_markerRandomBytes)}';
  final identityPath = context.join(candidatePath, _markerIdentityName);
  final bytes = utf8.encode('$_markerPrefix$rootId\n');
  try {
    await fileSystem.createDirectory(candidatePath);
    await _makePrivate(fileSystem, candidatePath, pathStyle);
    await fileSystem.upload(
      identityPath,
      Stream<List<int>>.value(bytes),
      length: bytes.length,
      computeHash: false,
    );
    await fileSystem.rename(candidatePath, markerPath);
    return rootId;
  } on RemoteFileException catch (error) {
    final winner = await _markerEntry(fileSystem, markerPath);
    await _removeMarkerCandidate(fileSystem, candidatePath, identityPath);
    if (winner != null) return _readMarker(fileSystem, context, markerPath);
    if (error.kind != RemoteFileErrorKind.conflict) rethrow;
  }

  await _removeMarkerCandidate(fileSystem, candidatePath, identityPath);

  final winner = await _markerEntry(fileSystem, markerPath);
  if (winner == null) {
    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'claim sync trash',
      path: markerPath,
      message: 'The sync-trash ownership marker race had no winner.',
    );
  }
  return _readMarker(fileSystem, context, markerPath);
}

Future<String> _readMarker(
  RemoteFileSystem fileSystem,
  p.Context context,
  String markerPath,
) async {
  final identityPath = context.join(markerPath, _markerIdentityName);
  final RemoteFileEntry identity;
  try {
    identity = await fileSystem.stat(identityPath, followLinks: false);
  } on RemoteFileException {
    throw _invalidMarker(markerPath);
  }
  if (identity.type != RemoteFileType.file ||
      (identity.size != null && identity.size! > _maxMarkerBytes)) {
    throw _invalidMarker(markerPath);
  }

  final sink = _BoundedByteSink(_maxMarkerBytes);
  try {
    await fileSystem.download(identityPath, sink, computeHash: false);
  } on _MarkerTooLarge {
    throw _invalidMarker(markerPath);
  }
  final String decoded;
  try {
    decoded = utf8.decode(sink.bytes);
  } on FormatException {
    throw _invalidMarker(markerPath);
  }
  final match = _markerPattern.firstMatch(decoded);
  if (match == null) throw _invalidMarker(markerPath);
  return match.group(1)!;
}

Future<void> _removeMarkerCandidate(
  RemoteFileSystem fileSystem,
  String candidatePath,
  String identityPath,
) async {
  for (final path in [identityPath, candidatePath]) {
    try {
      final entry = await fileSystem.stat(path, followLinks: false);
      await fileSystem.delete(entry);
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound) return;
    }
  }
}

Future<void> _makePrivate(
  RemoteFileSystem fileSystem,
  String trashRoot,
  SyncTrashPathStyle pathStyle,
) async {
  try {
    await fileSystem.setMode(trashRoot, _privateDirectoryMode);
  } on RemoteFileException catch (error) {
    // Local VFS implementations may not express POSIX modes (notably on
    // Windows); Windows-style remotes have the same contract.
    final modeIsMeaningless =
        fileSystem is LocalFileSystem ||
        pathStyle == SyncTrashPathStyle.windows;
    if (modeIsMeaningless && error.kind == RemoteFileErrorKind.unsupported) {
      return;
    }
    rethrow;
  }
}

bool _isFileSystemRoot(p.Context context, String path) =>
    context.dirname(path) == path;

RemoteFileException _unsafeRoot(String path) => RemoteFileException(
  kind: RemoteFileErrorKind.conflict,
  operation: 'claim sync trash',
  path: path,
  message: '"$path" is not a dedicated Poltergeist trash directory.',
);

RemoteFileException _invalidMarker(String path) => RemoteFileException(
  kind: RemoteFileErrorKind.conflict,
  operation: 'open sync trash',
  path: path,
  message: 'The sync-trash ownership marker is invalid.',
);

String _randomHex(int bytes) => secureRandomBytes(
  bytes,
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

final class _MarkerTooLarge implements Exception {
  const _MarkerTooLarge();
}

final class _BoundedByteSink implements StreamSink<List<int>> {
  _BoundedByteSink(this.limit);

  final int limit;
  final List<int> bytes = <int>[];

  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) throw const _MarkerTooLarge();
    bytes.addAll(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => throw error;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();
}
