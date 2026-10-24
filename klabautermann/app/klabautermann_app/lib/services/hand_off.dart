/// Hand-offs to the sibling apps (X-03, X-04, X-10; D12, 03 §2): a link
/// that names a server and, at most, a folder, opened in Séance or
/// Poltergeist. Links come only from the suite's builders, which refuse
/// any other parameter, so a hand-off can never carry a command (X8).
library;

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show
        buildPoltergeistBrowse,
        buildSeanceConnect,
        poltergeistBrowseRoute,
        poltergeistDeepLinkScheme,
        seanceConnectRoute,
        seanceDeepLinkScheme;
import 'package:url_launcher/url_launcher.dart';

/// The app a hand-off opens.
enum HandOffTarget {
  seance(seanceDeepLinkScheme, seanceConnectRoute),
  poltergeist(poltergeistDeepLinkScheme, poltergeistBrowseRoute);

  const HandOffTarget(this.scheme, this.route);

  final String scheme;
  final String route;

  /// The bare link the handler probe asks the OS about.
  Uri get probeUri => Uri(scheme: scheme, host: route);
}

/// Whether [target] registers its scheme on [platform] (D12, 03:403-404):
/// until it does, the app offers no hand-off to it there. Séance and
/// Poltergeist take links on every platform they ship on, Linux and
/// Windows through their single-instance forwarding (F5d-3); neither
/// ships on Fuchsia.
bool handOffIntakeOn(HandOffTarget target, TargetPlatform platform) =>
    platform != TargetPlatform.fuchsia;

/// The `seance://connect` link for [serverId], or null when Séance could
/// not name it: an id that is not a UUID (an ssh_config import, which only
/// this app has) or a folder the link grammar refuses.
Uri? seanceHandOff(String serverId, {String? folder}) {
  try {
    return buildSeanceConnect(serverId: serverId, cwd: folder);
  } on ArgumentError {
    return null;
  }
}

/// The `poltergeist://browse` link for [path] on [serverId], or null when
/// Poltergeist could not name it.
Uri? poltergeistHandOff(String serverId, {required String path}) {
  try {
    return buildPoltergeistBrowse(serverId: serverId, path: path);
  } on ArgumentError {
    return null;
  }
}

/// Opens hand-off links in the sibling apps.
abstract interface class HandOffLauncher {
  /// Whether [target] has an intake on this platform and a handler the
  /// OS reported at startup. An entry for an unavailable target is hidden.
  bool available(HandOffTarget target);

  /// Opens [link] in its app; false when the OS refused it.
  Future<bool> open(Uri link);
}

typedef HandOffProbe = Future<bool> Function(Uri uri);
typedef HandOffOpen = Future<bool> Function(Uri uri);
typedef HandOffErrorSink = void Function(Object error, StackTrace stack);

/// [HandOffLauncher] over `url_launcher`, probed once at startup.
final class UrlHandOffLauncher implements HandOffLauncher {
  UrlHandOffLauncher._(this._available, this._open);

  final Set<HandOffTarget> _available;
  final HandOffOpen _open;

  /// Asks the OS for each target's handler on [platform]. A probe that
  /// fails counts as no handler, and is reported to [onError].
  static Future<UrlHandOffLauncher> probe({
    required TargetPlatform platform,
    required HandOffErrorSink onError,
    HandOffProbe probe = canLaunchUrl,
    HandOffOpen open = _launchExternal,
  }) async {
    final available = <HandOffTarget>{};
    for (final target in HandOffTarget.values) {
      if (!handOffIntakeOn(target, platform)) continue;
      try {
        if (await probe(target.probeUri)) available.add(target);
      } on Object catch (error, stack) {
        onError(error, stack);
      }
    }
    return UrlHandOffLauncher._(available, open);
  }

  @override
  bool available(HandOffTarget target) => _available.contains(target);

  @override
  Future<bool> open(Uri link) => _open(link);

  static Future<bool> _launchExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}
