# WakeChain-Overnight check (v2). The WakeChain-Overnight task wakes the
# box at 02:15 (WakeToRun) and runs this as SYSTEM; it decides whether the box may go
# back to sleep: stay awake iff wake_need.txt is fresh (a worker asked for the night)
# or the user has been active within 10 minutes, per C:\wake-chain\idle_status.txt (written
# every minute by the WakeChain-IdleProbe task in the interactive session).
# v1's test — "an explorer.exe process exists" — was always true on this
# never-logged-out machine, so v1 NEVER re-slept after the rebuild. The suspend call
# also converged to the decider's rundll32 form (v1 used WinForms SetSuspendState).
# v2.1: audio playback also counts as activity —
# audio_active=true in idle_status.txt (probe loop v2, Core Audio meters) keeps
# the box awake, matching the sleep decider's v2.1 rule. A missing audio_active
# field (older probe) reads as inactive: pre-v2.1 behavior, never stuck awake.
$flag = "C:\wake-chain\wake_need.txt"
function Test-FlagFresh {
  if (-not (Test-Path $flag)) { return $false }
  try {
    $c = (Get-Content $flag -Raw).Trim()
    if ($c -eq (Get-Date -Format "yyyy-MM-dd")) { return $true }
  } catch {}
  return ((Get-Item $flag).LastWriteTime -gt (Get-Date).AddHours(-12))
}
function Get-IdleSeconds {
  $f = "C:\wake-chain\idle_status.txt"
  if (-not (Test-Path $f)) { return -1 }
  if (((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds -gt 180) { return -1 }
  $line = Get-Content $f | Where-Object { $_ -like "idle_seconds=*" } | Select-Object -First 1
  if (-not $line) { return -1 }
  return [int]($line -replace "idle_seconds=", "")
}
function Get-AudioActive {
  $f = "C:\wake-chain\idle_status.txt"
  if (-not (Test-Path $f)) { return $false }
  if (((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds -gt 180) { return $false }
  $line = Get-Content $f | Where-Object { $_ -like "audio_active=*" } | Select-Object -First 1
  if (-not $line) { return $false }
  return (($line -replace "audio_active=", "") -eq "true")
}
if (Test-FlagFresh) { exit 0 }
Start-Sleep -Seconds 45
if (Test-FlagFresh) { exit 0 }
$idle = Get-IdleSeconds
# Post-wake probe lag: this checker runs right after the 02:15 resume, when
# idle_status.txt still carries its pre-sleep timestamp (the probe ticks every
# 60s in-session). One extra wait + re-read before treating unknown as active.
if ($idle -lt 0) { Start-Sleep -Seconds 90; $idle = Get-IdleSeconds }
if ($idle -lt 0 -or $idle -lt 600) { exit 0 }
if (Get-AudioActive) { exit 0 }
rundll32.exe powrprof.dll,SetSuspendState 0,1,0
