package ch.lkmc.ghost.keepalive;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * The Dart side of the keep-alive: forwards the {@code ghost_keepalive}
 * channel's activate / countChanged / deactivate calls to {@link
 * KeepAliveService}, carrying the app's notification strings with every
 * count-carrying call (the service is stateless across restarts, so the
 * notification is always rebuilt from the call's arguments).
 */
public final class GhostKeepAlivePlugin
        implements FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private static final String CHANNEL = "ghost_keepalive";
    private static final int REQUEST_POST_NOTIFICATIONS = 7342;

    // Static (not an instance field): the plugin is re-created with every
    // engine attach, and the ask is once per process, at the first anchor.
    private static volatile boolean notificationPermissionAsked = false;

    private Context applicationContext;
    private Activity activity;
    private MethodChannel channel;

    @Override
    public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {
        applicationContext = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
        // Config detach can precede engine destruction without the normal
        // activity-detach callback. Dead Dart cannot release the anchor.
        if (applicationContext != null) {
            KeepAliveService.stop(applicationContext);
        }
        applicationContext = null;
    }

    @Override
    public void onAttachedToActivity(ActivityPluginBinding binding) {
        activity = binding.getActivity();
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) {
        activity = binding.getActivity();
    }

    @Override
    public void onDetachedFromActivity() {
        activity = null;
        // The Flutter engine is torn down with the activity, so Dart can no
        // longer manage the anchor — drop it rather than linger as an empty
        // foreground service. (Swiping the app away ends here; the work it
        // held dies with the engine.)
        if (applicationContext != null) {
            KeepAliveService.stop(applicationContext);
        }
    }

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "activate":
                activate(call, result);
                break;
            case "countChanged":
                countChanged(call, result);
                break;
            case "deactivate":
                KeepAliveService.stop(context());
                result.success(null);
                break;
            default:
                result.notImplemented();
        }
    }

    private void activate(MethodCall call, MethodChannel.Result result) {
        Bundle args = strings(call);
        Integer count = count(call);
        if (args == null || count == null || count < 0) {
            result.error(
                    "INVALID_ARGUMENT",
                    "count and the notification strings are required.",
                    null);
            return;
        }
        try {
            KeepAliveService.start(context(), args);
            requestNotificationPermissionOnce();
            result.success(null);
        } catch (Exception error) {
            // E.g. Android 12+ forbidding a foreground-service start from
            // the background; Dart treats this as best-effort.
            result.error(
                    "KEEP_ALIVE_FAILED",
                    "Could not start the keep-alive service: " + error.getMessage(),
                    null);
        }
    }

    private void countChanged(MethodCall call, MethodChannel.Result result) {
        Bundle args = strings(call);
        Integer count = count(call);
        if (args == null || count == null || count < 0) {
            result.error(
                    "INVALID_ARGUMENT",
                    "count and the notification strings are required.",
                    null);
            return;
        }
        KeepAliveService.update(context(), args);
        result.success(null);
    }

    private static Integer count(MethodCall call) {
        return (Integer) call.argument("count");
    }

    private static Bundle strings(MethodCall call) {
        String channelId = call.argument("channelId");
        String channelName = call.argument("channelName");
        String channelDescription = call.argument("channelDescription");
        String notificationTitle = call.argument("notificationTitle");
        String notificationText = call.argument("notificationText");
        String smallIconResourceName = call.argument("smallIconResourceName");
        if (channelId == null || channelName == null || channelDescription == null
                || notificationTitle == null || notificationText == null
                || smallIconResourceName == null) {
            return null;
        }
        Bundle args = new Bundle();
        args.putString(KeepAliveService.EXTRA_CHANNEL_ID, channelId);
        args.putString(KeepAliveService.EXTRA_CHANNEL_NAME, channelName);
        args.putString(KeepAliveService.EXTRA_CHANNEL_DESCRIPTION, channelDescription);
        args.putString(KeepAliveService.EXTRA_NOTIFICATION_TITLE, notificationTitle);
        args.putString(KeepAliveService.EXTRA_NOTIFICATION_TEXT, notificationText);
        args.putString(KeepAliveService.EXTRA_SMALL_ICON_RESOURCE_NAME, smallIconResourceName);
        return args;
    }

    private Context context() {
        // The activity when there is one (the foreground-service start and
        // the permission ask both want it); the application context keeps
        // teardown-time calls working after the activity is gone.
        return activity != null ? activity : applicationContext;
    }

    /**
     * The keep-alive's foreground-service notification is invisible on
     * Android 13+ without POST_NOTIFICATIONS; the service runs either way,
     * but a hidden notification reads as unexplained battery use. Ask once
     * per process, at the first anchor, and take no for an answer.
     */
    private void requestNotificationPermissionOnce() {
        if (activity == null) return;
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return;
        if (notificationPermissionAsked) return;
        notificationPermissionAsked = true;
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED) return;
        activity.requestPermissions(
                new String[]{Manifest.permission.POST_NOTIFICATIONS},
                REQUEST_POST_NOTIFICATIONS);
    }
}
