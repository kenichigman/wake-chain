package dev.wakechain

import android.content.Context
import android.net.wifi.WifiManager
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder

object WifiUtil {

    /** Current WiFi SSID, or null if unavailable. Requires
     *  ACCESS_FINE_LOCATION on Android 10+ (and location turned on). */
    fun currentSsid(ctx: Context): String? {
        val wm = ctx.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as WifiManager
        var ssid = wm.connectionInfo?.ssid ?: return null
        if (ssid == "<unknown ssid>") return null
        if (ssid.length > 1 && ssid.startsWith("\"") && ssid.endsWith("\"")) {
            ssid = ssid.substring(1, ssid.length - 1)
        }
        return ssid.ifEmpty { null }
    }

    /** Subnet broadcast address from DHCP info (e.g. 192.168.1.255). */
    fun broadcastAddress(ctx: Context): InetAddress? {
        return try {
            val wm = ctx.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            val dhcp = wm.dhcpInfo ?: return null
            if (dhcp.ipAddress == 0 || dhcp.netmask == 0) return null
            val ip = Integer.reverseBytes(dhcp.ipAddress)
            val mask = Integer.reverseBytes(dhcp.netmask)
            val bcast = ip or mask.inv()
            val bytes = ByteBuffer.allocate(4)
                .order(ByteOrder.BIG_ENDIAN).putInt(bcast).array()
            InetAddress.getByAddress(bytes)
        } catch (_: Exception) {
            null
        }
    }
}
