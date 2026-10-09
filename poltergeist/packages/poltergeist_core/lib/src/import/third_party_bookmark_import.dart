/// Bounded, credential-safe bookmark import for FileZilla, WinSCP, and
/// Cyberduck (D22; 07 §3.13).
///
/// Parsing stays in core while file access stays in the app: callers provide
/// immutable byte snapshots, receive a complete preview, and persist only the
/// rows the user confirms. Saved passwords are never deobfuscated, surfaced,
/// returned, or persisted.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_core/seance_core.dart';
import 'package:xml/xml.dart';

import '../bookmarks/bookmark_store.dart' show BookmarkSyncTuple;
import '_bookmark_import_dedupe.dart';

part '_cyberduck_bookmark_parser.dart';
part '_file_zilla_bookmark_parser.dart';
part '_win_scp_bookmark_parser.dart';

const int _defaultSshPort = 22;
const int _minimumPort = 1;
const int _maximumPort = 65535;
const String _defaultRemotePath = '/';
const int _maximumImportLabelCodeUnits = 512;
const int _maximumImportHostCodeUnits = 1024;
const int _maximumImportUsernameCodeUnits = 256;
const int _maximumImportPathCodeUnits = 4096;
const int _maximumImportProtocolCodeUnits = 64;
const int _maximumImportSourceNameCodeUnits = 512;
const int _maximumImportPortCodeUnits = 16;
const String _fallbackImportSourceName = '?';
const int _sortKeyAlphabetSize = 26;
const int _sortKeyFirstCodeUnit = 0x61;
const int _importedSortKeyRowDigits = 3;
const int _importedSortKeyCollisionDigits = 4;
const int _importedSortKeyEscapeDigits = 4;
const int _importedSortKeyRowCapacity =
    _sortKeyAlphabetSize * _sortKeyAlphabetSize * _sortKeyAlphabetSize;
const int _importedSortKeyCollisionCapacity =
    _sortKeyAlphabetSize *
    _sortKeyAlphabetSize *
    _sortKeyAlphabetSize *
    _sortKeyAlphabetSize;
const String _importedSortKeyPrefix = 'm';
const String _importedSortKeyTerminator = 'y';
const String _importedSortKeyIdentityEscape = 'z';
const String _invalidImportCharacterReplacement = '\uFFFD';
const int _jsonListSeparatorBytes = 1;
const String _persistedOutputProjectionDeviceId =
    '00000000-0000-4000-8000-000000000000';
const Set<String> _unsupportedIdentityFileExtensions = {'.ppk', '.pub'};
final RegExp _importHostWhitespace = RegExp(r'\s', unicode: true);
final RegExp _asciiDecimalPort = RegExp(r'^[0-9]+$');
final RegExp _unsafeImportControl = RegExp(
  r'[\u0000-\u001F\u007F-\u009F\u061C\u200E\u200F\u2028-\u202E\u2066-\u2069]',
);
final DateTime _persistedOutputProjectionTime = DateTime.utc(
  9999,
  12,
  31,
  23,
  59,
  59,
  999,
  999,
);
final int _persistedOutputProjectionEnvelopeBytes = utf8
    .encode(jsonEncode({'syncTuples': const <String, Object?>{}}))
    .length;

/// Import bounds keep a user-selected file from becoming an unbounded parse.
const int thirdPartyBookmarkImportMaxFiles = 4096;
const int thirdPartyBookmarkImportMaxFileBytes = 8 * 1024 * 1024;
const int thirdPartyBookmarkImportMaxTotalBytes = 32 * 1024 * 1024;
const int thirdPartyBookmarkImportMaxRows = 10000;

/// Aggregate UTF-8 JSON budget for every row that remains selectable. Matching
/// the single-file input cap prevents compact exports from amplifying writes.
const int thirdPartyBookmarkImportMaxProjectedPersistedBytes = 8 * 1024 * 1024;

/// The third-party export format selected by the user.
enum ThirdPartyBookmarkFormat { fileZilla, winScp, cyberduck }

/// Whether [ThirdPartyBookmarkImportRow.protocol] is a recognized technical
/// identifier or an opaque/missing source token that the app must localize.
enum ThirdPartyBookmarkProtocolVerdict { known, unknown }

