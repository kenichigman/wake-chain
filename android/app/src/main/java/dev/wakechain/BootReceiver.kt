package dev.wakechain

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restarts the wake service after a reboot if it was enabled. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!WakePrefs(ctx).serviceEnabled) return
        try {
            ctx.startForegroundService(Intent(ctx, WakeService::class.java))
        } catch (_: Exception) {
            // System may refuse FGS start right at boot on some OEM builds;
            // the user can start it manually from the app.
        }
    }
}
