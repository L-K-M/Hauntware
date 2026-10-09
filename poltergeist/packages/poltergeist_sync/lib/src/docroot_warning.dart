import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'pair_id.dart';
import 'plan.dart';
import 'trash_root.dart';

const String _suggestionRoot = '~/.poltergeist-trash';
const int _maxSlugLength = 63;
const String _base32Alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
const Set<String> _docrootComponents = {'public_html', 'www', 'htdocs'};
final RegExp _windowsVolumeShape = RegExp(r'^(?:[a-zA-Z]:[/\\]|\\\\)');

/// One sync root whose allowed actions may create HTTP-accessible trash.
final class SyncDocrootWarning {
  const SyncDocrootWarning({
    required this.side,
    required this.rootPath,
    required this.suggestedTrashPath,
  });

  final SyncSide side;
  final String rootPath;
  final String suggestedTrashPath;
}

/// Canonical root and trash paths available after a side is scanned.
final class SyncDocrootPathState {
  const SyncDocrootPathState({
    required this.rootPath,
    required this.trashPath,
    required this.pathStyle,
    required this.pathCase,
  });

  final String rootPath;

  /// Null when the scan resolved the root but not the trash identity.
  final String? trashPath;
  final SyncTrashPathStyle pathStyle;

  /// The scanned root filesystem's case rule. Containment is decided at
  /// that boundary even when a custom trash path crosses filesystems.
  final SyncTrashPathCase pathCase;
}

/// Finds docroot sides whose configured policies can create in-root trash.
///
/// This check is intentionally lexical. Filesystem canonicalization remains
/// the app layer's responsibility; uncertain paths keep the warning visible.
List<SyncDocrootWarning> syncDocrootWarnings(
  SyncPair pair, {
  Map<SyncSide, SyncDocrootPathState> resolvedPaths = const {},
}) {
  if (!_canCreateTrash(pair.rules)) return const [];

  final warnings = <SyncDocrootWarning>[];
  for (final side in SyncSide.values) {
    final endpoint = side == SyncSide.left ? pair.left : pair.right;
    final resolved = resolvedPaths[side];
    final rootPath = resolved?.rootPath ?? endpoint.path;
    final style = resolved?.pathStyle ?? _pathStyle(endpoint);
    if (!_looksLikeDocroot(rootPath, style)) continue;

    final configured = side == SyncSide.left
        ? pair.rules.trashPathLeft
        : pair.rules.trashPathRight;
    final resolvedTrash = resolved?.trashPath;
    final outside = resolvedTrash == null
        ? _pointsOutsideRoot(rootPath, configured, style)
        : !_isWithinRoot(rootPath, resolvedTrash, style, resolved!.pathCase);
    if (outside) continue;

    warnings.add(
      SyncDocrootWarning(
        side: side,
        rootPath: rootPath,
        suggestedTrashPath: _suggestedTrashPath(
          _endpointWithPath(endpoint, rootPath),
          style,
        ),
      ),
    );
  }

  return List.unmodifiable(warnings);
}

bool _canCreateTrash(SyncRuleSet rules) =>
    rules.deletions != DeletionPolicy.permanent ||
    rules.backups == BackupPolicy.trash;

bool _looksLikeDocroot(String rootPath, SyncTrashPathStyle style) {
  final context = syncTrashPathContext(style);
  final components = context
      .split(context.normalize(rootPath))
      .map((component) => component.toLowerCase());
  return components.any(_docrootComponents.contains);
}

