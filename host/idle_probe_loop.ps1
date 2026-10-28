# Idle probe loop — resident in the interactive session (task
# WakeChain-IdleProbe, ONLOGON trigger). Writes C:\wake-chain\idle_status.txt every ~45s:
# real last-input idle seconds + lock state + console user + audio_active.
#
# Why a loop and not a per-minute scheduled task: schtasks /sc minute silently
# created a repetition with Duration PT10M — the probe would have stopped
# ticking 10 minutes after creation (found the hard way). A
# resident loop has no cadence for the scheduler to break; suspend pauses it
# with the machine and it resumes writing on wake. If the loop ever dies, the
# status file goes stale and the sleep decider fails closed (never silent).
#
# audio_active (v2): media playback counts as activity. The owner's habit
# is to leave media playing on the PC when heading out so remote work keeps
# access; the input-idle timer alone marked the machine idle and the
# decider slept it mid-playback (observed: idle 2692s while audio played).
# v2.1 detection: audio_active = any audio
# session on the default render endpoint in state Active (IAudioSessionControl
# ::GetState == 1), sampled every ~5s, held for 150s (covers gaps between
# tracks; a pause longer than 150s correctly reads inactive). v2.0 tried
# IAudioMeterInformation peak meters first — dead end: the IID used for it
# (C02216F6-...) is not offered by this machine's devices or sessions
# (Activate returned E_NOINTERFACE, session casts returned null), while
# GetState worked on every call. Session state needs no meter interface.
# Coverage: the default (multimedia) endpoint only — that is where Spotify
# renders on this machine (verified: its session, pid-matched, state Active
# while playing). Any detector error reads as inactive — the pre-v2 behavior, never
# a stuck-on "active" that would keep the box awake forever.
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
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject { }
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
  [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, IntPtr devices);
  [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
  [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
}
[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioSessionManager2 {
  [PreserveSig] int GetAudioSessionControl(IntPtr iid, int sessionFlags, IntPtr sessionControl);
  [PreserveSig] int GetSimpleAudioVolume(IntPtr iid, int sessionFlags, IntPtr audioVolume);
  [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnum);
}
[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioSessionEnumerator {
  [PreserveSig] int GetCount(out int count);
  [PreserveSig] int GetSession(int index, out IAudioSessionControl session);
}
[ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioSessionControl {
  [PreserveSig] int GetState(out int state);
}
public static class AudioActivity {
  // True iff any session on the default render endpoint is in state
  // AudioSessionStateActive (1). All failures read as inactive.
  public static bool AnyActive() {
    object enumerator = null, device = null, manager = null, sessions = null;
    try {
      enumerator = new MMDeviceEnumeratorComObject();
      IMMDevice dev;
      if (((IMMDeviceEnumerator)enumerator).GetDefaultAudioEndpoint(0, 1, out dev) != 0 || dev == null) return false;
      device = dev;
      Guid iid = typeof(IAudioSessionManager2).GUID;
      object mgrObj;
      if (dev.Activate(ref iid, 23, IntPtr.Zero, out mgrObj) != 0 || mgrObj == null) return false;
      manager = mgrObj;
      IAudioSessionEnumerator sessionEnum;
      if (((IAudioSessionManager2)mgrObj).GetSessionEnumerator(out sessionEnum) != 0 || sessionEnum == null) return false;
      sessions = sessionEnum;
      int count;
      if (sessionEnum.GetCount(out count) != 0) return false;
      for (int i = 0; i < count; i++) {
        IAudioSessionControl ctl;
        if (sessionEnum.GetSession(i, out ctl) != 0 || ctl == null) continue;
        try {
          int state;
          if (ctl.GetState(out state) == 0 && state == 1) return true;
        } finally { Marshal.ReleaseComObject(ctl); }
      }
      return false;
    } catch { return false; }
    finally {
      if (sessions != null) Marshal.ReleaseComObject(sessions);
      if (manager != null) Marshal.ReleaseComObject(manager);
      if (device != null) Marshal.ReleaseComObject(device);
      if (enumerator != null) Marshal.ReleaseComObject(enumerator);
    }
  }
}
"@
$lastHeard = [DateTime]::MinValue
$nextWrite = Get-Date
while ($true) {
  try { if ([AudioActivity]::AnyActive()) { $lastHeard = Get-Date } } catch {}
  if ((Get-Date) -ge $nextWrite) {
    try {
      $idle = [IdleTime]::IdleSeconds()
      $locked = [bool](Get-Process logonui -ErrorAction SilentlyContinue)
      $cuser = (Get-CimInstance Win32_ComputerSystem).UserName
      $audio = ((Get-Date) - $lastHeard).TotalSeconds -lt 150
      $lines = @(
        "idle_seconds=$idle",
        "locked=$($locked.ToString().ToLower())",
        "console_user=$cuser",
        "audio_active=$($audio.ToString().ToLower())",
        "updated=$(Get-Date -Format o)"
      )
      $tmp = "C:\wake-chain\idle_status.txt.tmp"
      $lines | Set-Content -Path $tmp -Encoding ASCII
      Move-Item -Path $tmp -Destination "C:\wake-chain\idle_status.txt" -Force
    } catch {}
    $nextWrite = (Get-Date).AddSeconds(45)
  }
  Start-Sleep -Seconds 5
}
