import 'dart:async' show Timer, unawaited;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

/// The strings the OS side renders into the keep-alive notification.
/// Parameters, not resources, so each app owns its wording and channel:
/// Seance and Poltergeist share the service but keep distinct channels
/// (channel settings are stored user data) and their own localized or
/// literal copy.
abstract interface class KeepAliveStrings {
  /// The notification channel's id. Per-app: the channel's user settings
  /// live under this id, so it must never change for an existing app.
  String get channelId;

  /// The channel's user-visible name (system notification settings).
  String get channelName;

  /// The channel's user-visible description.
  String get channelDescription;

  /// The notification's title.
  String get notificationTitle;

  /// The notification's body for [count] live items.
  String notificationText(int count);

  /// The small icon's drawable resource name, resolved in the app's own
  /// package so the plugin needs no bundled resources.
  String get smallIconResourceName;
}

/// The OS-side half of the background keep-alive. Implemented by the platform
/// channel backend below; tests substitute a recorder.
abstract class BackgroundKeepAliveBackend {
  /// Start anchoring the process. [count] is how many items need it alive
  /// right now.
  Future<void> activate(int count);

  /// The anchor is up and the live count changed.
  Future<void> countChanged(int count);

  /// Stop anchoring; nothing needs the process kept alive.
  Future<void> deactivate();
}

/// Talks to the native `ghost_keepalive` channel (a foreground service on
/// Android). Android only: desktop apps are never frozen by their OS, and
/// iOS offers no equivalent for a sideloaded app, so every call is a no-op
/// elsewhere. Best-effort by design — a failed anchor degrades to the
/// backgrounding behavior of old (the work dies) and must never surface as
/// an application error.
///
/// The [strings] are marshaled with every count-carrying call: the service
/// is stateless across process restarts, and this keeps the notification
/// rebuilding without another round trip.
class MethodChannelBackgroundKeepAliveBackend
    implements BackgroundKeepAliveBackend {
  const MethodChannelBackgroundKeepAliveBackend({required this._strings});

  static const MethodChannel _channel = MethodChannel('ghost_keepalive');

  final KeepAliveStrings _strings;

  @override
  Future<void> activate(int count) => _invoke('activate', count);

  @override
  Future<void> countChanged(int count) => _invoke('countChanged', count);

  @override
  Future<void> deactivate() => _invoke('deactivate');

  Future<void> _invoke(String method, [int? count]) async {
    // kIsWeb first: querying the target platform throws on a web build,
    // and only Android has a channel to talk to. defaultTargetPlatform
    // (not dart:io's Platform) so tests can flip the host.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(
        method,
        count == null
            ? null
            : {
                'count': count,
                'channelId': _strings.channelId,
                'channelName': _strings.channelName,
                'channelDescription': _strings.channelDescription,
                'notificationTitle': _strings.notificationTitle,
                'notificationText': _strings.notificationText(count),
                'smallIconResourceName': _strings.smallIconResourceName,
              },
      );
    } on MissingPluginException {
      // Channel not installed (older embedding) — nothing to anchor through.
    } on PlatformException catch (e) {
      debugPrint('background keep-alive "$method" failed: ${e.message}');
    }
  }
}

/// Decides when the app needs an OS-level anchor keeping its process (and
/// with it every live connection or transfer) alive while it is
/// backgrounded.
///
/// Without an anchor, Android freezes cached processes soon after they leave
/// the screen; keepalives stop firing, sockets die, and the remote work dies
/// with them. While anything is still live, the anchor (an Android
/// foreground service behind [BackgroundKeepAliveBackend]) holds the process
/// out of the freezer. Seance lets the user opt out via settings.
///
/// Pure state machine over the reported live count: it activates once on
/// 0 → n, coalesces repeats into count updates, and deactivates once on
/// n → 0 — but not instantly. Zero-crossings are often transient (a failed
/// connect, a retry in flight), and cycling a foreground service that fast
/// flickers its notification; the anchor lingers for [_deactivateGrace] and a
/// new count within the window simply reuses it.
class BackgroundKeepAlive {
  BackgroundKeepAlive({
    required KeepAliveStrings strings,
    BackgroundKeepAliveBackend? backend,
    this._enabled = true,
  }) : _backend =
           backend ?? MethodChannelBackgroundKeepAliveBackend(strings: strings);

  /// How long the anchor survives the last live item before being dropped.
  static const Duration _deactivateGrace = Duration(seconds: 1);

  final BackgroundKeepAliveBackend _backend;
  bool _enabled;

  /// Count the backend was last told about; only meaningful while [_anchored].
  int _anchoredCount = 0;
  bool _anchored = false;
  int _lastCount = 0;
  Timer? _deactivateTimer;

  /// Apply the user's keep-alive setting. Enabling re-anchors immediately for
  /// the items already live; disabling drops an active anchor and keeps
  /// count churn from resurrecting one until re-enabled.
  void setEnabled(bool enabled) {
    if (enabled == _enabled) return;
    _enabled = enabled;
    enabled ? _anchor(_lastCount) : _deactivateNow();
  }

  /// Report the current number of live items. Call after every mutation of
  /// an item's liveness.
  void refresh(int count) {
    _lastCount = count;
    if (!_enabled) return;
    _anchor(count);
  }

  /// Drop the anchor immediately, grace ignored. For teardown, where nothing
  /// will re-anchor afterwards.
  void stop() {
    _lastCount = 0;
    _deactivateNow();
  }

  void _anchor(int count) {
    if (count <= 0) {
      // Already dropping (or nothing anchored): a second zero changes nothing.
      if (!_anchored || _deactivateTimer != null) return;
      _deactivateTimer = Timer(_deactivateGrace, _deactivateNow);
      return;
    }
    _deactivateTimer?.cancel();
    _deactivateTimer = null;
    if (_anchored && count == _anchoredCount) return;
    final wasAnchored = _anchored;
    _anchored = true;
    _anchoredCount = count;
    // The calls are unawaited, so a throwing backend would otherwise surface
    // as an unhandled async error — anchoring is best-effort by contract.
    unawaited(
      (wasAnchored ? _backend.countChanged(count) : _backend.activate(count))
          .catchError((Object error) {
            debugPrint('background keep-alive call failed: $error');
          }),
    );
  }

  void _deactivateNow() {
    _deactivateTimer?.cancel();
    _deactivateTimer = null;
    if (!_anchored) return;
    _anchored = false;
    _anchoredCount = 0;
    unawaited(
      _backend.deactivate().catchError((Object error) {
        debugPrint('background keep-alive deactivate failed: $error');
      }),
    );
  }
}