/// A preview warning attached to one imported row.
enum ThirdPartyBookmarkImportIssue {
  unsupportedProtocol,
  invalidPort,
  missingHost,
  credentialsNotImported,
  routeNotImported,
  invalidRemotePath,
  unsupportedKeyFormat,
  fieldTooLong,
  invalidFieldValue,
  persistedOutputLimitExceeded,
}

/// Why an entire import could not produce a trustworthy preview.
enum ThirdPartyBookmarkImportFailure {
  tooManyFiles,
  fileTooLarge,
  totalSizeExceeded,
  invalidEncoding,
  unsafeXml,
  malformedSource,
  tooManyRows,
}

/// A fatal import error. Entry-level problems remain visible as disabled rows.
final class ThirdPartyBookmarkImportException implements Exception {
  final ThirdPartyBookmarkImportFailure failure;
  final String? sourceName;

  const ThirdPartyBookmarkImportException(this.failure, {this.sourceName});

  @override
  String toString() {
    final source = sourceName;
    if (source == null) {
      return 'ThirdPartyBookmarkImportException(${failure.name})';
    }

    return 'ThirdPartyBookmarkImportException(${failure.name}, $source)';
  }
}

/// One user-selected export file, copied so the preview cannot change beneath
/// the user's selection while a picker buffer is reused.
final class ThirdPartyBookmarkImportFile {
  final String name;
  final Uint8List bytes;

  ThirdPartyBookmarkImportFile(String name, List<int> bytes)
    : name = ThirdPartyBookmarkImportFile.normalizeName(name),
      bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  /// Applies the same bounded, control-safe filename policy used by the
  /// constructor so picker preflight can render a safe name before copying.
  static String normalizeName(String name) => _normalizeImportSourceName(name);
}

/// One source entry plus the safety and dedupe verdicts shown in the preview.
final class ThirdPartyBookmarkImportRow {
  final String id;
  final String label;
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;
  final String? identityFilePath;
  final String remotePath;
  final String protocol;
  final ThirdPartyBookmarkProtocolVerdict protocolVerdict;
  final String sourceName;
  final String _sortKey;
  final List<ThirdPartyBookmarkImportIssue> issues;
  final String? existingBookmarkLabel;
  final String? earlierImportRowLabel;

  /// Whether a saved bookmark already reaches this destination; its label
  /// is [existingBookmarkLabel] (an empty label still counts).
  bool get matchesExistingBookmark => existingBookmarkLabel != null;

  /// Whether an earlier row of this import already reaches this
  /// destination; its label is [earlierImportRowLabel].
  bool get matchesEarlierImportRow => earlierImportRowLabel != null;

  const ThirdPartyBookmarkImportRow._({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    required this.identityFilePath,
    required this.remotePath,
    required this.protocol,
    required this.protocolVerdict,
    required this.sourceName,
    required String importSortKey,
    required this.issues,
    this.existingBookmarkLabel,
    this.earlierImportRowLabel,
  }) : _sortKey = importSortKey;

  /// Host and port as rendered by the common import table.
  String get endpoint {
    final displayHost =
        host.contains(':') && !(host.startsWith('[') && host.endsWith(']'))
        ? '[$host]'
        : host;
    if (issues.contains(ThirdPartyBookmarkImportIssue.invalidPort)) {
      return displayHost;
    }

    return '$displayHost:$port';
  }

  bool get importable =>
      !issues.contains(ThirdPartyBookmarkImportIssue.unsupportedProtocol) &&
      !issues.contains(ThirdPartyBookmarkImportIssue.invalidPort) &&
      !issues.contains(ThirdPartyBookmarkImportIssue.missingHost) &&
      !issues.contains(ThirdPartyBookmarkImportIssue.unsupportedKeyFormat) &&
      !issues.contains(ThirdPartyBookmarkImportIssue.fieldTooLong) &&
      !issues.contains(ThirdPartyBookmarkImportIssue.invalidFieldValue) &&
      !issues.contains(
        ThirdPartyBookmarkImportIssue.persistedOutputLimitExceeded,
      );

  bool get importByDefault =>
      importable &&
      !matchesExistingBookmark &&
      !matchesEarlierImportRow &&
      !issues.contains(ThirdPartyBookmarkImportIssue.routeNotImported);

  ThirdPartyBookmarkImportRow _withIssue(ThirdPartyBookmarkImportIssue issue) {
    final updatedIssues = {...issues, issue}.toList()
      ..sort((left, right) => left.index.compareTo(right.index));

    return _copyWith(issues: List.unmodifiable(updatedIssues));
  }

