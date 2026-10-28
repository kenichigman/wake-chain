#!/usr/bin/env python3
"""Wake coordination: per-job wake requests + the nightly decider.

Why this exists: a workstation that sleeps to save power is useless to
scheduled jobs unless something arranges its wake *before* it sleeps.
Wake-on-LAN cannot be sent from the requester's network (the magic packet
is a LAN broadcast; the requester reaches the LAN only through tunnels),
and the phone-based wake path (request_wake.sh) only works while the
phone is home. So standing wakes are arranged on the box itself, in
advance, as scheduled tasks — and this script is the registry + decider
for them.

How it works:
- Any job registers a wake request:
    wake_coordinator.py request add --id <slug> --date YYYY-MM-DD \
        [--time HH:MM] --reason "..." [--source "..."]
  `date` is the calendar date of the wake (the morning after the
  decider's evening run, for the default overnight time). `time`
  defaults to the standing overnight self-wake time (02:15, matching the
  on-box WakeToRun task that runs host/wake_check.ps1). A different time
  creates a one-off WakeToRun task on the box for that date/time.
- The nightly decider runs:
    wake_coordinator.py decide [--hold-file PATH]
  Stay-awake reasons = an external hold (the hold file exists — another
  system's way of saying "keep the box up tonight") OR any request due
  tomorrow. The flag planted on the box always contains the WAKE date
  (tomorrow), so wake_check.ps1's content-equality freshness test passes
  at the wake regardless of when the flag was planted. Timed requests
  also get their one-off task created and read back while the box is
  reachable.
- Output is marker lines on stdout; a caller stays silent unless a line
  starts with ARRANGE_FAILED (a registered wake that could not be set up
  is a structural miss, not plumbing).

A request registered while the box is already asleep cannot be arranged
for a custom time — it can still be honored by the overnight path if the
decider ran while the box was up. Requests are pruned by the decider
once their date passes.

Configuration (environment):
  WAKE_STATE_DIR    registry + log directory (default ~/.wake-chain)
  WAKE_SSH_CMD      ssh command line to reach the box
                    (default "ssh workstation")
  WAKE_REMOTE_DIR   on-box install dir (default C:\\wake-chain)
  WAKE_TZ           IANA timezone for date math (default: system local)
"""
import argparse
import base64
import json
import os
import shlex
import subprocess
import sys
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

STATE_DIR = Path(os.environ.get(
    "WAKE_STATE_DIR", Path.home() / ".wake-chain"))
REGISTRY = STATE_DIR / "wake_requests.json"
LOG = STATE_DIR / "wake_coordinator.log"
SSH_CMD = shlex.split(os.environ.get("WAKE_SSH_CMD", "ssh workstation"))
REMOTE_DIR = os.environ.get("WAKE_REMOTE_DIR", r"C:\wake-chain")
WAKE_CHECK = REMOTE_DIR + r"\wake_check.ps1"
FLAG_REMOTE = REMOTE_DIR + r"\wake_need.txt"
OVERNIGHT_TIME = os.environ.get("WAKE_OVERNIGHT_TIME", "02:15")
_tz_name = os.environ.get("WAKE_TZ")
TZ = ZoneInfo(_tz_name) if _tz_name else None


def now_local() -> datetime:
    return datetime.now(TZ) if TZ else datetime.now().astimezone()


def load_registry() -> list:
    if not REGISTRY.exists():
        return []
    return json.loads(REGISTRY.read_text()).get("requests", [])


def save_registry(requests: list) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    REGISTRY.write_text(json.dumps({"requests": requests}, indent=2) + "\n")


