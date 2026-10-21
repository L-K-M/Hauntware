/// The suite's link grammar: strict parsers and builders for
/// `poltergeist://browse` and `seance://connect`. Moved from Poltergeist's
/// `deep_links.dart` and `seance_links.dart` (docs/design/suite-links.md
/// sections 2 and 5); the review queue and launcher stay in the app.
///
/// Every parser refuses the whole link on any deviation, and every builder
/// throws [ArgumentError] on input its parser would refuse, so a built link
/// always parses back to what was built. No form carries a command: a key
/// outside a form's exact set refuses the link (D12, X8).
library;

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:seance_protocol/seance_protocol.dart'
    show Bookmark, ServerConfig;

import '../fs/path_component.dart';
import 'link_display.dart';

const poltergeistDeepLinkScheme = 'poltergeist';
const poltergeistBrowseRoute = 'browse';

/// Reserved for X-06's `klabautermann://server` links. No parser or builder
/// exists until X-06 defines the form, so every parser here refuses it.
const klabautermannDeepLinkScheme = 'klabautermann';
const klabautermannServerRoute = 'server';
const _maxRemotePathBytes = 4096;
const _maxEndpointValueLength = 1024;
const _minPort = 1;
const _maxPort = 65535;

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

enum DeepLinkFailureKind {
  unsupportedLink,
  invalidParameters,
  invalidPort,
  invalidPath,
  serverNotFound,
}

@immutable
final class DeepLinkFailure {
  const DeepLinkFailure(this.kind, {this.serverId});

  final DeepLinkFailureKind kind;
  final String? serverId;
}

sealed class DeepLinkRequest {
  const DeepLinkRequest({required this.remotePath});

  final String remotePath;
}

@immutable
final class ServerDeepLink extends DeepLinkRequest {
  const ServerDeepLink({required this.serverId, required super.remotePath});

  final String serverId;
}

@immutable
final class HostDeepLink extends DeepLinkRequest {
  const HostDeepLink({
    required this.host,
    required this.port,
    required this.username,
    required super.remotePath,
    this.activationCount = 1,
  });

  final String host;
  final int port;
  final String username;
  final int activationCount;

  ({String host, int port, String username}) get endpointKey =>
      (host: _endpointHostKey(host), port: port, username: username);

  HostDeepLink coalesce(HostDeepLink newer) => HostDeepLink(
    host: newer.host,
    port: newer.port,
    username: newer.username,
    remotePath: newer.remotePath,
    activationCount: activationCount + newer.activationCount,
  );
}

String _endpointHostKey(String host) {
  final zoneStart = host.indexOf('%');
  if (zoneStart < 0) return host.toLowerCase();

  // IPv6 addresses are case-insensitive, but interface names are not.
  return '${host.substring(0, zoneStart).toLowerCase()}'
      '${host.substring(zoneStart)}';
}

@immutable
final class DeepLinkParse {
  const DeepLinkParse._({this.request, this.failure});

  const DeepLinkParse.request(DeepLinkRequest request)
    : this._(request: request);

  const DeepLinkParse.failure(DeepLinkFailure failure)
    : this._(failure: failure);

  final DeepLinkRequest? request;
  final DeepLinkFailure? failure;
}

DeepLinkParse parsePoltergeistDeepLink(Uri uri) {
  if (!_isRoute(uri, poltergeistDeepLinkScheme, poltergeistBrowseRoute)) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.unsupportedLink),
    );
  }

  final parameters = _singleParameters(uri);
  if (parameters == null) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
    );
  }

  final keys = parameters.keys.toSet();
  if (keys.contains('serverId')) {
    if (!_sameKeys(keys, const {'serverId', 'path'})) {
      return const DeepLinkParse.failure(
        DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
      );
    }
    final serverId = parameters['serverId']!;
    final path = parameters['path']!;
    if (!_uuidPattern.hasMatch(serverId)) {
      return const DeepLinkParse.failure(
        DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
      );
    }
    if (!_validRemotePath(path)) {
      return const DeepLinkParse.failure(
        DeepLinkFailure(DeepLinkFailureKind.invalidPath),
      );
    }
    return DeepLinkParse.request(
      ServerDeepLink(serverId: serverId.toLowerCase(), remotePath: path),
    );
  }

  if (!keys.contains('port') &&
      keys.containsAll(const {'host', 'username', 'path'})) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidPort),
    );
  }
  if (!_sameKeys(keys, const {'host', 'port', 'username', 'path'})) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
    );
  }
  final rawPort = parameters['port']!;
  final port = _parseDecimalPort(rawPort);
  if (port == null || port < _minPort || port > _maxPort) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidPort),
    );
  }
  final host = parameters['host']!;
  final username = parameters['username']!;
  final path = parameters['path']!;
  if (!_validHost(host) || !_validUsername(username)) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
    );
  }
  if (!_validRemotePath(path)) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidPath),
    );
  }
  return DeepLinkParse.request(
    HostDeepLink(host: host, port: port, username: username, remotePath: path),
  );
}