  ThirdPartyBookmarkImportRow _withEarlierImportRow(String label) =>
      _copyWith(earlierImportRowLabel: label);

  ThirdPartyBookmarkImportRow _copyWith({
    List<ThirdPartyBookmarkImportIssue>? issues,
    String? earlierImportRowLabel,
  }) {
    return ThirdPartyBookmarkImportRow._(
      id: id,
      label: label,
      host: host,
      port: port,
      username: username,
      authMethod: authMethod,
      identityFilePath: identityFilePath,
      remotePath: remotePath,
      protocol: protocol,
      protocolVerdict: protocolVerdict,
      sourceName: sourceName,
      importSortKey: _sortKey,
      issues: issues ?? this.issues,
      existingBookmarkLabel: existingBookmarkLabel,
      earlierImportRowLabel:
          earlierImportRowLabel ?? this.earlierImportRowLabel,
    );
  }

  /// Builds a reference-only bookmark. Passwords are prompted later and key
  /// paths are stored verbatim; import never reads either credential. The
  /// bounded default sort key avoids persistence-time key expansion.
  Bookmark toBookmark({required DateTime now}) {
    if (!importable) {
      throw StateError('Row "$label" cannot be imported');
    }

    return Bookmark(
      id: id,
      kind: BookmarkKind.remotePath,
      label: label,
      server: BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: host,
          port: port,
          username: username,
          authMethod: authMethod,
          identityFilePath: identityFilePath,
        ),
      ),
      remotePath: remotePath,
      sortKey: _sortKey,
      createdAt: now,
      updatedAt: now,
    );
  }
}

/// The complete, immutable import preview.
final class ThirdPartyBookmarkImportPreview {
  final List<ThirdPartyBookmarkImportRow> rows;

  ThirdPartyBookmarkImportPreview._(List<ThirdPartyBookmarkImportRow> rows)
    : rows = List.unmodifiable(rows);
}

/// Parses third-party exports and applies one dedupe rule across all formats.
final class ThirdPartyBookmarkImportService {
  final String Function() mintId;

  const ThirdPartyBookmarkImportService({required this.mintId});

  ThirdPartyBookmarkImportPreview loadPreview({
    required ThirdPartyBookmarkFormat format,
    required Iterable<ThirdPartyBookmarkImportFile> files,
    Iterable<Bookmark> existingBookmarks = const [],
  }) {
    final input = _boundedFiles(files);
    final drafts = <_ThirdPartyBookmarkDraft>[];

    for (final file in input) {
      final remainingRows = thirdPartyBookmarkImportMaxRows - drafts.length;
      drafts.addAll(_parseFile(format, file, remainingRows));
    }

    // Snapshot once because callers may provide a one-shot database iterable.
    final existing = List<Bookmark>.of(existingBookmarks, growable: false);
    final existingDestinations = existingBookmarkImportDestinations(existing);
    final sortKeyMinter = _ImportedBookmarkSortKeyMinter(
      existing.map((bookmark) => bookmark.sortKey),
    );
    final candidates = <_ThirdPartyBookmarkCandidate>[];

    for (final draft in drafts) {
      final id = mintId();
      final comparableEndpoint =
          !draft.issues.contains(ThirdPartyBookmarkImportIssue.missingHost) &&
          !draft.issues.contains(ThirdPartyBookmarkImportIssue.invalidPort) &&
          !draft.issues.contains(ThirdPartyBookmarkImportIssue.fieldTooLong) &&
          !draft.issues.contains(
            ThirdPartyBookmarkImportIssue.invalidFieldValue,
          );
      final destination = comparableEndpoint
          ? bookmarkImportDestinationKey(
              draft.host,
              draft.port,
              draft.username,
              draft.remotePath,
            )
          : null;
      final existingLabel = destination == null
          ? null
          : existingDestinations[destination];
      final issues = draft.issues.toList();

      final row = ThirdPartyBookmarkImportRow._(
        id: id,
        label: draft.label,
        host: draft.host,
        port: draft.port,
        username: draft.username,
        authMethod: draft.authMethod,
        identityFilePath: draft.identityFilePath,
        remotePath: draft.remotePath,
        protocol: draft.protocol,
        protocolVerdict: draft.protocolVerdict,
        sourceName: draft.sourceName,
        importSortKey: sortKeyMinter.mint(
          rowIndex: candidates.length,
          rowId: id,
        ),
        issues: List.unmodifiable(
          issues..sort((left, right) => left.index.compareTo(right.index)),
        ),
        existingBookmarkLabel: existingLabel,
      );
      candidates.add(_ThirdPartyBookmarkCandidate(row, destination));
    }

    return ThirdPartyBookmarkImportPreview._(
      _applyProjectedPersistedBudget(candidates),
    );
  }

