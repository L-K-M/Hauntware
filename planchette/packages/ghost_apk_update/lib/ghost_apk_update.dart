/// The Android in-app update shared by Séance and Poltergeist: after the
/// user chooses Update, [ApkUpdater] downloads the release APK, proves it
/// against the published size and SHA-256 digest, and opens the system
/// installer through `GhostApkUpdatePlugin`.
///
/// Host-neutral: it takes a plain [ApkRelease], so the release lookup
/// (seance_core's UpdateChecker) and every user-facing string stay in the
/// apps. Never `seance_core` or `dartssh2` (tool/guards.yaml).
library;

export 'src/apk_installer.dart';
export 'src/apk_updater.dart';