/// Whether [uri] is exactly `<scheme>://<route>`: both case-insensitive,
/// with no path beyond `/`, fragment, authority port or userinfo.
bool _isRoute(Uri uri, String scheme, String route) =>
    uri.scheme.toLowerCase() == scheme &&
    uri.host.toLowerCase() == route &&
    (uri.path.isEmpty || uri.path == '/') &&
    !uri.hasFragment &&
    !uri.hasPort &&
    uri.userInfo.isEmpty;

/// [uri]'s query as one value per key, or null when a key repeats or the
/// query does not decode.
///
/// Dart's `Uri.parse` keeps a malformed escape such as `%ZZ` as the literal
/// text `%ZZ`, so only an escape that decodes to invalid UTF-8 fails here.
/// A value that keeps a literal `%` still meets its own rule, which none
/// of the UUID, port or path rules lets through as anything but a name.
Map<String, String>? _singleParameters(Uri uri) {
  final Map<String, List<String>> all;
  try {
    all = uri.queryParametersAll;
  } on FormatException {
    return null;
  }
  if (all.values.any((values) => values.length != 1)) return null;
  return {for (final MapEntry(:key, :value) in all.entries) key: value.single};
}

int? _parseDecimalPort(String value) {
  if (value.isEmpty) return null;

  var port = 0;
  for (final unit in value.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return null;
    port = port * 10 + unit - 0x30;
    if (port > _maxPort) return null;
  }
  return port;
}

bool _validHost(String value) {
  if (value.isEmpty || value.length > _maxEndpointValueLength) return false;
  for (final rune in value.runes) {
    if (rune <= 0x20 || isUnsafeDisplayControl(rune)) return false;
    if (const [0x2f, 0x5c, 0x40, 0x3f, 0x23, 0x26].contains(rune)) {
      return false;
    }
  }
  return true;
}

bool _validUsername(String value) {
  if (value.length > _maxEndpointValueLength) return false;
  return value.runes.every((rune) => !isUnsafeDisplayControl(rune));
}

bool _sameKeys(Set<String> keys, Set<String> expected) =>
    keys.length == expected.length && keys.containsAll(expected);

bool _validRemotePath(String path) {
  if (!path.startsWith('/') || utf8.encode(path).length > _maxRemotePathBytes) {
    return false;
  }
  if (path == '/') return true;
  final components = path.substring(1).split('/');
  try {
    for (final component in components) {
      validatePathComponent(component);
    }
  } on FormatException {
    return false;
  }
  return true;
}

const seanceDeepLinkScheme = 'seance';
const seanceConnectRoute = 'connect';

/// A `seance://connect` link that parsed: which server to connect to, and
/// for the id form the folder to start in.
sealed class SeanceConnectRequest {
  const SeanceConnectRequest();
}

/// `seance://connect?serverId=<uuid>[&cwd=<folder>]`.
@immutable
final class SeanceServerConnect extends SeanceConnectRequest {
  const SeanceServerConnect({required this.serverId, this.cwd});

  /// Lower-case, as the catalog stores it.
  final String serverId;

  /// An absolute folder with no control characters, which
  /// `buildChangeDirectoryCommand` always accepts.
  final String? cwd;
}

/// `seance://connect?host=&port=&username=`, Poltergeist's link for a
/// bookmark without a catalog id (docs/design/suite-links.md section 3).
/// It names a server only to look up one the receiver already has; it
/// never creates one and carries no folder.
@immutable
final class SeanceIdentityConnect extends SeanceConnectRequest {
  const SeanceIdentityConnect({
    required this.host,
    required this.port,
    required this.username,
  });

  final String host;
  final int port;
  final String username;

  /// The key a stored server must share to match: the host compares
  /// case-insensitively except an IPv6 zone id.
  ({String host, int port, String username}) get endpointKey =>
      (host: _endpointHostKey(host), port: port, username: username);
}

@immutable
final class SeanceConnectParse {
  const SeanceConnectParse._({this.request, this.failure});

  const SeanceConnectParse.request(SeanceConnectRequest request)
    : this._(request: request);

  const SeanceConnectParse.failure(DeepLinkFailure failure)
    : this._(failure: failure);

  final SeanceConnectRequest? request;
  final DeepLinkFailure? failure;
}

