# Idle check — SSH-side reader for the sleep decider.
# Emits key=value lines for the VM-side decider: the probe's fields, plus
# wake_need_fresh computed on-box (quoting a freshness test through ssh+cmd from the
# VM side was the decider's other silent-death cause — compute it here instead).
$f = "C:\wake-chain\idle_status.txt"
if (-not (Test-Path $f)) { "error=missing"; }
else {
  $age = ((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds
  if ($age -gt 180) { "error=stale age_s=$([int]$age)" }
  Get-Content $f
}
$flag = "C:\wake-chain\wake_need.txt"
$fresh = $false
if (Test-Path $flag) {
  try {
    $c = (Get-Content $flag -Raw).Trim()
    if ($c -eq (Get-Date -Format "yyyy-MM-dd")) { $fresh = $true }
  } catch {}
  if (-not $fresh) { $fresh = ((Get-Item $flag).LastWriteTime -gt (Get-Date).AddHours(-12)) }
}
"wake_need_fresh=$($fresh.ToString().ToLower())"