def log_line(msg: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    stamp = now_local().strftime("%Y-%m-%d %H:%M %Z")
    with LOG.open("a") as f:
        f.write(f"[{stamp}] {msg}\n")


def ssh_ps(ps_script: str, timeout: int = 40) -> subprocess.CompletedProcess:
    enc = base64.b64encode(ps_script.encode("utf-16le")).decode()
    return subprocess.run(
        SSH_CMD + ["powershell", "-NoProfile", "-EncodedCommand", enc],
        text=True, capture_output=True, timeout=timeout,
    )


def probe_box() -> bool:
    try:
        r = subprocess.run(SSH_CMD + ["echo ok"], text=True,
                           capture_output=True, timeout=20)
        return r.returncode == 0 and "ok" in r.stdout
    except Exception:
        return False


# ---------- request management ----------

def cmd_request(args) -> int:
    reqs = load_registry()
    if args.action == "add":
        try:
            datetime.strptime(args.date, "%Y-%m-%d")
            datetime.strptime(args.time, "%H:%M")
        except ValueError:
            print("BAD_DATE_OR_TIME")
            return 2
        reqs = [r for r in reqs if r["id"] != args.id]
        reqs.append({
            "id": args.id, "wake_date": args.date, "time": args.time,
            "reason": args.reason, "source": args.source or "",
            "created": now_local().strftime("%Y-%m-%d %H:%M %Z"),
        })
        save_registry(reqs)
        print(f"ADDED {args.id} {args.date} {args.time}")
        return 0
    if args.action == "remove":
        before = len(reqs)
        reqs = [r for r in reqs if r["id"] != args.id]
        save_registry(reqs)
        print(f"REMOVED {args.id}" if len(reqs) < before else f"NOT_FOUND {args.id}")
        return 0
    for r in sorted(reqs, key=lambda r: (r["wake_date"], r["time"])):
        print(f"{r['wake_date']} {r['time']}  {r['id']}  {r['reason']}"
              + (f"  [{r['source']}]" if r.get("source") else ""))
    if not reqs:
        print("(no wake requests)")
    return 0


# ---------- decider ----------

def decide(args) -> int:
    today = now_local().date()
    tomorrow = today + timedelta(days=1)
    tmr = tomorrow.isoformat()
    reqs = load_registry()

    expired = [r for r in reqs if r["wake_date"] < tmr]
    active = [r for r in reqs if r["wake_date"] >= tmr]
    due = [r for r in active if r["wake_date"] == tmr]
    overnight = [r for r in due if r["time"] == OVERNIGHT_TIME]
    timed = [r for r in due if r["time"] != OVERNIGHT_TIME]
    hold = bool(args.hold_file) and Path(args.hold_file).exists()

    reasons = (["external-hold"] if hold else []) + \
              [f"request:{r['id']}" for r in due]

    if args.dry_run:
        for r in expired:
            print(f"WOULD_PRUNE {r['id']} ({r['wake_date']} past)")
        if reasons:
            print(f"WOULD_PLANT flag={tmr} reasons={','.join(reasons)}")
        else:
            print("WOULD_CLEAR flag (no stay-awake reasons)")
        for r in timed:
            print(f"WOULD_CREATE_TASK WakeChain-Once-{r['id']} at {tmr} {r['time']}")
        return 0

    if expired:
        save_registry(active)
        for r in expired:
            log_line(f"pruned expired wake request {r['id']} ({r['wake_date']})")

    if not probe_box():
        msg = f"box unreachable at decider; due_tomorrow={len(due)} external_hold={hold}"
        log_line(msg)
        print("UNREACHABLE " + msg)
        for r in due:
            print(f"ARRANGE_FAILED {r['id']}: box unreachable at decider time; "
                  f"wake for {tmr} {r['time']} could not be arranged")
        if hold:
            print("ARRANGE_FAILED external-hold: hold set but box unreachable; flag not planted")
        return 0

    # Flag: plant with the WAKE date as content, or clear when no reasons.
    if reasons:
        ps = (f"Set-Content -LiteralPath '{FLAG_REMOTE}' -Value '{tmr}' -NoNewline; "
              f"(Get-Content -LiteralPath '{FLAG_REMOTE}' -Raw).Trim()")
        r = ssh_ps(ps)
        readback = (r.stdout or "").strip()
        if readback == tmr:
            log_line(f"planted wake flag {tmr}; reasons={','.join(reasons)}")
            print(f"PLANTED {tmr} reasons={','.join(reasons)}")
        else:
            log_line(f"FLAG WRITE FAILED readback={readback!r} reasons={','.join(reasons)}")
            print(f"ARRANGE_FAILED flag: write read-back {readback!r} != {tmr}")
    else:
        ssh_ps(f"Remove-Item -LiteralPath '{FLAG_REMOTE}' -ErrorAction SilentlyContinue")
        log_line("cleared wake flag (no stay-awake reasons)")
        print("CLEARED (no stay-awake reasons)")

    # Timed one-off wake tasks.
    for r in timed:
        task = f"WakeChain-Once-{r['id']}"
        when = f"{tmr}T{r['time']}:00"
        ps = f"""
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File {WAKE_CHECK}'
$trg = New-ScheduledTaskTrigger -Once -At ([datetime]'{when}')
$set = New-ScheduledTaskSettingsSet -WakeToRun
Register-ScheduledTask -TaskName '{task}' -Action $act -Trigger $trg -Settings $set -Force | Out-Null
$t = Get-ScheduledTask -TaskName '{task}'
"WAKE=$($t.Settings.WakeToRun) STATE=$($t.State)"
"""
        out = ssh_ps(ps)
        txt = out.stdout or ""
        if "WAKE=True" in txt:
            log_line(f"arranged timed wake {task} at {when} for request {r['id']}")
            print(f"TIMED_ARRANGED {r['id']} task={task} at={when}")
        else:
            log_line(f"TIMED WAKE FAILED {task}: {txt.strip()[:200]}")
            print(f"ARRANGE_FAILED {r['id']}: timed task {task} not verified (output: {txt.strip()[:120]})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    rq = sub.add_parser("request")
    rq.add_argument("action", choices=["add", "remove", "list"])
    rq.add_argument("--id")
    rq.add_argument("--date")
    rq.add_argument("--time", default=OVERNIGHT_TIME)
    rq.add_argument("--reason", default="")
    rq.add_argument("--source", default="")
    dc = sub.add_parser("decide")
    dc.add_argument("--hold-file", default=None,
                    help="if this file exists, keep the box awake tonight")
    dc.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if args.cmd == "request":
        if args.action in ("add", "remove") and not args.id:
            print("--id required")
            return 2
        if args.action == "add" and not args.date:
            print("--date required")
            return 2
        return cmd_request(args)
    return decide(args)


if __name__ == "__main__":
    sys.exit(main())
