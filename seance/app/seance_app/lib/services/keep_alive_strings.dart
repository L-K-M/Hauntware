import 'package:ghost_keepalive/ghost_keepalive.dart';

/// Séance's strings for the shared keep-alive's notification. The wording
/// matches what the app-private service showed before the move, and the
/// channel id must never change: its settings are stored user data from
/// before the plugin existed.
class SeanceKeepAliveStrings implements KeepAliveStrings {
  const SeanceKeepAliveStrings();

  @override
  String get channelId => 'seance.keepalive';

  @override
  String get channelName => 'Session keep-alive';

  @override
  String get channelDescription =>
      'Shown while connections are kept alive in the background.';

  @override
  String get notificationTitle => 'Séance';

  @override
  String notificationText(int count) {
    final sessions = count == 1 ? 'session' : 'sessions';
    return 'Keeping $count $sessions alive in the background.';
  }

  @override
  String get smallIconResourceName => 'ic_stat_keep_alive';
}
