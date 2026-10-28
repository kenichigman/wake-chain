# wol_listen.ps1 — PC-side Wake-on-LAN packet-arrival test
#
# Run on the workstation while it is AWAKE, then trigger the wake (tap
# "Wake now" in the Wake Chain app, or POST /wake). This splits the fault domain:
#   packet ARRIVES but PC won't wake from sleep -> NIC driver / BIOS problem
#   packet NEVER arrives                      -> Spectrum router WiFi->Ethernet
#                                              broadcast problem
#
# Usage: powershell -ExecutionPolicy Bypass -File wol_listen.ps1
#        (run in an elevated PowerShell is fine but not required for UDP recv)
param(
  [int]$Port = 9,            # app sends to :9 (global + subnet broadcast) and :7
  [int]$TimeoutSec = 90,
  [string]$ExpectedMac = "XX:XX:XX:XX:XX:XX"   # placeholder — set to the workstation's wired NIC MAC (see getmac)
)

$u = New-Object System.Net.Sockets.UdpClient($Port)
$u.Client.ReceiveTimeout = $TimeoutSec * 1000
$ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
Write-Host "listening on UDP $Port for ${TimeoutSec}s — trigger the wake from the phone now"

try {
  $b = $u.Receive([ref]$ep)
  Write-Host "got $($b.Length) bytes from $($ep.Address):$($ep.Port)"
  $isMagic = $b.Length -eq 102
  for ($i = 0; $i -lt 6 -and $isMagic; $i++) { if ($b[$i] -ne 255) { $isMagic = $false } }
  if ($isMagic) {
    $mac = (($b[6..11] | ForEach-Object { $_.ToString("X2") }) -join ":")
    Write-Host "MAGIC PACKET detected for MAC $mac"
    if ($mac -eq $ExpectedMac.ToUpper()) {
      Write-Host "MATCHES the workstation NIC ($ExpectedMac) — network path is fine, fault is PC-side"
    } else {
      Write-Host "WARNING: does not match expected $ExpectedMac — wrong adapter is being targeted"
    }
  } else {
    Write-Host "not a magic packet (wrong length/header)"
  }
} catch {
  Write-Host "TIMEOUT: no UDP packet arrived on port $Port — the router is not delivering broadcasts to this NIC"
} finally {
  $u.Close()
}
