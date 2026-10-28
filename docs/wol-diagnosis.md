# Wake-on-LAN diagnosis order

For the failure "the phone says the packet was sent, the PC stays asleep."
Worked example throughout: the target is a workstation on wired Ethernet,
the phone is on the home WiFi, the target MAC is the wired NIC's.

Proven facts in the reference deployment: the app sends 3 magic packets
per wake (global broadcast :9 and :7, plus the subnet broadcast :9 — see
`WolSender.kt`), the app reports `on_home_wifi: true` with the correct
SSID, the target MAC is verified against the NIC — and the PC still did
not wake from S3 sleep. The diagnosis order below is what separated the
causes.

## 1. Fault-domain split FIRST (one test, before touching settings)

On the workstation while AWAKE, run `tools/wol_listen.ps1`, then tap
"Wake now" in the phone app. Then:

- packet arrives → skip to section 2 (PC-side: NIC/BIOS)
- never arrives → skip to section 3 (router-side)

## 2. PC-side checklist (packet arrives but no wake)

Device Manager → the wired NIC → Advanced tab:

- "Wake on Magic Packet" = Enabled
- "Shutdown Wake-On-Lan" = Enabled (matters for shutdown tests later)
- "Wake on pattern match" = Enabled
- "Energy Efficient Ethernet" / "Green Ethernet" = Disabled
  (if the link LED goes dark on sleep, the PHY can't hear the packet)

Power Management tab:

- BOTH checked: "Allow the computer to turn off this device to save
  power" AND "Allow this device to wake the computer" (unchecking the
  first keeps the NIC in D0 and can prevent D3-wake)

BIOS (exact names vary by vendor):

- ErP Ready = Disabled (ErP cuts NIC power in S3/S4/S5)
- Wake on LAN / "Power On By PCI-E" = Enabled

Verify the right adapter: `ipconfig /all` — the Ethernet adapter carrying
the LAN must show the MAC the phone targets. If the packet targets a
virtual NIC's MAC (mesh VPN, hypervisor), nothing wakes.

PowerShell checks (admin):

```powershell
powercfg /devicequery wake_from_S3_supported   # wired adapter listed?
powercfg /devicequery wake_armed               # armed right now?
powercfg /lastwake                             # after a failed test, empty = never armed
```

Note: Windows "Fast Startup" breaks WOL from SHUTDOWN (hybrid S4), not
from S3 sleep — only relevant if testing with shutdown instead of sleep.

## 3. Router-side checklist (packet never arrives)

The magic packet must cross WiFi (phone) → Ethernet (workstation) as a
broadcast. Suspects, in order: client/AP isolation on the WiFi network,
multicast filtering, separate 2.4/5 GHz segments with isolation, or a
guest SSID. If isolation is the cause and the router offers no toggle,
the workaround is a wired sender — a tiny always-on device on Ethernet
that relays the packet onto the LAN.
