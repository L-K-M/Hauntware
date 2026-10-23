/// The suite's link grammar: strict parsers and builders for
/// `poltergeist://browse` and `seance://connect`. Moved from Poltergeist's
/// `deep_links.dart` and `seance_links.dart` (docs/design/suite-links.md
/// sections 2 and 5); the review queue and launcher stay in the app.
library;

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:seance_protocol/seance_protocol.dart'
    show Bookmark, ServerConfig;

import '../fs/path_component.dart';
import 'link_display.dart';

const poltergeistDeepLinkScheme = 'poltergeist';
const poltergeistBrowseRoute = 'browse';
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
  if (uri.scheme.toLowerCase() != poltergeistDeepLinkScheme ||
      uri.host.toLowerCase() != poltergeistBrowseRoute ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasFragment ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.unsupportedLink),
    );
  }

  late final Map<String, List<String>> parameters;
  try {
    parameters = uri.queryParametersAll;
  } on FormatException {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
    );
  }
  if (parameters.values.any((values) => values.length != 1)) {
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
    final serverId = parameters['serverId']!.single;
    final path = parameters['path']!.single;
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
  final rawPort = parameters['port']!.single;
  final port = _parseDecimalPort(rawPort);
  if (port == null || port < _minPort || port > _maxPort) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidPort),
    );
  }
  final host = parameters['host']!.single;
  final username = parameters['username']!.single;
  final path = parameters['path']!.single;
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

Uri seanceConnectUriForBookmark(Bookmark bookmark) {
  final server = bookmark.server;
  if (server == null) {
    throw StateError('A remote bookmark must carry a server reference.');
  }
  if (server.serverConfigId case final id?) {
    return _seanceConnectUri({'serverId': id});
  }
  final identity = server.identity;
  if (identity == null) {
    throw StateError('A server reference must carry an id or identity.');
  }
  return _seanceConnectUri({
    'host': identity.host,
    'port': '${identity.port}',
    'username': identity.username,
  });
}

Uri seanceConnectUriForServer(ServerConfig server) =>
    _seanceConnectUri({'serverId': server.id});

Uri _seanceConnectUri(Map<String, String> parameters) => Uri(
  scheme: seanceDeepLinkScheme,
  host: seanceConnectRoute,
  queryParameters: parameters,
);
