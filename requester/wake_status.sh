#!/bin/bash
# wake_status.sh — check the Wake Chain app's status via the tailnet
# (phone must have the app's service running). Same setup as
# request_wake.sh: WAKE_PHONE / WAKE_PHONE_FILE, WAKE_TOKEN /
# WAKE_TOKEN_FILE, optional WAKE_PROXY, WAKE_PORT (default 8765).
set -euo pipefail

PHONE="${WAKE_PHONE:-}"
if [[ -z "$PHONE" && -n "${WAKE_PHONE_FILE:-}" ]]; then
  PHONE="$(cat "$WAKE_PHONE_FILE" 2>/dev/null || true)"
fi
PORT="${WAKE_PORT:-8765}"

if [[ -z "$PHONE" ]]; then
  echo "ERROR: phone tailnet address not configured. Set WAKE_PHONE or WAKE_PHONE_FILE." >&2
  exit 2
fi
TOKEN="${WAKE_TOKEN:-}"
if [[ -z "$TOKEN" && -n "${WAKE_TOKEN_FILE:-}" ]]; then
  TOKEN="$(cat "$WAKE_TOKEN_FILE" 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: bearer <redacted> not configured. Set WAKE_TOKEN or WAKE_TOKEN_FILE." >&2
  exit 2
fi

PROXY_ARGS=()
if [[ -n "${WAKE_PROXY:-}" ]]; then PROXY_ARGS=(--proxy "$WAKE_PROXY"); fi

curl "${PROXY_ARGS[@]}" \
  --fail-with-body -sS -m 15 \
  "http://${PHONE}:${PORT}/status" \
  -H "Authorization: Bearer ${TOKEN}"
echo
