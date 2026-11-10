import 'package:seance_core/seance_core.dart' show hauntwareUpdateRepo;

/// Preserve the host API while checking the shared suite release.
const klabautermannUpdateRepo = hauntwareUpdateRepo;

/// The `User-Agent` Klabautermann's update check sends, so GitHub sees
/// Klabautermann rather than the shared checker's Séance default.
const klabautermannUpdateUserAgent = 'Klabautermann-update-check';

/// The release asset an Android build updates itself from; the release
/// manifest (scripts/release-manifest.txt) names it. Until v1 the suite
/// ships Klabautermann's clients as previews.
const klabautermannAndroidReleaseAsset = 'klabautermann-preview-android.apk';
