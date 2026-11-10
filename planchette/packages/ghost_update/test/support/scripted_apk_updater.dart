import 'package:ghost_apk_update/ghost_apk_update.dart';

/// An Android updater whose state the test sets, recording what the app
/// asked of it. Nothing downloads.
class ScriptedApkUpdater extends ApkUpdater {
  ApkUpdateState _scripted = const ApkUpdateIdle();
  final requested = <ApkRelease>[];
  var cancels = 0;

  @override
  ApkUpdateState get state => _scripted;

  set scripted(ApkUpdateState next) {
    _scripted = next;
    notifyListeners();
  }

  @override
  Future<void> update(ApkRelease release) async => requested.add(release);

  @override
  void cancel() => cancels++;
}

/// The latest-release JSON for [tag], carrying one digested APK asset
/// named [asset].
Map<String, Object?> releaseWithApk(String tag, String asset) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'assets': [
    {
      'name': asset,
      'browser_download_url':
          'https://github.com/L-K-M/Hauntware/releases/download/$tag/$asset',
      'size': 103670866,
      'digest':
          'sha256:'
          '0be7459344d614eb920cce957e33c6d272a1a4540b291b16a580cee7adac64f3',
    },
  ],
};

/// The [ApkRelease] [releaseWithApk] describes.
ApkRelease apkOf(String tag, String asset) => ApkRelease(
  url: Uri.parse(
    'https://github.com/L-K-M/Hauntware/releases/download/$tag/$asset',
  ),
  size: 103670866,
  sha256: '0be7459344d614eb920cce957e33c6d272a1a4540b291b16a580cee7adac64f3',
);
