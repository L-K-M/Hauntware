/// Outbound `seance://connect` links and their OS-handler gate.
library;

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:url_launcher/url_launcher.dart';

// The outbound link builders moved to seance_core
// (docs/design/suite-links.md section 5); re-exported so this file's
// importers do not change.
export 'package:poltergeist_core/poltergeist_core.dart'
    show
        seanceConnectRoute,
        seanceConnectUriForBookmark,
        seanceConnectUriForServer,
        seanceDeepLinkScheme;

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
