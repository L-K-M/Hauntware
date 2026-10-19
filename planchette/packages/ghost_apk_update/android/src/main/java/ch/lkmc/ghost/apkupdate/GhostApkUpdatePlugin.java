package ch.lkmc.ghost.apkupdate;

import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.FileProvider;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Stages and opens a downloaded update of this app: Dart downloads and
 * verifies the APK into {@link #stagingDirectory()}, then asks this plugin
 * to open it in the system installer through {@link ApkFileProvider}.
 */
public final class GhostApkUpdatePlugin
    implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private static final String CHANNEL = "ghost_apk_update";
  private static final String STAGING_DIRECTORY = "ghost_apk_update";
  private static final String AUTHORITY_SUFFIX = ".ghost_apk_update";
  private static final String APK_MIME_TYPE = "application/vnd.android.package-archive";
  private static final String APK_EXTENSION = ".apk";

  // Emptied once per process. No download can run before the first engine
  // attaches, and a file from an earlier process is an update that was
  // installed (which restarted the app) or abandoned.
  private static final AtomicBoolean stagingCleared = new AtomicBoolean(false);

  @Nullable private Context context;
  @Nullable private MethodChannel channel;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    if (stagingCleared.compareAndSet(false, true)) clearStaging();

    channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (channel != null) channel.setMethodCallHandler(null);
    channel = null;
    context = null;
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    switch (call.method) {
      case "stagingDirectory":
        stagingDirectory(result);
        break;
      case "install":
        install(call.argument("path"), result);
        break;
      default:
        result.notImplemented();
    }
  }

  private void stagingDirectory(@NonNull MethodChannel.Result result) {
    File directory = stagingDirectory();
    if (!directory.isDirectory() && !directory.mkdirs()) {
      result.error("NO_STAGING_DIRECTORY", "Android could not create the update directory.", null);
      return;
    }
    result.success(directory.getAbsolutePath());
  }

  private void install(@Nullable String path, @NonNull MethodChannel.Result result) {
    Context app = requireContext();
    File apk = stagedApk(path);
    if (apk == null) {
      result.error("INVALID_ARGUMENT", "Only a staged APK can be installed.", null);
      return;
    }

    // An APK of another app would install beside this one, not update it.
    PackageInfo archive = archiveInfo(app.getPackageManager(), apk);
    if (archive == null || !app.getPackageName().equals(archive.packageName)) {
      result.error("WRONG_PACKAGE", "The downloaded file is not an update of this app.", null);
      return;
    }

    Uri uri =
        FileProvider.getUriForFile(app, app.getPackageName() + AUTHORITY_SUFFIX, apk);
    Intent intent =
        new Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, APK_MIME_TYPE)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
    try {
      app.startActivity(intent);
      result.success(null);
    } catch (ActivityNotFoundException e) {
      result.error("NO_INSTALLER", "No app on this device can install the update.", null);
    }
  }

  /** The file {@code path} names when it is an APK directly inside the staging directory. */
  @Nullable
  private File stagedApk(@Nullable String path) {
    if (path == null) return null;
    try {
      File apk = new File(path).getCanonicalFile();
      File directory = stagingDirectory().getCanonicalFile();
      if (!directory.equals(apk.getParentFile())) return null;
      if (!apk.getName().endsWith(APK_EXTENSION) || !apk.isFile()) return null;
      return apk;
    } catch (IOException e) {
      return null;
    }
  }

  @Nullable
  private static PackageInfo archiveInfo(@NonNull PackageManager packages, @NonNull File apk) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      return packages.getPackageArchiveInfo(apk.getPath(), PackageManager.PackageInfoFlags.of(0));
    }
    return packages.getPackageArchiveInfo(apk.getPath(), 0);
  }

  private void clearStaging() {
    File[] files = stagingDirectory().listFiles();
    if (files == null) return;
    for (File file : files) {
      // Best effort: the cache is the system's to clear as well.
      //noinspection ResultOfMethodCallIgnored
      file.delete();
    }
  }

  @NonNull
  private File stagingDirectory() {
    return new File(requireContext().getCacheDir(), STAGING_DIRECTORY);
  }

  @NonNull
  private Context requireContext() {
    if (context == null) throw new IllegalStateException("The plugin is not attached.");
    return context;
  }
}
