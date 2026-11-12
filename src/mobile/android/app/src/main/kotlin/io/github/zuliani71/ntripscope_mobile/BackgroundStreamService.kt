package io.github.zuliani71.ntripscope_mobile

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** A user-enabled, non-restarting lease for a live GNSS session, not a keep-screen-on flag. */
class BackgroundStreamService : Service() {
    companion object {
        const val STOP = "io.github.zuliani71.ntripscope_mobile.STOP_STREAM"
        private const val CHANNEL = "ntripscope_stream"
        private const val ID = 401
        @Volatile var running = false
            private set
        var requested = false
        var ready: ((String?) -> Unit)? = null
        val stopped = mutableListOf<() -> Unit>()
        var onStopRequested: (() -> Unit)? = null
    }
    private var cpu: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "GNSS streaming", NotificationManager.IMPORTANCE_LOW))
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            requested = false
            onStopRequested?.invoke()
            finish()
            return START_NOT_STICKY
        }
        try {
            val open = PendingIntent.getActivity(this, 0,
                Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val stop = PendingIntent.getService(this, 1,
                Intent(this, BackgroundStreamService::class.java).setAction(STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
            val notification = builder.setContentTitle("NTRIP Scope · screen-off mode")
                .setContentText("GNSS session · ${intent?.getStringExtra("mountpoint") ?: "NTRIP"}")
                .setSmallIcon(R.drawable.ic_stat_stream).setContentIntent(open)
                .setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
                .addAction(Notification.Action.Builder(null, "Stop", stop).build()).build()
            if (Build.VERSION.SDK_INT >= 29) startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            else startForeground(ID, notification)
            if (!requested) {
                ready?.invoke("Streaming was cancelled"); ready = null
                finish(); return START_NOT_STICKY
            }
            if (cpu == null) {
                cpu = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "NTRIPScope:stream").apply {
                    setReferenceCounted(false); acquire()
                }
                // Optional on mobile-data-only devices; never turns Wi-Fi on.
                runCatching {
                    wifi = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager)
                        .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "NTRIPScope:stream").apply {
                            setReferenceCounted(false); acquire()
                        }
                }
            }
            running = true
            ready?.invoke(null); ready = null
        } catch (error: Exception) {
            requested = false
            ready?.invoke(error.localizedMessage ?: "Cannot start screen-off streaming"); ready = null
            finish()
        }
        return START_NOT_STICKY
    }
    private fun finish() {
        release()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
    private fun release() {
        running = false
        runCatching { if (wifi?.isHeld == true) wifi?.release() }; wifi = null
        runCatching { if (cpu?.isHeld == true) cpu?.release() }; cpu = null
    }
    override fun onTaskRemoved(rootIntent: Intent?) {
        requested = false
        onStopRequested?.invoke()
        finish()
        super.onTaskRemoved(rootIntent)
    }
    override fun onDestroy() {
        val unexpected = requested
        requested = false
        release()
        ready?.invoke("Streaming service stopped"); ready = null
        if (unexpected) onStopRequested?.invoke()
        val callbacks = stopped.toList(); stopped.clear()
        callbacks.forEach { it() }
        super.onDestroy()
    }
}
