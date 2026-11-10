package ch.lkmc.ghost.keepalive;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;

/**
 * Foreground service anchoring the app's process while Dart reports live
 * work (SSH sessions for Seance, transfers for Poltergeist).
 *
 * Android freezes (and later kills) cached processes once they leave the
 * screen; a frozen process cannot service keepalives or open sockets, so
 * the work dies moments after the app is backgrounded. Running as a
 * dataSync foreground service keeps the process unfrozen, at the cost of
 * an ongoing notification the user can see (and switch off in Settings).
 *
 * All control flows through the companion-style statics {@link #start},
 * {@link #update} and {@link #stop}, called from the {@code
 * ghost_keepalive} method channel; this class itself only renders the
 * notification and stops when told. Every notification string arrives as
 * an intent extra, so the app owns the wording and the channel.
 */
public final class KeepAliveService extends Service {

    static final String EXTRA_CHANNEL_ID = "channelId";
    static final String EXTRA_CHANNEL_NAME = "channelName";
    static final String EXTRA_CHANNEL_DESCRIPTION = "channelDescription";
    static final String EXTRA_NOTIFICATION_TITLE = "notificationTitle";
    static final String EXTRA_NOTIFICATION_TEXT = "notificationText";
    static final String EXTRA_SMALL_ICON_RESOURCE_NAME = "smallIconResourceName";

    // Distinctive on purpose: notification ids share one app-wide space
    // with anything plugins post, and a collision with an ongoing
    // foreground notification misbehaves visibly.
    private static final int NOTIFICATION_ID = 7343;

    /** Whether the service is running; mutated only by its lifecycle. */
    private static volatile boolean isActive = false;

    /**
     * Starts anchoring. Always deliver a fresh start command rather than
     * short-circuit on {@code isActive}: stop() → onDestroy is asynchronous,
     * so a quick deactivate → activate (reconnect churn) could otherwise
     * see a stale true, only update the notification, and then die with the
     * teardown — silently unanchoring the process. Repeated starts are
     * idempotent; onStartCommand re-invokes startForeground with the
     * current strings.
     */
    static void start(Context context, Bundle args) {
        Intent intent = new Intent(context, KeepAliveService.class);
        intent.putExtras(args);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
    }

    /** Refreshes the running service's notification. */
    static void update(Context context, Bundle args) {
        if (!isActive) {
            // start() is asynchronous: a countChanged that lands between
            // startForegroundService() and onCreate() would otherwise be
            // dropped, leaving a stale notification. Re-deliver via start();
            // it is idempotent and carries the fresh strings.
            try {
                start(context, args);
            } catch (Exception ignored) {
                // Best-effort, matching how "activate" treats failures.
            }
            return;
        }
        context.getSystemService(NotificationManager.class)
                .notify(NOTIFICATION_ID, notification(context, args));
    }

    static void stop(Context context) {
        context.stopService(new Intent(context, KeepAliveService.class));
    }

    private static Notification notification(Context context, Bundle args) {
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(context, args.getString(EXTRA_CHANNEL_ID));
        } else {
            //noinspection deprecation
            builder = new Notification.Builder(context);
        }
        return builder
                .setContentTitle(args.getString(EXTRA_NOTIFICATION_TITLE))
                .setContentText(args.getString(EXTRA_NOTIFICATION_TEXT))
                .setSmallIcon(smallIcon(context, args.getString(EXTRA_SMALL_ICON_RESOURCE_NAME)))
                // Tap → back into the app: the notification is the feature's
                // most visible surface, and an untappable ongoing entry reads
                // as broken.
                .setContentIntent(contentIntent(context))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build();
    }

    private static int smallIcon(Context context, String resourceName) {
        int id = context.getResources()
                .getIdentifier(resourceName, "drawable", context.getPackageName());
        // The app's own icon when the named drawable is missing: better a
        // generic anchor notification than a crash (setSmallIcon(0) throws).
        return id != 0 ? id : context.getApplicationInfo().icon;
    }

    private static PendingIntent contentIntent(Context context) {
        return PendingIntent.getActivity(
                context,
                0,
                context.getPackageManager().getLaunchIntentForPackage(context.getPackageName()),
                PendingIntent.FLAG_IMMUTABLE);
    }

    private static boolean hasStrings(Bundle args) {
        return args != null
                && args.getString(EXTRA_CHANNEL_ID) != null
                && args.getString(EXTRA_CHANNEL_NAME) != null
                && args.getString(EXTRA_CHANNEL_DESCRIPTION) != null
                && args.getString(EXTRA_NOTIFICATION_TITLE) != null
                && args.getString(EXTRA_NOTIFICATION_TEXT) != null
                && args.getString(EXTRA_SMALL_ICON_RESOURCE_NAME) != null;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        isActive = true;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Bundle args = intent != null ? intent.getExtras() : null;
        if (!hasStrings(args)) {
            // Only the plugin starts this service, and always with its
            // strings; an intent without them cannot render a notification.
            stopSelf();
            return START_NOT_STICKY;
        }
        // The channel is ensured here (not in onCreate) because its name
        // and description arrive as intent extras; re-creating an existing
        // channel just updates them.
        ensureChannel(args);
        try {
            startForeground(NOTIFICATION_ID, notification(this, args));
        } catch (Exception error) {
            // E.g. the Android 15 dataSync daily budget is already spent, or
            // the start was disallowed: the anchor is best-effort, never
            // worth crashing the process (and every live session) over.
            stopSelf();
        }
        // Not sticky: only the Dart side knows whether work is still live;
        // a service restarted without it would be a zombie anchor.
        return START_NOT_STICKY;
    }

    private void ensureChannel(Bundle args) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationChannel channel = new NotificationChannel(
                args.getString(EXTRA_CHANNEL_ID),
                args.getString(EXTRA_CHANNEL_NAME),
                NotificationManager.IMPORTANCE_LOW);
        channel.setDescription(args.getString(EXTRA_CHANNEL_DESCRIPTION));
        getSystemService(NotificationManager.class).createNotificationChannel(channel);
    }

    @Override
    public void onTimeout(int startId) {
        // Variant delivered to apps targeting API ≤ 34; targetSdk 35+ gets
        // the two-argument overload below instead.
        stopAnchor();
    }

    @Override
    public void onTimeout(int startId, int fgsType) {
        stopAnchor();
    }

    private void stopAnchor() {
        // Recent Android caps dataSync foreground services (~6 h per day).
        // Stop cleanly: the app becomes freezable again and its work drops
        // exactly as it would without the anchor — the reconnect and retry
        // flows already cover that.
        stopSelf();
    }

    @Override
    public void onDestroy() {
        isActive = false;
        stopForeground(STOP_FOREGROUND_REMOVE);
        super.onDestroy();
    }
}
