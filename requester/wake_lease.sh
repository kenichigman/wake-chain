#!/bin/bash
# wake_lease.sh — reference-counted wake leases for a workstation.
#
# A lease means "a worker needs the workstation awake right now." The last
# release triggers the sleep decider (sleep_decider.sh), which may put the
# machine back to sleep — but only when nobody is using it.
#
# Usage:
#   wake_lease.sh acquire <worker-id> [--wake]  — take a lease; --wake fires
#       the phone wake chain (request_wake.sh) if the workstation is
#       unreachable, then waits up to ~120s for SSH. Without --wake, an
#       unreachable workstation is exit 3 (caller degrades gracefully,
#       never fails hard).
#   wake_lease.sh release <worker-id>           — drop a lease; if zero live
#       leases remain, runs the sleep decider.
#   wake_lease.sh list                          — live leases (id + age).
#   wake_lease.sh count                         — number of live leases.
#   wake_lease.sh probe                         — exit 0 if SSH reachable.
#
# Stale leases (>4h) are treated as dead (crashed-worker safety) and pruned.
#
# wake_need bridge: the on-box overnight checker (host/wake_check.ps1) is
# lease-blind — on its repeating trigger it suspends the machine whenever
# the wake_need flag is not fresh, idle >= 600s and no audio, even with
# leases held (this once slept the machine 7 minutes after a wake, with
# work in flight). So: every successful acquire also stamps wake_need.txt
# on the box with today's date (the checker's own "a worker asked" input;
# date content = fresh all day), and the last release clears the stamp
# before the decider runs. Both are best-effort and logged — a failed
# stamp must never fail a lease, but it must never be silent either.
#
# Configuration (environment):
#   WAKE_LEASE_DIR   lease state dir   (default ~/.wake-chain/leases)
#   WAKE_POWER_LOG   power log file    (default ~/.wake-chain/power.log)
#   WAKE_SSH_CMD     ssh command line to reach the workstation
#                    (default "ssh workstation")
#   WAKE_REMOTE_DIR  on-box install dir (default C:\wake-chain)
set -euo pipefail

LEASE_DIR="${WAKE_LEASE_DIR:-$HOME/.wake-chain/leases}"
POWER_LOG="${WAKE_POWER_LOG:-$HOME/.wake-chain/power.log}"
REMOTE_DIR="${WAKE_REMOTE_DIR:-C:\\wake-chain}"
STALE_SECS=14400  # 4h

mkdir -p "$LEASE_DIR" "$(dirname "$POWER_LOG")"

# Run a command on the workstation over SSH.
run_ssh() { ${WAKE_SSH_CMD:-ssh workstation} "$@"; }

sanitize() { printf '%s' "$1" | tr -cd 'a-zA-Z0-9_.-'; }

plog() { echo "$(date '+%F %T %Z') LEASE: $*" >> "$POWER_LOG"; }

# Remove leases older than STALE_SECS.
prune_stale() {
  local pruned=0 f age now
  now=$(date +%s)
  for f in "$LEASE_DIR"/*.lease; do
    [[ -e "$f" ]] || continue
    age=$(( now - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    if (( age > STALE_SECS )); then
      plog "pruning stale lease $(basename "$f" .lease) (age ${age}s)"
      rm -f "$f"; (( pruned++ )) || true
    fi
  done
  return 0
}

# Fast SSH reachability probe. Exit 0 reachable, 1 not.
do_probe() {
  timeout 30 run_ssh 'echo ok' >/dev/null 2>&1
}

# Stamp the on-box wake_need.txt with the box's own today's date. Best effort.
stamp_wake_need() {
  if timeout 30 run_ssh "powershell -NoProfile -Command \"Set-Content -Path ${REMOTE_DIR}\\wake_need.txt -Value (Get-Date -Format 'yyyy-MM-dd') -NoNewline\"" >/dev/null 2>&1; then
    plog "wake_need stamped (lease bridge)"
  else
    plog "WARN: wake_need stamp FAILED — on-box wake_check may sleep the box despite leases"
  fi
}

# Clear the stamp on last release. Only removes the file when its content is
# exactly a yyyy-MM-dd date (our stamp format) — a hand-written flag with any
# other content is left alone. Best effort.
clear_wake_need() {
  if timeout 30 run_ssh "powershell -NoProfile -Command \"if (Test-Path ${REMOTE_DIR}\\wake_need.txt) { \$c = (Get-Content ${REMOTE_DIR}\\wake_need.txt -Raw).Trim(); if (\$c -match '^\\d{4}-\\d{2}-\\d{2}\$') { Remove-Item ${REMOTE_DIR}\\wake_need.txt } }\"" >/dev/null 2>&1; then
    plog "wake_need cleared (last release)"
  else
    plog "WARN: wake_need clear FAILED — stamp may linger until date rollover"
  fi
}

cmd="${1:-}"; wid="$(sanitize "${2:-}")"

case "$cmd" in
  probe)
    do_probe
    ;;
  count)
    prune_stale
    shopt -s nullglob
    files=("$LEASE_DIR"/*.lease)
    echo "${#files[@]}"
    ;;
  list)
    prune_stale
    now=$(date +%s)
    for f in "$LEASE_DIR"/*.lease; do
      [[ -e "$f" ]] || continue
      age=$(( now - $(stat -c %Y "$f") ))
      echo "$(basename "$f" .lease) age=${age}s"
    done
    ;;
  acquire)
    [[ -n "$wid" ]] || { echo "acquire needs <worker-id>" >&2; exit 2; }
    want_wake=0
    [[ "${3:-}" == "--wake" ]] && want_wake=1
    if ! do_probe; then
      if (( want_wake == 1 )); then
        plog "acquire($wid): workstation unreachable, firing phone wake"
        if ! "$(dirname "$0")/request_wake.sh" "lease:$wid" >/dev/null 2>&1; then
          plog "acquire($wid): wake request failed"
          exit 3
        fi
        waited=0
        while (( waited < 120 )); do
          sleep 10; (( waited += 10 )) || true
          do_probe && break
        done
        if ! do_probe; then
          plog "acquire($wid): still unreachable after 120s wake wait"
          exit 3
        fi
        plog "acquire($wid): workstation awake after wake (${waited}s)"
      else
        exit 3
      fi
    fi
    touch "$LEASE_DIR/$wid.lease"
    plog "acquire($wid): lease held"
    stamp_wake_need || true
    echo "acquired $wid"
    ;;
  release)
    [[ -n "$wid" ]] || { echo "release needs <worker-id>" >&2; exit 2; }
    rm -f "$LEASE_DIR/$wid.lease"
    plog "release($wid): lease dropped"
    n=0
    n=$("$0" count)
    if (( n == 0 )); then
      clear_wake_need || true
      plog "release($wid): last lease, running sleep decider"
      "$(dirname "$0")/sleep_decider.sh" || true
    else
      plog "release($wid): $n lease(s) remain, no decider run"
    fi
    echo "released $wid ($n leases remain)"
    ;;
  *)
    echo "usage: $0 {acquire <id> [--wake]|release <id>|list|count|probe}" >&2
    exit 2
    ;;
esac
