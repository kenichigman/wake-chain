# Idle probe — runs INSIDE the interactive session (task WakeChain-IdleProbe, every 1 min).
# Writes C:\wake-chain\idle_status.txt: real last-input idle seconds + lock state + console user.
# Exists because GetLastInputInfo is meaningless from an SSH/session-0 context; the
# measurement has to happen in the session whose activity it describes.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class IdleTime {
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO lii);
  [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
  public static ulong IdleSeconds() {
    LASTINPUTINFO lii = new LASTINPUTINFO(); lii.cbSize = (uint)Marshal.SizeOf(lii);
    if (!GetLastInputInfo(ref lii)) return 0;
    ulong nowLow = GetTickCount64() & 0xFFFFFFFFUL;
    ulong last = lii.dwTime;
    ulong delta = (nowLow >= last) ? (nowLow - last) : (nowLow + 0x100000000UL - last);
    return delta / 1000UL;
  }
}
"@
$idle = [IdleTime]::IdleSeconds()
$locked = [bool](Get-Process logonui -ErrorAction SilentlyContinue)
$cuser = (Get-CimInstance Win32_ComputerSystem).UserName
$lines = @(
  "idle_seconds=$idle",
  "locked=$($locked.ToString().ToLower())",
  "console_user=$cuser",
  "updated=$(Get-Date -Format o)"
)
$tmp = "C:\wake-chain\idle_status.txt.tmp"
$lines | Set-Content -Path $tmp -Encoding ASCII
Move-Item -Path $tmp -Destination "C:\wake-chain\idle_status.txt" -Force