  List<ThirdPartyBookmarkImportFile> _boundedFiles(
    Iterable<ThirdPartyBookmarkImportFile> files,
  ) {
    final result = <ThirdPartyBookmarkImportFile>[];
    var totalBytes = 0;

    for (final file in files) {
      if (result.length >= thirdPartyBookmarkImportMaxFiles) {
        throw const ThirdPartyBookmarkImportException(
          ThirdPartyBookmarkImportFailure.tooManyFiles,
        );
      }
      if (file.bytes.length > thirdPartyBookmarkImportMaxFileBytes) {
        throw ThirdPartyBookmarkImportException(
          ThirdPartyBookmarkImportFailure.fileTooLarge,
          sourceName: file.name,
        );
      }

      totalBytes += file.bytes.length;
      if (totalBytes > thirdPartyBookmarkImportMaxTotalBytes) {
        throw const ThirdPartyBookmarkImportException(
          ThirdPartyBookmarkImportFailure.totalSizeExceeded,
        );
      }
      result.add(file);
    }

    return result;
  }

  List<_ThirdPartyBookmarkDraft> _parseFile(
    ThirdPartyBookmarkFormat format,
    ThirdPartyBookmarkImportFile file,
    int rowLimit,
  ) {
    switch (format) {
      case ThirdPartyBookmarkFormat.fileZilla:
        return _parseFileZilla(file, rowLimit);
      case ThirdPartyBookmarkFormat.winScp:
        return _parseWinScp(file, rowLimit);
      case ThirdPartyBookmarkFormat.cyberduck:
        return _parseCyberduck(file, rowLimit);
    }
  }
}

final class _ImportedBookmarkSortKeyMinter {
  final Set<String> _usedSortKeys;

  _ImportedBookmarkSortKeyMinter(Iterable<String> usedSortKeys)
    : _usedSortKeys = {...usedSortKeys};

  String mint({required int rowIndex, required String rowId}) {
    if (rowIndex < 0 || rowIndex >= _importedSortKeyRowCapacity) {
      throw StateError('import sort-key row capacity exceeded');
    }

    // Row order leads; the globally unique record id makes stale previews
    // distinct without randomness. The terminator prevents prefix neighbors.
    final prefix =
        '$_importedSortKeyPrefix'
        '${_encodeBase26(rowIndex, _importedSortKeyRowDigits)}'
        '${_encodeSortKeyIdentity(rowId)}';
    for (
      var collision = 0;
      collision < _importedSortKeyCollisionCapacity;
      collision++
    ) {
      final sortKey =
          '$prefix'
          '${_encodeBase26(collision, _importedSortKeyCollisionDigits)}'
          '$_importedSortKeyTerminator';

      if (_usedSortKeys.add(sortKey)) return sortKey;
    }

    throw StateError('import sort-key capacity exceeded');
  }
}

String _encodeSortKeyIdentity(String id) {
  final encoded = StringBuffer();

  for (final codeUnit in id.codeUnits) {
    final compactIndex = _compactSortKeyIdentityIndex(codeUnit);
    if (compactIndex >= 0) {
      encoded.writeCharCode(_sortKeyFirstCodeUnit + compactIndex);
      continue;
    }

    encoded
      ..write(_importedSortKeyIdentityEscape)
      ..write(_encodeBase26(codeUnit, _importedSortKeyEscapeDigits));
  }
  encoded.write(_importedSortKeyTerminator);

  return encoded.toString();
}

int _compactSortKeyIdentityIndex(int codeUnit) {
  const digitZero = 0x30;
  const digitNine = 0x39;
  const lowercaseA = 0x61;
  const lowercaseF = 0x66;
  const hyphen = 0x2D;
  const compactLetterOffset = 10;
  const compactHyphenIndex = 16;

  if (codeUnit >= digitZero && codeUnit <= digitNine) {
    return codeUnit - digitZero;
  }
  if (codeUnit >= lowercaseA && codeUnit <= lowercaseF) {
    return compactLetterOffset + codeUnit - lowercaseA;
  }
  if (codeUnit == hyphen) return compactHyphenIndex;

  return switch (codeUnit) {
    0x69 => 17, // i
    0x6D => 18, // m
    0x6F => 19, // o
    0x70 => 20, // p
    0x72 => 21, // r
    0x73 => 22, // s
    0x74 => 23, // t
    _ => -1,
  };
}

