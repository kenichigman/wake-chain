package dev.wakechain

import android.content.Context
import android.content.SharedPreferences
import java.security.SecureRandom

/** App settings + runtime state. No secrets leave the device; the bearer
 *  token lives only here, shown in the app UI, never in code. */
class WakePrefs(ctx: Context) {
    private val sp: SharedPreferences =
        ctx.getSharedPreferences("wake_chain", Context.MODE_PRIVATE)

    var mac: String
        get() = sp.getString("mac", "") ?: ""
        set(v) = sp.edit().putString("mac", v).apply()

    var homeSsid: String
        get() = sp.getString("ssid", "") ?: ""
        set(v) = sp.edit().putString("ssid", v).apply()

    var port: Int
        get() = sp.getInt("port", 8765)
        set(v) = sp.edit().putInt("port", v).apply()

    /** Bearer token for the HTTP trigger. Generated once on first launch. */
    var token: String
        get() {
            var t = sp.getString("token", null)
            if (t.isNullOrEmpty()) {
                t = newToken()
                sp.edit().putString("token", t).apply()
            }
            return t
        }
        set(v) = sp.edit().putString("token", v).apply()

    fun regenerateToken(): String {
        val t = newToken()
        sp.edit().putString("token", t).apply()
        return t
    }

    var serviceEnabled: Boolean
        get() = sp.getBoolean("service_enabled", false)
        set(v) = sp.edit().putBoolean("service_enabled", v).apply()

    var lastWake: String
        get() = sp.getString("last_wake", "—") ?: "—"
        set(v) = sp.edit().putString("last_wake", v).apply()

    var lastError: String
        get() = sp.getString("last_error", "—") ?: "—"
        set(v) = sp.edit().putString("last_error", v).apply()

    var statusLine: String
        get() = sp.getString("status", "stopped") ?: "stopped"
        set(v) = sp.edit().putString("status", v).apply()

    companion object {
        fun newToken(): String {
            val bytes = ByteArray(32)
            SecureRandom().nextBytes(bytes)
            return bytes.joinToString("") { "%02x".format(it) }
        }
    }
}