/// Parses a `seance://connect` link (docs/design/suite-links.md section 2).
SeanceConnectParse parseSeanceConnect(Uri uri) {
  if (!_isRoute(uri, seanceDeepLinkScheme, seanceConnectRoute)) {
    return const SeanceConnectParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.unsupportedLink),
    );
  }

  final parameters = _singleParameters(uri);
  if (parameters == null) {
    return const SeanceConnectParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
    );
  }

  final keys = parameters.keys.toSet();
  if (keys.contains('serverId')) {
    if (!_sameKeys(keys, const {'serverId'}) &&
        !_sameKeys(keys, const {'serverId', 'cwd'})) {
      return const SeanceConnectParse.failure(
        DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
      );
    }
    final serverId = parameters['serverId']!;
    if (!_uuidPattern.hasMatch(serverId)) {
      return const SeanceConnectParse.failure(
        DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
      );
    }
    final cwd = parameters['cwd'];
    if (cwd != null && !_validFolder(cwd)) {
      return const SeanceConnectParse.failure(
        DeepLinkFailure(DeepLinkFailureKind.invalidPath),
      );
    }
    return SeanceConnectParse.request(
      SeanceServerConnect(serverId: serverId.toLowerCase(), cwd: cwd),
    );
  }

  if (_sameKeys(keys, const {'host', 'username'})) {
    return const SeanceConnectParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidPort),
    );
  }
  if (!_sameKeys(keys, const {'host', 'port', 'username'})) {
    return const SeanceConnectParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
    );
  }
  final port = _parseDecimalPort(parameters['port']!);
  if (port == null || port < _minPort) {
    return const SeanceConnectParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidPort),
    );
  }
  final host = parameters['host']!;
  final username = parameters['username']!;
  if (!_validHost(host) || !_validUsername(username)) {
    return const SeanceConnectParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
    );
  }
  return SeanceConnectParse.request(
    SeanceIdentityConnect(host: host, port: port, username: username),
  );
}

/// The `seance://connect` link for [serverId], starting in [cwd] when set.
///
/// Throws [ArgumentError] when [serverId] is not a UUID or [cwd] is not a
/// normalized absolute folder free of control characters; a trailing
/// slash or `//` is refused, not repaired. The id is written lower-case,
/// as the parser returns it.
Uri buildSeanceConnect({required String serverId, String? cwd}) {
  _checkServerId(serverId);
  if (cwd != null && !_validFolder(cwd)) {
    throw ArgumentError.value(cwd, 'cwd', 'Not a linkable folder.');
  }
  return _seanceConnectUri({'serverId': serverId.toLowerCase(), 'cwd': ?cwd});
}

/// The `poltergeist://browse` link for [path] on [serverId].
///
/// Throws [ArgumentError] when [serverId] is not a UUID or [path] is not a
/// normalized absolute path.
Uri buildPoltergeistBrowse({required String serverId, required String path}) {
  _checkServerId(serverId);
  if (!_validRemotePath(path)) {
    throw ArgumentError.value(path, 'path', 'Not a linkable path.');
  }
  return Uri(
    scheme: poltergeistDeepLinkScheme,
    host: poltergeistBrowseRoute,
    queryParameters: {'serverId': serverId.toLowerCase(), 'path': path},
  );
}

/// The `seance://connect` link for [bookmark]'s server: by catalog id when
/// it has one, else by host, port and username.
///
/// Throws [StateError] for a bookmark without a server reference and
/// [ArgumentError] for an id or endpoint the parser would refuse.
Uri seanceConnectUriForBookmark(Bookmark bookmark) {
  final server = bookmark.server;
  if (server == null) {
    throw StateError('A remote bookmark must carry a server reference.');
  }
  if (server.serverConfigId case final id?) {
    return buildSeanceConnect(serverId: id);
  }
  final identity = server.identity;
  if (identity == null) {
    throw StateError('A server reference must carry an id or identity.');
  }
  if (!_validHost(identity.host)) {
    throw ArgumentError.value(identity.host, 'host', 'Not a linkable host.');
  }
  if (identity.port < _minPort || identity.port > _maxPort) {
    throw ArgumentError.value(identity.port, 'port', 'Not a TCP port.');
  }
  if (!_validUsername(identity.username)) {
    throw ArgumentError.value(
      identity.username,
      'username',
      'Not a linkable username.',
    );
  }
  return _seanceConnectUri({
    'host': identity.host,
    'port': '${identity.port}',
    'username': identity.username,
  });
}

/// Throws [ArgumentError] when [server]'s id is not a UUID.
Uri seanceConnectUriForServer(ServerConfig server) =>
    buildSeanceConnect(serverId: server.id);

Uri _seanceConnectUri(Map<String, String> parameters) => Uri(
  scheme: seanceDeepLinkScheme,
  host: seanceConnectRoute,
  queryParameters: parameters,
);

void _checkServerId(String serverId) {
  if (!_uuidPattern.hasMatch(serverId)) {
    throw ArgumentError.value(serverId, 'serverId', 'Not a UUID.');
  }
}

/// The browse path rule plus no C0 or C1 control, the set
/// `buildChangeDirectoryCommand` throws on, so a folder that parses can
/// always be staged.
bool _validFolder(String path) =>
    _validRemotePath(path) &&
    path.runes.every((rune) => rune > 0x1f && (rune < 0x7f || rune > 0x9f));