String _encodeBase26(int value, int width) {
  var remainder = value;
  final digits = List<int>.filled(width, _sortKeyFirstCodeUnit);
  for (var position = digits.length - 1; position >= 0; position--) {
    digits[position] = _sortKeyFirstCodeUnit + remainder % _sortKeyAlphabetSize;
    remainder ~/= _sortKeyAlphabetSize;
  }
  if (remainder != 0) throw StateError('sort-key value exceeds width');

  return String.fromCharCodes(digits);
}

List<ThirdPartyBookmarkImportRow> _applyProjectedPersistedBudget(
  List<_ThirdPartyBookmarkCandidate> candidates,
) {
  var projectedPersistedBytes = _persistedOutputProjectionEnvelopeBytes;

  bool reserve(int index) {
    final candidate = candidates[index];
    final row = candidate.row;
    final projectedRowBytes = _projectedPersistedBytes(row);
    final remainingBytes =
        thirdPartyBookmarkImportMaxProjectedPersistedBytes -
        projectedPersistedBytes;
    if (projectedRowBytes > remainingBytes) {
      candidate.row = row._withIssue(
        ThirdPartyBookmarkImportIssue.persistedOutputLimitExceeded,
      );
      return false;
    }

    projectedPersistedBytes += projectedRowBytes;
    return true;
  }

  final defaultIndexes = <int>{};
  final defaultByDestination = <String, ({int index, String label})>{};

  // Budget the first fitting safe row per destination before manual choices.
  for (var index = 0; index < candidates.length; index++) {
    final candidate = candidates[index];
    final destination = candidate.destination;
    if (!candidate.row.importByDefault || destination == null) continue;
    if (defaultByDestination.containsKey(destination)) continue;
    if (!reserve(index)) continue;

    defaultIndexes.add(index);
    defaultByDestination[destination] = (
      index: index,
      label: candidate.row.label,
    );
  }

  for (var index = 0; index < candidates.length; index++) {
    final candidate = candidates[index];
    final destination = candidate.destination;
    final representative = destination == null
        ? null
        : defaultByDestination[destination];
    if (representative == null || representative.index >= index) continue;

    candidate.row = candidate.row._withEarlierImportRow(representative.label);
  }

  for (var index = 0; index < candidates.length; index++) {
    if (defaultIndexes.contains(index)) continue;
    if (!candidates[index].row.importable) continue;

    reserve(index);
  }

  return [for (final candidate in candidates) candidate.row];
}

int _projectedPersistedBytes(ThirdPartyBookmarkImportRow row) {
  final bookmark = row.toBookmark(now: _persistedOutputProjectionTime);
  final bookmarkBytes = utf8.encode(jsonEncode(bookmark.toJson())).length;
  final syncTuple = BookmarkSyncTuple(
    updatedAt: _persistedOutputProjectionTime.millisecondsSinceEpoch,
    deviceId: _persistedOutputProjectionDeviceId,
  );
  final syncTupleBytes = utf8
      .encode(jsonEncode({row.id: syncTuple.toJson()}))
      .length;

  // Per-entry map braces overcount enrolled stores' shared tuple map.
  return bookmarkBytes + _jsonListSeparatorBytes + syncTupleBytes;
}

void _requireImportRowCapacity(int rowCount, int rowLimit, String sourceName) {
  if (rowCount < rowLimit) return;

  throw ThirdPartyBookmarkImportException(
    ThirdPartyBookmarkImportFailure.tooManyRows,
    sourceName: sourceName,
  );
}

final class _ThirdPartyBookmarkCandidate {
  ThirdPartyBookmarkImportRow row;
  final String? destination;

  _ThirdPartyBookmarkCandidate(this.row, this.destination);
}

final class _ThirdPartyBookmarkDraft {
  final String label;
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;
  final String? identityFilePath;
  final String remotePath;
  final String protocol;
  final ThirdPartyBookmarkProtocolVerdict protocolVerdict;
  final String sourceName;
  final Set<ThirdPartyBookmarkImportIssue> issues;
  final Set<ThirdPartyBookmarkImportIssue> issuesWithoutRemotePath;
  final Set<ThirdPartyBookmarkImportIssue> remotePathIssues;

