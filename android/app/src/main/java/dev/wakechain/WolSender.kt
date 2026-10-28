package dev.wakechain

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/** Builds and broadcasts the Wake-on-LAN magic packet:
 *  6 x 0xFF followed by the target MAC repeated 16 times (102 bytes). */
object WolSender {

    /** Sends to 255.255.255.255:9, :7, and the subnet broadcast :9.
     *  Returns the number of targets the packet was sent to. */
    fun send(mac: String, subnetBroadcast: InetAddress?): Int {
        val macBytes = parseMac(mac)
        val packet = ByteArray(102)
        for (i in 0 until 6) packet[i] = 0xFF.toByte()
        for (i in 0 until 16) System.arraycopy(macBytes, 0, packet, 6 + i * 6, 6)

        val targets = mutableListOf<Pair<InetAddress, Int>>()
        val global = InetAddress.getByName("255.255.255.255")
        targets.add(global to 9)
        targets.add(global to 7)
        if (subnetBroadcast != null && subnetBroadcast.hostAddress != "255.255.255.255") {
            targets.add(subnetBroadcast to 9)
        }

        var sent = 0
        val socket = DatagramSocket()
        try {
            socket.broadcast = true
            for ((addr, port) in targets) {
                try {
                    socket.send(DatagramPacket(packet, packet.size, addr, port))
                    sent++
                } catch (_: Exception) { /* try remaining targets */ }
            }
        } finally {
            socket.close()
        }
        return sent
    }

    fun parseMac(mac: String): ByteArray {
        val parts = mac.trim().replace('-', ':').split(':')
        require(parts.size == 6) { "MAC must have 6 octets" }
        return ByteArray(6) { parts[it].toInt(16).toByte() }
    }
}
