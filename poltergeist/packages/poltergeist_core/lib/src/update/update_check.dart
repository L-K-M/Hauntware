import 'package:seance_core/seance_core.dart' show hauntwareUpdateRepo;

/// Preserve the host API while checking the shared suite release.
const poltergeistUpdateRepo = hauntwareUpdateRepo;

/// The `User-Agent` Poltergeist's update check sends, so GitHub sees
/// Poltergeist rather than the shared checker's Séance default.
const poltergeistUpdateUserAgent = 'Poltergeist-update-check';

/// The release asset an Android build updates itself from; the release
/// manifest (scripts/release-manifest.txt) names it.
const poltergeistAndroidReleaseAsset = 'poltergeist-android.apk';