  const _ThirdPartyBookmarkDraft({
    required this.label,
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    required this.identityFilePath,
    required this.remotePath,
    required this.protocol,
    required this.protocolVerdict,
    required this.sourceName,
    required this.issues,
    required this.issuesWithoutRemotePath,
    required this.remotePathIssues,
  });
}

_ThirdPartyBookmarkDraft _draft({
  required String sourceName,
  required String label,
  required String host,
  required String? rawPort,
  required String username,
  required String protocol,
  required ThirdPartyBookmarkProtocolVerdict protocolVerdict,
  required _ProtocolSupport protocolSupport,
  required String? identityFilePath,
  required _RemotePath remotePath,
  _RouteSupport routeSupport = _RouteSupport.direct,
  Iterable<ThirdPartyBookmarkImportIssue> sourceIssues = const [],
}) {
  final normalizedHost = host.trim();
  final boundedHost = _boundImportText(
    normalizedHost,
    _maximumImportHostCodeUnits,
  );
  final normalizedPort = rawPort?.trim();
  final boundedPort = _boundImportText(
    normalizedPort ?? '',
    _maximumImportPortCodeUnits,
  );
  final parsedPort = boundedPort.issues.isEmpty
      ? _parsePort(normalizedPort)
      : (port: 0, valid: false);
  final normalizedUsername = username.trim();
  final boundedUsername = _boundImportText(
    normalizedUsername,
    _maximumImportUsernameCodeUnits,
  );
  final keyPath = identityFilePath;
  final hasKey = keyPath != null && keyPath.trim().isNotEmpty;
  final boundedKeyPath = _boundImportText(
    keyPath ?? '',
    _maximumImportPathCodeUnits,
  );
  final unsupportedKeyFormat =
      hasKey &&
      boundedKeyPath.issues.isEmpty &&
      _hasUnsupportedKeyFormat(keyPath);
  final validHost = _isValidImportHost(normalizedHost);
  final fallbackLabel = normalizedHost.isEmpty ? sourceName : normalizedHost;
  final normalizedLabel = label.trim().isEmpty ? fallbackLabel : label.trim();
  final boundedLabel = _boundImportText(
    normalizedLabel,
    _maximumImportLabelCodeUnits,
  );
  final boundedProtocol = _boundImportText(
    protocol,
    _maximumImportProtocolCodeUnits,
  );
  final boundedSourceName = _boundImportText(
    sourceName,
    _maximumImportSourceNameCodeUnits,
  );
  final boundedRemotePath = _boundImportRemotePath(remotePath);
  final issuesWithoutRemotePath = <ThirdPartyBookmarkImportIssue>{
    ...sourceIssues,
    ...boundedLabel.issues,
    ...boundedHost.issues,
    ...boundedPort.issues,
    ...boundedUsername.issues,
    ...boundedKeyPath.issues,
    ...boundedProtocol.issues,
    ...boundedSourceName.issues,
    if (protocolSupport == _ProtocolSupport.unsupported)
      ThirdPartyBookmarkImportIssue.unsupportedProtocol,
    if (!parsedPort.valid) ThirdPartyBookmarkImportIssue.invalidPort,
    if (!validHost) ThirdPartyBookmarkImportIssue.missingHost,
    if (!hasKey) ThirdPartyBookmarkImportIssue.credentialsNotImported,
    if (routeSupport == _RouteSupport.notImported)
      ThirdPartyBookmarkImportIssue.routeNotImported,
    if (unsupportedKeyFormat)
      ThirdPartyBookmarkImportIssue.unsupportedKeyFormat,
  };
  final remotePathIssues = boundedRemotePath.issues;
  final issues = <ThirdPartyBookmarkImportIssue>{
    ...issuesWithoutRemotePath,
    ...remotePathIssues,
  };

  return _ThirdPartyBookmarkDraft(
    label: boundedLabel.value,
    host: boundedHost.value,
    port: parsedPort.port,
    username: boundedUsername.value,
    authMethod: hasKey ? AuthMethod.privateKey : AuthMethod.password,
    identityFilePath: hasKey ? boundedKeyPath.value : null,
    remotePath: boundedRemotePath.path,
    protocol: boundedProtocol.value,
    protocolVerdict: protocolVerdict,
    sourceName: boundedSourceName.value,
    issues: Set.unmodifiable(issues),
    issuesWithoutRemotePath: Set.unmodifiable(issuesWithoutRemotePath),
    remotePathIssues: Set.unmodifiable(remotePathIssues),
  );
}

