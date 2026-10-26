package ch.lkmc.ghost.licenses;

import android.content.Context;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/**
 * Hands Dart the app's library definitions: the Maven libraries of the APK
 * with their license texts, which the AboutLibraries Gradle plugin writes to
 * res/raw/aboutlibraries.json from the resolved release graph.
 */
public final class GhostLicensesPlugin
    implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private static final String CHANNEL = "ghost_licenses";
  private static final String DEFINITIONS = "aboutlibraries";
  private static final String RAW = "raw";

  // Set while attached to an engine.
  private Context context;
  private MethodChannel channel;

  @Override
  public void onAttachedToEngine(FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(FlutterPluginBinding binding) {
    if (channel != null) channel.setMethodCallHandler(null);
    channel = null;
    context = null;
  }

  @Override
  public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    if (!"libraryDefinitions".equals(call.method)) {
      result.notImplemented();
      return;
    }
    if (context == null) {
      result.error("NO_CONTEXT", "The plugin is not attached to an engine.", null);
      return;
    }

    // By name: the definitions belong to the app, not to this library.
    int id = context.getResources().getIdentifier(DEFINITIONS, RAW, context.getPackageName());
    if (id == 0) {
      result.error("NO_DEFINITIONS", "The app has no res/raw/aboutlibraries.json.", null);
      return;
    }
    try (InputStream input = context.getResources().openRawResource(id)) {
      ByteArrayOutputStream bytes = new ByteArrayOutputStream();
      byte[] buffer = new byte[16 * 1024];
      for (int read; (read = input.read(buffer)) != -1; ) {
        bytes.write(buffer, 0, read);
      }
      result.success(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
    } catch (IOException error) {
      result.error("READ_FAILED", error.getMessage(), null);
    }
  }
}
