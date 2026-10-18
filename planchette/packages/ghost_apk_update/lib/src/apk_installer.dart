import 'package:flutter/services.dart';

/// The Android half of the update, implemented by `GhostApkUpdatePlugin`:
/// the directory an APK is staged in and the system installer that opens
/// it. Only an APK of this app inside [stagingDirectory] can be installed.
class ApkInstaller {
  const ApkInstaller();

  static const _channel = MethodChannel('ghost_apk_update');

  /// The app-private cache directory the plugin shares with the system
  /// installer. The plugin empties it once per process start, so an APK
  /// left over from an installed or abandoned update never lingers.
  Future<String> stagingDirectory() async {
    final path = await _channel.invokeMethod<String>('stagingDirectory');
    if (path == null) {
      throw PlatformException(
        code: 'NO_STAGING_DIRECTORY',
        message: 'The plugin returned no staging directory.',
      );
    }
    return path;
  }

  /// Opens the system installer for the staged APK at [path]. Android
  /// asks the user to confirm, and first to allow installs from this app
  /// when that is not yet allowed. Throws [PlatformException] when [path]
  /// is not a staged APK of this app or nothing can open it.
  Future<void> install(String path) =>
      _channel.invokeMethod<void>('install', {'path': path});
}
