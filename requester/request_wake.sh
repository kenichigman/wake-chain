#!/bin/bash
# request_wake.sh — ask the phone app to wake the workstation.
#
# How it works: the phone runs a mesh VPN client and the Wake Chain app,
# which hosts a tiny HTTP server on the tailnet interface. This script
# POSTs /wake through the tunnel; the app checks the phone is on the home
# WiFi and fires the Wake-on-LAN magic packet at the PC.
#
# Usage: request_wake.sh [reason]
#
# Setup (one-time):
#   1. Phone joins the tailnet (mesh VPN app, same account as requester).
#   2. Set WAKE_PHONE to the phone's tailnet address, or write it to a
#      file and point WAKE_PHONE_FILE at it.
#   3. Provide the bearer <redacted> from the app via WAKE_TOKEN, or a
#      file via WAKE_TOKEN_FILE. The token is generated on the phone and
#      never stored in this repo.
#   WAKE_PROXY is optional, for requesters that reach the tailnet through
#   an HTTP CONNECT proxy.
set -euo pipefail

PHONE="${WAKE_PHONE:-}"
if [[ -z "$PHONE" && -n "${WAKE_PHONE_FILE:-}" ]]; then
  PHONE="$(cat "$WAKE_PHONE_FILE" 2>/dev/null || true)"
fi
PORT="${WAKE_PORT:-8765}"
REASON="$(printf '%s' "${1:-manual}" | tr -cd 'a-zA-Z0-9_.-')"

if [[ -z "$PHONE" ]]; then
  echo "ERROR: phone tailnet address not configured." >&2
  echo "Set WAKE_PHONE or WAKE_PHONE_FILE (find the address in the phone's mesh VPN app)." >&2
  exit 2
fi
TOKEN="${WAKE_TOKEN:-}"
if [[ -z "$TOKEN" && -n "${WAKE_TOKEN_FILE:-}" ]]; then
  TOKEN="$(cat "$WAKE_TOKEN_FILE" 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: bearer <redacted> not configured. Set WAKE_TOKEN or WAKE_TOKEN_FILE." >&2
  echo "Copy the token from the Wake Chain app on the phone." >&2
  exit 2
fi

PROXY_ARGS=()
if [[ -n "${WAKE_PROXY:-}" ]]; then PROXY_ARGS=(--proxy "$WAKE_PROXY"); fi

curl "${PROXY_ARGS[@]}" \
  --fail-with-body -sS -m 15 \
  -X POST "http://${PHONE}:${PORT}/wake" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"reason\": \"${REASON}\"}"
echo