final class _BoundedImportText {
  final String value;
  final Set<ThirdPartyBookmarkImportIssue> issues;

  const _BoundedImportText(this.value, this.issues);
}

_BoundedImportText _boundImportText(String value, int maximumCodeUnits) {
  final tooLong = value.length > maximumCodeUnits;
  final invalid = _unsafeImportControl.hasMatch(value);
  if (!tooLong && !invalid) {
    return _BoundedImportText(value, const {});
  }

  var end = tooLong ? maximumCodeUnits : value.length;
  if (end > 0 &&
      end < value.length &&
      _isHighSurrogate(value.codeUnitAt(end - 1)) &&
      _isLowSurrogate(value.codeUnitAt(end))) {
    end--;
  }
  final bounded = value
      .substring(0, end)
      .replaceAll(_unsafeImportControl, _invalidImportCharacterReplacement);

  return _BoundedImportText(bounded, {
    if (tooLong) ThirdPartyBookmarkImportIssue.fieldTooLong,
    if (invalid) ThirdPartyBookmarkImportIssue.invalidFieldValue,
  });
}

String _normalizeImportSourceName(String sourceName) {
  final normalized = sourceName.trim();
  if (normalized.isEmpty) return _fallbackImportSourceName;

  final bounded = _boundImportText(
    normalized,
    _maximumImportSourceNameCodeUnits,
  ).value;
  final meaningful = bounded
      .replaceAll(_invalidImportCharacterReplacement, '')
      .trim();
  return meaningful.isEmpty ? _fallbackImportSourceName : bounded;
}

