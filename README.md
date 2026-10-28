# wake-chain

A remote-wake system for a workstation that sleeps: a phone app fires
Wake-on-LAN on authenticated request, and an activity-aware power layer
on both sides decides — conservatively, and out loud — when waking is
allowed and when sleeping is safe.

The wake request is the easy part. The system is the set of reasons it
refuses to fire, and the set of reasons it refuses to sleep.

## Why

Unattended jobs (builds, data pulls, batch work) need a workstation that
is awake on demand, but a workstation left on 24/7 wastes power and the
owner's patience. The obvious pieces fight each other:

- Wake-on-LAN is a LAN broadcast. A requester on another network
  (a VM, a laptop away from home) cannot send it directly.
- The phone can send it — but only when the phone is physically home,
  which is exactly when a person could press the power button.
- A machine that wakes on schedule must decide whether it may go back
  to sleep, without ever sleeping on its owner or on work in flight.

## Architecture

```
requester                        phone (home)              workstation
─────────                        ────────────              ───────────
wake_coordinator.py ──┐
request_wake.sh ──────┼─ HTTPS-over-mesh-VPN ──▶ Wake Chain app
wake_lease.sh         │    (tailnet only)         │  ├─ SSID gate
                      │                           │  └─ WoL broadcast ──▶ NIC wakes
                      │                           │
                      └─ SSH ─────────────────────┴───────────────▶ host/*.ps1
                                                                    (idle probe,
                                                                     wake check,
                                                                     sleep inputs)
```

- **Android app** (`android/`) — a foreground service running a small
  hand-rolled HTTP server bound *only* to the phone's mesh-VPN
  (tailnet) interface. `POST /wake` and `GET /status`, bearer-token
  auth with a constant-time compare, bounded connection handling. The
  token is generated on the phone and never appears in this repo.
- **Host scripts** (`host/`, PowerShell, run on the workstation) — an
  idle probe resident in the interactive session (input idle, lock
  state, audio activity), an SSH-side reader that computes flag
  freshness on-box, and the overnight wake check.
- **Requester scripts** (`requester/`) — the wake client, a
  reference-counted lease manager, the sleep decider, and a
  coordinator that arranges dated wake requests in advance as on-box
  scheduled tasks.

## The refusal rules (the design core)

**The wake refuses to fire when:**

- the phone is not on the configured home WiFi SSID — checked at send
  time, for both the HTTP path and the in-app manual button. Off home
  WiFi, a wake request returns `409` and *nothing is sent*: a magic
  packet broadcast on a foreign network is useless and noisy.
- the mesh-VPN interface is down. The HTTP listener binds only to the
  tailnet address and fails closed (with a retry loop) when it is
  absent — the trigger is never exposed on the LAN in cleartext.
- the bearer <redacted> doesn't match (constant-time compare).

**The machine refuses to sleep when:**

- any lease is held. Workers take reference-counted leases
  (`wake_lease.sh acquire <id>`); the sleep decider only runs when the
  count reaches zero, and stale leases (>4h, crashed worker) are pruned.
- a `wake_need` flag is fresh. Overnight jobs plant it (content: the
  wake date, so the on-box freshness test is content equality, immune
  to clock skew).
- the user was active within 10 minutes — input idle is measured
  *inside* the interactive session, because reading it from a service
  or SSH context returns fiction.
- audio is playing. Media playback counts as activity: the probe
  watches Core Audio session state on the default endpoint, holds the
  signal for 150s across track gaps, and any detector error reads as
  inactive (never stuck awake).
- **anything is unknown.** A stale probe file, an unparseable value, a
  failed check — every error path stays awake and logs the reason.
  Every decider exit logs its verdict; a silent decider is treated as
  a dead one.

**The two checkers are bridged.** The on-box overnight checker is
lease-blind by design (it must run with no requester alive). So the
lease manager stamps the `wake_need` flag on every acquire and clears
it — only if it still holds lease-stamp content — on the last release.
Each side stays simple; the bridge keeps them from fighting.

**When the phone can't fire, the machine doesn't sleep.** The wake path
depends on the phone being home; when the owner travels, it can't. An
away-hold poller on the requester side checks the phone's `/status`:
whenever the wake path is unavailable (phone away, app stopped) and the
workstation is up, it holds a standing lease, so the decider can never
strand a running machine in a sleep it cannot be woken from. Its known
limit is stated plainly: it cannot help a machine that is already
asleep when the phone leaves.

## Layout

```
android/     the phone app (Kotlin, no third-party dependencies)
host/        PowerShell on the workstation: idle_probe_loop.ps1 (resident
             probe), idle_probe.ps1 (one-shot variant), idle_check.ps1
             (SSH-side reader), wake_check.ps1 (overnight wake check)
requester/   request_wake.sh / wake_status.sh (phone wake client),
             wake_lease.sh (leases), sleep_decider.sh (sleep decision),
             wake_coordinator.py (dated wake requests + nightly decider)
tools/       wol_listen.ps1 — packet-arrival test that splits the fault
             domain (network vs PC) before any settings are touched
docs/        wol-diagnosis.md — the diagnosis order for "packet sent,
             PC stays asleep"
```

Configuration is by environment variables (`WAKE_SSH_CMD`,
`WAKE_REMOTE_DIR`, `WAKE_PHONE`, `WAKE_TOKEN`, …), documented at the top
of each script. Nothing site-specific is hardcoded; the on-box install
directory defaults to `C:\wake-chain`.

## Field note: the SSID that vanished in the background

The app's first version passed every test on screen and refused every
real wake. Cause: on Android 10+, reading the current WiFi SSID requires
the app to count as "in use" for location; a foreground service only
counts when it declares the `location` service type. Without it, the
SSID read as `<unknown ssid>` the moment the app left the screen, the
gate (correctly) refused — and the on-screen status kept showing the
SSID, because the visible activity *was* in use. The fix is one line in
the manifest; finding it took the fault-domain split in
`docs/wol-diagnosis.md`. The gate failing closed was the system working
as designed; the bug was in what the gate could see.

## Status

In production, daily, on one home workstation, for one user. It is a
personal system published as a design artifact: small on purpose, every
rule traceable to a failure it prevents. No telemetry, no cloud relay,
no open ports.
