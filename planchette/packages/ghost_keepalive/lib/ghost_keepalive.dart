/// The background keep-alive shared by Séance and Poltergeist: while the
/// app has live work (SSH sessions, transfers), an Android foreground
/// service holds the process out of Android's cached-app freezer through
/// `GhostKeepAlivePlugin`.
///
/// Host-neutral: every user-facing string and the notification channel id
/// are parameters ([KeepAliveStrings]), so each app owns its wording and
/// existing users keep their stored channel settings.
library;

export 'src/background_keep_alive.dart';