bool _pointsOutsideRoot(
  String rootPath,
  String? configured,
  SyncTrashPathStyle style,
) {
  if (configured == null) return false;
  final rootIsTilde = _isTildePath(rootPath);
  final configuredIsTilde = _isTildePath(configured);
  if (rootIsTilde || configuredIsTilde) {
    // Only paths sharing the same home namespace can be compared before
    // expansion. Mixed absolute/home paths stay warned until scan.
    if (!rootIsTilde || !configuredIsTilde) return false;

    return !_isWithinRoot(
      _tildeRelative(rootPath),
      _tildeRelative(configured),
      style,
      SyncTrashPathCase.insensitive,
    );
  }

  final context = syncTrashPathContext(style);
  // Case behavior is unknown before scan; retain a safe false positive.
  final normalizedRoot = _normalizeForComparison(
    rootPath,
    context,
    SyncTrashPathCase.insensitive,
  );
  final effective = context.isAbsolute(configured)
      ? configured
      : context.join(rootPath, configured);
  final normalizedTrash = _normalizeForComparison(
    effective,
    context,
    SyncTrashPathCase.insensitive,
  );

  if (normalizedRoot == normalizedTrash) return false;
  return !context.isWithin(normalizedRoot, normalizedTrash);
}

bool _isTildePath(String path) => path == '~' || path.startsWith('~/');

String _tildeRelative(String path) => path == '~' ? '.' : path.substring(2);

bool _isWithinRoot(
  String rootPath,
  String trashPath,
  SyncTrashPathStyle style,
  SyncTrashPathCase pathCase,
) {
  final context = syncTrashPathContext(style);
  final root = _normalizeForComparison(rootPath, context, pathCase);
  final trash = _normalizeForComparison(trashPath, context, pathCase);
  return root == trash || context.isWithin(root, trash);
}

String _normalizeForComparison(
  String path,
  p.Context context,
  SyncTrashPathCase pathCase,
) {
  final normalized = context.normalize(path);
  return pathCase == SyncTrashPathCase.insensitive
      ? normalized.toLowerCase()
      : normalized;
}

String _suggestedTrashPath(SyncEndpoint endpoint, SyncTrashPathStyle style) {
  final context = syncTrashPathContext(style);
  final normalizedPath = context.normalize(endpoint.path);
  final normalizedEndpoint = switch (endpoint) {
    LocalEndpoint() => LocalEndpoint(normalizedPath),
    RemoteEndpoint(:final server) => RemoteEndpoint(
      server: server,
      path: normalizedPath,
    ),
  };
  final identity = canonicalEndpointIdentity(normalizedEndpoint);
  final digest = _base32(sha256.convert(utf8.encode(identity)).bytes);
  final basename = _sanitizeSlug(context.basename(normalizedPath));
  final maxBasenameLength = _maxSlugLength - digest.length - 1;
  final boundedBasename = basename.length <= maxBasenameLength
      ? basename
      : basename.substring(0, maxBasenameLength);

  return '$_suggestionRoot/$boundedBasename-$digest';
}

/// RFC 4648 base32 without padding keeps the complete digest lowercase and
/// filesystem-safe. A SHA-256 digest always produces 52 characters.
String _base32(List<int> bytes) {
  var buffer = 0;
  var bitCount = 0;
  final output = StringBuffer();
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bitCount += 8;
    while (bitCount >= 5) {
      bitCount -= 5;
      output.write(_base32Alphabet[(buffer >> bitCount) & 31]);
    }
    buffer &= (1 << bitCount) - 1;
  }
  if (bitCount > 0) {
    output.write(_base32Alphabet[(buffer << (5 - bitCount)) & 31]);
  }

  return output.toString();
}

String _sanitizeSlug(String value) {
  final slug = value
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'root' : slug;
}

SyncTrashPathStyle _pathStyle(SyncEndpoint endpoint) {
  if (endpoint is RemoteEndpoint) return SyncTrashPathStyle.posix;
  final path = endpoint.path;
  if (p.style == p.Style.windows || _windowsVolumeShape.hasMatch(path)) {
    return SyncTrashPathStyle.windows;
  }

  return SyncTrashPathStyle.posix;
}

SyncEndpoint _endpointWithPath(SyncEndpoint endpoint, String path) =>
    switch (endpoint) {
      LocalEndpoint() => LocalEndpoint(path),
      RemoteEndpoint(:final server) => RemoteEndpoint(
        server: server,
        path: path,
      ),
    };

extension on SyncEndpoint {
  String get path => switch (this) {
    LocalEndpoint(:final path) || RemoteEndpoint(:final path) => path,
  };
}
