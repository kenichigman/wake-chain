package dev.wakechain

import android.content.Context
import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors

/**
 * Minimal hand-rolled HTTP server for the wake trigger. No framework.
 *
 *   POST /wake   (Authorization: Bearer <token>) -> fires the magic packet
 *   GET  /status (Authorization: Bearer <token>) -> JSON service status
 *
 * Safety: POST /wake only fires when the phone is on the configured home
 * WiFi SSID. Anything else gets 409 and nothing is sent.
 */
class WakeHttpServer(
    private val ctx: Context,
    private val prefs: WakePrefs,
    private val port: Int
) {
    private val timeFmt = DateTimeFormatter.ofPattern("MM-dd HH:mm:ss")
        .withZone(ZoneId.systemDefault())

    @Volatile private var running = false
    private var server: ServerSocket? = null
    private var acceptThread: Thread? = null
    // Bounded pool: an unauthenticated client can open TCP connections, so
    // connection handling must not be able to exhaust threads (F1).
    private val pool = Executors.newFixedThreadPool(8)

    /** Address of the Tailscale interface (the CGNAT range used by the mesh VPN), or null when
     *  Tailscale is down. The trigger is only reachable over the tailnet —
     *  never the LAN in cleartext (F2). */
    private fun tailscaleAddress(): InetAddress? {
        return try {
            NetworkInterface.getNetworkInterfaces().asSequence()
                .flatMap { it.inetAddresses.asSequence() }
                .firstOrNull { a ->
                    !a.isLoopbackAddress && a is Inet4Address &&
                    a.address.let { b ->
                        (b[0].toInt() and 0xFF) == 100 &&
                        (b[1].toInt() and 0xFF) in 64..127
                    }
                }
        } catch (_: Exception) { null }
    }

    /** Minimal JSON string escaper for interpolated values (F3). */
    private fun jsonStr(s: String): String {
        val sb = StringBuilder("\"")
        for (c in s) when (c) {
            '"' -> sb.append("\\\"")
            '\\' -> sb.append("\\\\")
            '\n' -> sb.append("\\n")
            '\r' -> sb.append("\\r")
            '\t' -> sb.append("\\t")
            else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
        }
        return sb.append('"').toString()
    }

    /** Starts the listener. Returns false (fail-closed) when the Tailscale
     *  interface is absent — the caller should retry later. */
    fun start(): Boolean {
        if (running) return true
        val bindAddr = tailscaleAddress()
        if (bindAddr == null) {
            val msg = "mesh VPN interface not found — HTTP trigger not started"
            Log.w(TAG, msg)
            prefs.lastError = "${nowStr()}: $msg"
            return false
        }
        running = true
        acceptThread = Thread({
            try {
                // reuseAddress BEFORE bind, or it silently no-ops (F5).
                server = ServerSocket().also {
                    it.reuseAddress = true
                    it.bind(InetSocketAddress(bindAddr, port))
                }
                Log.i(TAG, "listening on ${bindAddr.hostAddress}:$port (tailnet only)")
                while (running) {
                    try {
                        val sock = server!!.accept()
                        pool.execute { handle(sock) }
                    } catch (e: Exception) {
                        if (running) Log.w(TAG, "accept failed: ${e.message}")
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "server failed: ${e.message}")
                prefs.lastError = "${nowStr()}: HTTP server failed: ${e.message?.take(120)}"
                running = false
            }
        }, "wakechain-accept").also { it.start() }
        return true
    }

    fun stop() {
        running = false
        try { server?.close() } catch (_: Exception) {}
        acceptThread?.interrupt()
        pool.shutdownNow()
    }

    private fun handle(sock: Socket) {
        try {
            sock.soTimeout = 10_000
            val reader = BufferedReader(InputStreamReader(sock.getInputStream(), StandardCharsets.UTF_8))
            val requestLine = reader.readLine()?.take(4096) ?: return
            val parts = requestLine.split(" ")
            if (parts.size < 2) return
            val method = parts[0].uppercase()
            val path = parts[1].substringBefore("?")

            // Bounded header parsing: an unauthenticated client must not be
            // able to hold resources with a drip-feed (F1).
            val headers = mutableMapOf<String, String>()
            var headerCount = 0
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) break
                if (++headerCount > 32 || line.length > 8192) return
                val idx = line.indexOf(':')
                if (idx > 0) headers[line.substring(0, idx).trim().lowercase()] =
                    line.substring(idx + 1).trim()
            }
            // Drain a POST body if present so the socket stays clean.
            (headers["content-length"]?.toIntOrNull() ?: 0).let { n ->
                var left = n.coerceAtMost(4096)
                while (left > 0) {
                    val skipped = reader.skip(left.toLong())
                    if (skipped <= 0) break
                    left -= skipped.toInt()
                }
            }

            val authed = checkAuth(headers["authorization"])
            val out = sock.getOutputStream()
            when {
                !authed -> respond(out, 401, """{"error":"unauthorized"}""")
                method == "POST" && path == "/wake" -> onWake(out)
                method == "GET" && path == "/status" -> onStatus(out)
                else -> respond(out, 404, """{"error":"not_found"}""")
            }
            out.flush()
        } catch (e: Exception) {
            Log.w(TAG, "conn failed: ${e.message}")
        } finally {
            try { sock.close() } catch (_: Exception) {}
        }
    }

    private fun checkAuth(header: String?): Boolean {
        if (header == null) return false
        val expected = "Bearer ${prefs.token}"
        // Constant-time compare to avoid timing side-channels.
        if (header.length != expected.length) return false
        var diff = 0
        for (i in header.indices) diff = diff or (header[i].code xor expected[i].code)
        return diff == 0
    }

    private fun onWake(out: OutputStream) {
        val home = prefs.homeSsid.trim()
        val cur = WifiUtil.currentSsid(ctx)
        if (home.isEmpty() || cur == null || !cur.equals(home, ignoreCase = true)) {
            val ssidJson = cur?.let { jsonStr(it) } ?: "null"
            prefs.statusLine = "wake refused — off home WiFi (now: ${cur ?: "none"})"
            respond(out, 409,
                """{"woke":false,"reason":"not_on_home_wifi","ssid":$ssidJson}""")
            return
        }
        val n = try {
            WolSender.send(prefs.mac, WifiUtil.broadcastAddress(ctx))
        } catch (e: Exception) {
            prefs.lastError = "${nowStr()}: WOL failed: ${e.message?.take(120)}"
            respond(out, 500, """{"woke":false,"reason":"send_failed"}""")
            return
        }
        prefs.lastWake = nowStr()
        prefs.lastError = "—"
        prefs.statusLine = "wake sent via HTTP ($n targets)"
        respond(out, 200, """{"woke":true,"targets":$n}""")
    }

    private fun onStatus(out: OutputStream) {
        val cur = WifiUtil.currentSsid(ctx)
        val home = prefs.homeSsid.trim()
        val onHome = home.isNotEmpty() && cur != null && cur.equals(home, ignoreCase = true)
        val ssidJson = cur?.let { jsonStr(it) } ?: "null"
        val lastWakeJson = prefs.lastWake.let {
            if (it == "—") "null" else jsonStr(it)
        }
        respond(out, 200,
            """{"on_home_wifi":$onHome,"ssid":$ssidJson,"last_wake":$lastWakeJson,"service":"wake-chain","version":"1.0"}""")
    }

    private fun respond(out: OutputStream, code: Int, body: String) {
        val bytes = body.toByteArray(StandardCharsets.UTF_8)
        val head = "HTTP/1.1 $code ${reason(code)}\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: ${bytes.size}\r\n" +
            "Connection: close\r\n\r\n"
        out.write(head.toByteArray(StandardCharsets.US_ASCII))
        out.write(bytes)
    }

    private fun reason(code: Int) = when (code) {
        200 -> "OK"; 401 -> "Unauthorized"; 404 -> "Not Found"
        409 -> "Conflict"; 500 -> "Internal Server Error"; else -> "Error"
    }

    private fun nowStr() = timeFmt.format(Instant.now())

    companion object { private const val TAG = "WakeChainHttp" }
}
