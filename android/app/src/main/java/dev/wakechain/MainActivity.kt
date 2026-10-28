package dev.wakechain

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast

class MainActivity : Activity() {

    private lateinit var prefs: WakePrefs
    private lateinit var statusView: TextView
    private lateinit var macField: EditText
    private lateinit var ssidField: EditText
    private lateinit var portField: EditText
    private lateinit var tokenView: TextView

    private val handler = Handler(Looper.getMainLooper())
    private val refresher = object : Runnable {
        override fun run() {
            renderStatus()
            handler.postDelayed(this, 2000)
        }
    }

    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)
        setContentView(R.layout.activity_main)
        prefs = WakePrefs(this)

        statusView = findViewById(R.id.statusView)
        macField = findViewById(R.id.macField)
        ssidField = findViewById(R.id.ssidField)
        portField = findViewById(R.id.portField)
        tokenView = findViewById(R.id.tokenView)

        macField.setText(prefs.mac)
        ssidField.setText(prefs.homeSsid)
        portField.setText(prefs.port.toString())
        renderToken()

        findViewById<Button>(R.id.copyTokenBtn).setOnClickListener {
            val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("Wake Chain token", prefs.token))
            toast("Token copied — give it to the wake requester")
        }
        findViewById<Button>(R.id.regenTokenBtn).setOnClickListener {
            renderToken(prefs.regenerateToken())
            toast("New token generated — update the requester")
        }
        findViewById<Button>(R.id.useCurrentBtn).setOnClickListener {
            val ssid = WifiUtil.currentSsid(this)
            if (ssid != null) {
                ssidField.setText(ssid)
                toast("SSID set to $ssid")
            } else {
                toast("Couldn't read SSID — grant location permission and turn location on")
            }
        }
        findViewById<Button>(R.id.startBtn).setOnClickListener {
            if (!saveFields()) return@setOnClickListener
            prefs.serviceEnabled = true
            startForegroundService(Intent(this, WakeService::class.java))
            toast("Service started")
        }
        findViewById<Button>(R.id.stopBtn).setOnClickListener {
            prefs.serviceEnabled = false
            stopService(Intent(this, WakeService::class.java))
            prefs.statusLine = "stopped"
            toast("Service stopped")
        }
        findViewById<Button>(R.id.wakeNowBtn).setOnClickListener {
            if (!saveFields()) return@setOnClickListener
            if (WakeService.isRunning) {
                startService(Intent(this, WakeService::class.java)
                    .setAction(WakeService.ACTION_WAKE_NOW))
                toast("Wake requested via service")
            } else {
                Thread {
                    val home = prefs.homeSsid.trim()
                    val cur = WifiUtil.currentSsid(this@MainActivity)
                    if (home.isEmpty() || cur == null || !cur.equals(home, ignoreCase = true)) {
                        runOnUiThread { toast("Not on home WiFi (now: ${cur ?: "none"})") }
                        return@Thread
                    }
                    try {
                        val n = WolSender.send(prefs.mac, WifiUtil.broadcastAddress(this@MainActivity))
                        runOnUiThread {
                            prefs.lastWake = "manual"
                            toast("Magic packet sent to $n targets")
                        }
                    } catch (e: Exception) {
                        runOnUiThread { toast("Failed: ${e.message}") }
                    }
                }.start()
            }
        }
        findViewById<Button>(R.id.batteryBtn).setOnClickListener {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            if (pm.isIgnoringBatteryOptimizations(packageName)) {
                toast("Already exempt")
            } else {
                try {
                    startActivity(Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:$packageName")))
                } catch (_: Exception) {
                    toast("Couldn't open settings — exempt manually")
                }
            }
        }

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 10)
        }
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION), 11)
        }
    }

    private fun renderToken(t: String = prefs.token) {
        tokenView.text = t
    }

    private fun validMac(s: String) =
        s.matches(Regex("^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$"))

    /** Saves fields; returns false (and saves nothing) when the MAC is malformed. */
    private fun saveFields(): Boolean {
        val mac = macField.text.toString().trim()
        if (!validMac(mac)) {
            toast("Invalid MAC — not saved (use six hex octets, colon-separated)")
            return false
        }
        prefs.mac = mac
        prefs.homeSsid = ssidField.text.toString().trim()
        prefs.port = portField.text.toString().toIntOrNull()?.coerceIn(1024, 65535) ?: 8765
        return true
    }

    private fun renderStatus() {
        val state = if (WakeService.isRunning) "RUNNING" else "STOPPED"
        val cur = try { WifiUtil.currentSsid(this) } catch (_: Exception) { "?" }
        statusView.text =
            "Service: $state (port ${prefs.port})\n" +
            "WiFi now: ${cur ?: "none"}\n" +
            "Last wake: ${prefs.lastWake}\n" +
            "Note: ${prefs.statusLine}\n" +
            "Error: ${prefs.lastError}"
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    override fun onResume() {
        super.onResume()
        handler.post(refresher)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(refresher)
    }
}
