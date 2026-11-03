#!/usr/bin/env python3
"""Wake sender — Linux edition.

A small HTTP service on an always-on host resident on the home LAN (the
"sender host"). It is protocol-compatible with the phone sender in this
repo — same endpoints, same token auth — so requesters did not change
when the sender did:

  GET  /status -> {on_home_wifi, on_home_network, ssid, target_awake,
                   verified_awake, last_wake, last_reason, service,
                   version}
  POST /wake   -> broadcasts the Wake-on-LAN magic packet for the target
                  workstation on the home LAN, then verifies the target
                  answered; returns {woke, verified_awake, targets,
                  already_awake, reason}. HTTP 200 only when the target
                  is verified awake; 504 when the wake could not be
                  verified.

The listener binds only to the sender's mesh-VPN address (WAKE_BIND) —
never to the LAN — and the startup loop waits until that address exists
before serving, so a boot that races the mesh client fails closed
instead of exposing the trigger.

Configuration is by environment only; nothing site-specific is in the
code. Required: WAKE_BIND, WAKE_TARGET_MAC, and at least one of
WAKE_TARGET_TS_IP / WAKE_TARGET_LAN_IP. The bearer token is read from
WAKE_TOKEN_FILE on every request (keep the file mode 600); it is never
in this file or in the systemd unit.
"""
import hmac
import json
import os
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND_IP = os.environ.get("WAKE_BIND")
PORT = int(os.environ.get("WAKE_PORT", "8765"))
TOKEN_FILE = os.environ.get("WAKE_TOKEN_FILE", "token")
TARGET_MAC = os.environ.get("WAKE_TARGET_MAC")
TARGET_TS_IP = os.environ.get("WAKE_TARGET_TS_IP")
TARGET_LAN_IP = os.environ.get("WAKE_TARGET_LAN_IP")
TARGET_PORT = int(os.environ.get("WAKE_TARGET_PORT", "22"))
BROADCAST = os.environ.get("WAKE_BROADCAST")  # subnet broadcast, e.g. <lan-broadcast>
SSID = os.environ.get("WAKE_SSID")  # reported for protocol compatibility; see /status

STATE = {"last_wake": None, "last_reason": None}
LOCK = threading.Lock()


def read_token():
    with open(TOKEN_FILE) as f:
        return f.read().strip()


def target_awake():
    # The target's LAN side is firewalled (ICMP and TCP from the LAN
    # silently drop), so ping is fiction. The reliable signal is the
    # target's SSH port answering — tried on its mesh-VPN address
    # first, then its LAN address.
    for host in (TARGET_TS_IP, TARGET_LAN_IP):
        if not host:
            continue
        try:
            with socket.create_connection((host, TARGET_PORT), timeout=2):
                return True
        except OSError:
            pass
    return False


def magic_packet(mac):
    raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
    return b"\xff" * 6 + raw * 16


def send_wol():
    pkt = magic_packet(TARGET_MAC)
    dests = [("255.255.255.255", 9), ("255.255.255.255", 7)]
    if BROADCAST:
        dests += [(BROADCAST, 9), (BROADCAST, 7)]
    sent = 0
    for host, port in dests:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.sendto(pkt, (host, port))
            s.close()
            sent += 1
        except OSError:
            pass
    return sent


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def _auth_ok(self):
        try:
            want = "Bearer " + read_token()
        except OSError:
            return False
        got = self.headers.get("Authorization", "")
        return hmac.compare_digest(got, want)

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/status":
            return self._json(404, {"error": "not_found"})
        if not self._auth_ok():
            return self._json(401, {"error": "unauthorized"})
        awake = target_awake()
        self._json(200, {
            "service": "wake-sender", "version": "2.0-linux",
            # Protocol compatibility with the phone sender: this sender
            # is wired and permanently resident on the home LAN, so the
            # home-network fields report the deployment premise rather
            # than a measurement. The phone sender measures them via
            # its SSID gate.
            "on_home_wifi": True, "on_home_network": True, "ssid": SSID,
            "target_awake": awake, "verified_awake": awake,
            "last_wake": STATE["last_wake"], "last_reason": STATE["last_reason"],
        })

    def do_POST(self):
        if self.path != "/wake":
            return self._json(404, {"error": "not_found"})
        if not self._auth_ok():
            return self._json(401, {"woke": False, "error": "unauthorized"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            req = {}
        reason = str(req.get("reason", "manual"))[:64]
        with LOCK:
            already = target_awake()
            targets = 0
            if not already:
                for _ in range(3):
                    targets = send_wol()
                    time.sleep(2)
                    if target_awake():
                        break
                deadline = time.time() + 150
                while time.time() < deadline and not target_awake():
                    time.sleep(5)
            awake = target_awake()
            STATE["last_wake"] = datetime.now(timezone.utc).isoformat()
            STATE["last_reason"] = reason
        self._json(200 if awake else 504, {
            "woke": awake, "verified_awake": awake,
            "already_awake": already, "targets": targets, "reason": reason,
        })


def wait_bindable():
    # At boot the mesh-VPN address may not be assigned yet. Wait for it
    # rather than binding anything else: fail closed, retry forever.
    while True:
        try:
            s = socket.socket()
            s.bind((BIND_IP, 0))
            s.close()
            return
        except OSError:
            time.sleep(5)


if __name__ == "__main__":
    missing = [name for name, val in
               (("WAKE_BIND", BIND_IP), ("WAKE_TARGET_MAC", TARGET_MAC))
               if not val]
    if not (TARGET_TS_IP or TARGET_LAN_IP):
        missing.append("WAKE_TARGET_TS_IP or WAKE_TARGET_LAN_IP")
    if missing:
        sys.exit("wake_service: missing required configuration: "
                 + ", ".join(missing))
    wait_bindable()
    ThreadingHTTPServer((BIND_IP, PORT), H).serve_forever()
