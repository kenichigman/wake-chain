#!/bin/bash
# sleep_decider.sh — decide whether the workstation may sleep now.
#
# Design rules (each one is a scar from a real failure):
#   - EVERY exit path logs its verdict; an ERR trap logs unexpected death.
#     An earlier version silently died on most runs — a fragile nested-quote
#     SSH command under `set -e` exited before any log line, so the power
#     log showed runs starting and no verdict ever landing.
#   - One SSH read (host/idle_check.ps1) supplies idle_seconds, locked,
#     console_user, audio_active and wake_need_fresh — freshness is
#     computed on-box, because quoting a freshness test through ssh+cmd
#     from the requester side was the other silent-death cause.
#   - Sleep iff: no live leases AND reachable AND wake_need not fresh AND
#     no audio activity AND idle_seconds >= 600 — a quick check that there
#     has not been recent activity. Lock state is reported, not the gate.
#   - Audio playback counts as activity: leaving media playing keeps the
#     machine available. A missing audio_active field (older probe) parses
#     as not-true — pre-audio behavior, never stuck awake.
#   - Any check error: stay awake + log (fail closed, never silent).
#
# Configuration (environment): see wake_lease.sh (WAKE_POWER_LOG,
# WAKE_SSH_CMD, WAKE_REMOTE_DIR).
set -uo pipefail

POWER_LOG="${WAKE_POWER_LOG:-$HOME/.wake-chain/power.log}"
REMOTE_DIR="${WAKE_REMOTE_DIR:-C:\\wake-chain}"
IDLE_MIN_SECONDS=600
HERE="$(dirname "$0")"

mkdir -p "$(dirname "$POWER_LOG")"
run_ssh() { ${WAKE_SSH_CMD:-ssh workstation} "$@"; }

dlog() { echo "$(date '+%F %T %Z') DECIDER: $*" >> "$POWER_LOG"; }
trap 'dlog "DIED unexpectedly near line $LINENO — stayed awake by default"' ERR
stay() { dlog "STAYING AWAKE — $*"; exit 0; }

# 1. Live leases?
count=$("$HERE/wake_lease.sh" count 2>/dev/null) || stay "lease count failed"
if (( count > 0 )); then stay "$count live lease(s) present"; fi

# 2. Reachable? If not, there is nothing to sleep (already asleep/off).
if ! "$HERE/wake_lease.sh" probe; then
  dlog "workstation unreachable — nothing to do"
  exit 0
fi

# 3. One read: activity + wake_need (computed on-box by idle_check.ps1).
# Post-wake wrinkle: right after a resume the probe file's age includes the
# whole sleep, so it reads "stale" for up to one probe tick (~60s) even
# though the probe is healthy. On stale, wait out one tick and re-read
# ONCE; still stale = genuinely dead probe, fail closed.
read_state() { run_ssh "powershell -ExecutionPolicy Bypass -File ${REMOTE_DIR}\\idle_check.ps1" 2>/dev/null | tr -d '\r'; }
state=$(read_state) || stay "idle_check.ps1 call failed — fail closed"
if printf '%s' "$state" | grep -q '^error=stale'; then
  dlog "probe file stale — waiting 150s for a post-wake tick, re-reading once"
  sleep 150
  state=$(read_state) || stay "idle_check.ps1 re-read failed — fail closed"
fi
if printf '%s' "$state" | grep -q '^error='; then
  stay "idle_check reports: $(printf '%s' "$state" | grep '^error=' | head -1)"
fi
idle=$(printf '%s' "$state" | grep '^idle_seconds=' | cut -d= -f2)
locked=$(printf '%s' "$state" | grep '^locked=' | cut -d= -f2)
cuser=$(printf '%s' "$state" | grep '^console_user=' | cut -d= -f2)
need=$(printf '%s' "$state" | grep '^wake_need_fresh=' | cut -d= -f2)
audio=$(printf '%s' "$state" | grep '^audio_active=' | cut -d= -f2)
[[ "$idle" =~ ^[0-9]+$ ]] || stay "idle_seconds unparseable ('$idle') — fail closed"
if [[ "$need" == "true" ]]; then stay "wake_need flag fresh — a worker asked for the night"; fi
if [[ "$audio" == "true" ]]; then stay "audio playing — media counts as activity (user=$cuser)"; fi
if (( idle < IDLE_MIN_SECONDS )); then stay "recent activity ${idle}s ago (user=$cuser, locked=$locked)"; fi

# 4. All clear: sleep. On-box log line first (its own simple call), then
# the suspend in a separate call so the log write can never block it.
dlog "SLEEPING workstation — no leases, no fresh wake_need, no audio, idle ${idle}s (user=$cuser, locked=$locked)"
run_ssh "powershell -c \"Add-Content ${REMOTE_DIR}\\wake_log.txt 'SLEEP-DECIDER: idle ${idle}s, sleeping'\"" >/dev/null 2>&1 || dlog "on-box log write failed (continuing to sleep)"
run_ssh 'rundll32.exe powrprof.dll,SetSuspendState 0,1,0' >/dev/null 2>&1 || {
  dlog "sleep command failed — staying awake"
  exit 0
}
dlog "sleep command sent"