_BoundedImportText _appendImportLabelSegment(
  _BoundedImportText prefix,
  String segment,
) {
  if (segment.isEmpty) return prefix;
  if (prefix.issues.contains(ThirdPartyBookmarkImportIssue.fieldTooLong)) {
    return prefix;
  }

  final separatorLength = prefix.value.isEmpty ? 0 : 1;
  final remaining =
      _maximumImportLabelCodeUnits - prefix.value.length - separatorLength;
  if (remaining <= 0) {
    return _BoundedImportText(prefix.value, {
      ...prefix.issues,
      ThirdPartyBookmarkImportIssue.fieldTooLong,
    });
  }

  final bounded = _boundImportText(segment, remaining);
  if (bounded.value.isEmpty) {
    return _BoundedImportText(prefix.value, {
      ...prefix.issues,
      ...bounded.issues,
    });
  }

  final separator = separatorLength == 0 ? '' : '/';
  return _BoundedImportText('${prefix.value}$separator${bounded.value}', {
    ...prefix.issues,
    ...bounded.issues,
  });
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

bool _isValidImportHost(String host) {
  if (host.isEmpty || _importHostWhitespace.hasMatch(host)) return false;

  for (final codeUnit in host.codeUnits) {
    if (codeUnit <= 0x20 || codeUnit == 0x7F) return false;
  }
  return true;
}

bool _hasUnsupportedKeyFormat(String path) {
  final normalized = path.trim().toLowerCase();
  return _unsupportedIdentityFileExtensions.any(normalized.endsWith);
}

enum _ProtocolSupport { supported, unsupported }

enum _RouteSupport { direct, notImported }

({int port, bool valid}) _parsePort(String? rawPort) {
  if (rawPort == null || rawPort.trim().isEmpty) {
    return (port: _defaultSshPort, valid: true);
  }

  final normalized = rawPort.trim();
  if (!_asciiDecimalPort.hasMatch(normalized)) {
    return (port: 0, valid: false);
  }

  final port = int.tryParse(normalized, radix: 10);
  if (port == null || port < _minimumPort || port > _maximumPort) {
    return (port: 0, valid: false);
  }

  return (port: port, valid: true);
}

final class _RemotePath {
  final String path;
  final _RemotePathVerdict verdict;

  const _RemotePath(this.path, this.verdict);
}

enum _RemotePathVerdict { valid, invalid }

final class _BoundedImportRemotePath {
  final String path;
  final Set<ThirdPartyBookmarkImportIssue> issues;

  const _BoundedImportRemotePath(this.path, this.issues);
}

_BoundedImportRemotePath _boundImportRemotePath(_RemotePath remotePath) {
  if (remotePath.verdict == _RemotePathVerdict.invalid) {
    return const _BoundedImportRemotePath(_defaultRemotePath, {
      ThirdPartyBookmarkImportIssue.invalidRemotePath,
    });
  }

  final bounded = _boundImportText(
    remotePath.path,
    _maximumImportPathCodeUnits,
  );
  if (bounded.issues.isEmpty) {
    return _BoundedImportRemotePath(bounded.value, const {});
  }

  return _BoundedImportRemotePath(_defaultRemotePath, {
    ...bounded.issues,
    ThirdPartyBookmarkImportIssue.invalidRemotePath,
  });
}

_RemotePath _remotePath(String? rawPath) {
  if (rawPath == null || rawPath.isEmpty) {
    return const _RemotePath(_defaultRemotePath, _RemotePathVerdict.valid);
  }
  if (!rawPath.startsWith('/') || _unsafeImportControl.hasMatch(rawPath)) {
    return const _RemotePath(_defaultRemotePath, _RemotePathVerdict.invalid);
  }

  return _RemotePath(rawPath, _RemotePathVerdict.valid);
}

String _decodeText(ThirdPartyBookmarkImportFile file) {
  final bytes = file.bytes;
  try {
    if (_startsWith(bytes, const [0xEF, 0xBB, 0xBF])) {
      return utf8.decode(bytes.sublist(3), allowMalformed: false);
    }
    if (_startsWith(bytes, const [0xFF, 0xFE])) {
      return _decodeUtf16(bytes, file.name, _ByteOrder.littleEndian);
    }
    if (_startsWith(bytes, const [0xFE, 0xFF])) {
      return _decodeUtf16(bytes, file.name, _ByteOrder.bigEndian);
    }

    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw ThirdPartyBookmarkImportException(
      ThirdPartyBookmarkImportFailure.invalidEncoding,
      sourceName: file.name,
    );
  }
}

enum _ByteOrder { littleEndian, bigEndian }

String _decodeUtf16(Uint8List bytes, String sourceName, _ByteOrder byteOrder) {
  if ((bytes.length - 2).isOdd) {
    throw ThirdPartyBookmarkImportException(
      ThirdPartyBookmarkImportFailure.invalidEncoding,
      sourceName: sourceName,
    );
  }

  int readCodeUnit(int index) {
    final first = bytes[index];
    final second = bytes[index + 1];
    return byteOrder == _ByteOrder.littleEndian
        ? first | (second << 8)
        : (first << 8) | second;
  }

  Never invalidEncoding() => throw ThirdPartyBookmarkImportException(
    ThirdPartyBookmarkImportFailure.invalidEncoding,
    sourceName: sourceName,
  );

  final codeUnits = <int>[];
  var index = 2;
  while (index < bytes.length) {
    final codeUnit = readCodeUnit(index);
    if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) invalidEncoding();
    if (codeUnit < 0xD800 || codeUnit > 0xDBFF) {
      codeUnits.add(codeUnit);
      index += 2;
      continue;
    }

    if (index + 3 >= bytes.length) invalidEncoding();
    final lowSurrogate = readCodeUnit(index + 2);
    if (lowSurrogate < 0xDC00 || lowSurrogate > 0xDFFF) invalidEncoding();

    codeUnits
      ..add(codeUnit)
      ..add(lowSurrogate);
    index += 4;
  }
  return String.fromCharCodes(codeUnits);
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;

  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}

XmlDocument _parseXml(ThirdPartyBookmarkImportFile file) {
  final text = _decodeText(file);
  if (RegExp(r'<!\s*ENTITY\b', caseSensitive: false).hasMatch(text)) {
    throw ThirdPartyBookmarkImportException(
      ThirdPartyBookmarkImportFailure.unsafeXml,
      sourceName: file.name,
    );
  }

  try {
    final document = XmlDocument.parse(text);
    document.rootElement;
    return document;
  } on XmlException {
    throw ThirdPartyBookmarkImportException(
      ThirdPartyBookmarkImportFailure.malformedSource,
      sourceName: file.name,
    );
  } on StateError {
    throw ThirdPartyBookmarkImportException(
      ThirdPartyBookmarkImportFailure.malformedSource,
      sourceName: file.name,
    );
  }
}
