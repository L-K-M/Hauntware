/// Outbound `seance://connect` links and their OS-handler gate.
library;

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:url_launcher/url_launcher.dart';

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

typedef UriHandlerProbe = Future<bool> Function(Uri uri);
typedef ExternalUriLauncher = Future<bool> Function(Uri uri);
typedef SeanceLaunchErrorSink =
    void Function(Object error, StackTrace stackTrace);

abstract interface class SeanceLauncher {
  bool get available;

  Future<void> openBookmark(Bookmark bookmark);

  Future<void> openServer(ServerConfig server);
}

final class SeanceLinkLauncher implements SeanceLauncher {
  const SeanceLinkLauncher._({
    required this.available,
    required this._launch,
    required this._onError,
  });

  @override
  final bool available;
  final ExternalUriLauncher _launch;
  final SeanceLaunchErrorSink _onError;

  static Future<SeanceLinkLauncher> probe({
    UriHandlerProbe probe = _probeHandler,
    ExternalUriLauncher launch = _launchExternal,
    required SeanceLaunchErrorSink onError,
  }) async {
    var available = false;
    try {
      available = await probe(
        Uri(scheme: seanceDeepLinkScheme, host: seanceConnectRoute),
      );
    } on Object catch (error, stackTrace) {
      onError(error, stackTrace);
    }
    return SeanceLinkLauncher._(
      available: available,
      launch: launch,
      onError: onError,
    );
  }

  @override
  Future<void> openBookmark(Bookmark bookmark) =>
      _open(seanceConnectUriForBookmark(bookmark));

  @override
  Future<void> openServer(ServerConfig server) =>
      _open(seanceConnectUriForServer(server));

  Future<void> _open(Uri uri) async {
    if (!available) return;
    try {
      if (await _launch(uri)) return;
      throw StateError('The Séance link handler refused the request.');
    } on Object catch (error, stackTrace) {
      _onError(error, stackTrace);
    }
  }

  static Future<bool> _probeHandler(Uri uri) => canLaunchUrl(uri);

  static Future<bool> _launchExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}
