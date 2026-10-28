package dev.wakechain

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Foreground service: keeps the HTTP wake trigger alive and shows a
 *  persistent notification. Triggered remotely by the wake requester over the tailnet. */
class WakeService : Service() {

    companion object {
        const val ACTION_WAKE_NOW = "dev.wakechain.WAKE_NOW"
        @Volatile var isRunning = false
        private const val CH = "wake_chain"
    }

    private lateinit var prefs: WakePrefs
    private var server: WakeHttpServer? = null

    private val timeFmt = DateTimeFormatter.ofPattern("MM-dd HH:mm:ss")
        .withZone(ZoneId.systemDefault())
    private fun nowStr() = timeFmt.format(Instant.now())

    // If the Tailscale interface isn't up when the service starts, retry
    // every 60s until the listener binds (fail-closed, self-healing).
    private val handler = Handler(Looper.getMainLooper())
    private val bindRetry = object : Runnable {
        override fun run() {
            if (server == null && prefs.serviceEnabled) {
                if (tryBind()) handler.removeCallbacks(this)
                else handler.postDelayed(this, 60_000)
            }
        }
    }

    /** Foreground promotion. The LOCATION type bit is included only while we
     *  hold ACCESS_FINE_LOCATION: on Android 14 declaring the location type
     *  without the runtime permission throws at startForeground time (e.g.
     *  service auto-started at boot after the user revoked it). Without the
     *  bit the SSID check degrades to fail-closed (wake refused), never a
     *  crash. minSdk 29, so the 3-arg startForeground is always available. */
    private fun startFg(notif: Notification) {
        val hasLoc = checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC or
            (if (hasLoc) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0)
        startForeground(1, notif, type)
    }

    /** Attempts to bind the HTTP trigger. Returns true when listening. */
    private fun tryBind(): Boolean {
        val port = prefs.port.coerceIn(1024, 65535)
        val s = WakeHttpServer(this, prefs, port)
        return if (s.start()) {
            server = s
            prefs.statusLine = "listening (tailnet)"
            startFg(buildNotif("listening (tailnet)"))
            true
        } else {
            prefs.statusLine = "waiting for tailnet…"
            startFg(buildNotif("waiting for tailnet…"))
            false
        }
    }

    override fun onCreate() {
        super.onCreate()
        prefs = WakePrefs(this)
        isRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        if (server == null && !tryBind()) handler.postDelayed(bindRetry, 60_000)
        if (intent?.action == ACTION_WAKE_NOW) Thread { wakeNow("manual") }.start()
        return START_STICKY
    }

    /** Manual wake: still gated on the home WiFi SSID, like the HTTP path. */
    private fun wakeNow(source: String) {
        val home = prefs.homeSsid.trim()
        val cur = WifiUtil.currentSsid(this)
        if (home.isEmpty() || cur == null || !cur.equals(home, ignoreCase = true)) {
            prefs.lastError = "${nowStr()}: not on home WiFi (now: ${cur ?: "none"})"
            return
        }
        try {
            val n = WolSender.send(prefs.mac, WifiUtil.broadcastAddress(this))
            prefs.lastWake = nowStr()
            prefs.lastError = "—"
            prefs.statusLine = "wake sent ($source, $n targets)"
        } catch (e: Exception) {
            prefs.lastError = "${nowStr()}: WOL failed: ${e.message?.take(120)}"
        }
    }

    private fun ensureChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH, "Wake Chain", NotificationManager.IMPORTANCE_LOW))
    }

    private fun buildNotif(text: String): Notification =
        Notification.Builder(this, CH)
            .setContentTitle("Wake Chain watching")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_launcher)
            .setOngoing(true)
            .build()

    override fun onDestroy() {
        handler.removeCallbacks(bindRetry)
        server?.stop()
        server = null
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
