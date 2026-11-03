#!/bin/bash
# Wake client for the Linux sender (and the phone sender — same protocol).
#
# Usage:
#   wake-client.sh status          GET  /status
#   wake-client.sh wake [reason]   POST /wake {"reason": ...}
#
# Configuration (environment):
#   WAKE_SENDER      sender base URL, e.g. http://<sender-mesh-ip>:8765
#   WAKE_TOKEN_FILE  file holding the bearer token (preferred), or
#   WAKE_TOKEN       the bearer token itself
#
# The /wake call can take a while: the sender fires the packet and then
# verifies the target actually came up (up to ~150 s) before answering.
set -euo pipefail

: "${WAKE_SENDER:?set WAKE_SENDER, e.g. http://<sender-mesh-ip>:8765}"

if [[ -n "${WAKE_TOKEN_FILE:-}" ]]; then
  TOKEN="$(cat "$WAKE_TOKEN_FILE")"
elif [[ -n "${WAKE_TOKEN:-}" ]]; then
  TOKEN="$WAKE_TOKEN"
else
  echo "ERROR: set WAKE_TOKEN_FILE or WAKE_TOKEN." >&2
  exit 2
fi

case "${1:-}" in
  status)
    curl --fail-with-body -sS -m 30 \
      "${WAKE_SENDER}/status" \
      -H "Authorization: Bearer ${TOKEN}"
    echo
    ;;
  wake)
    REASON="$(printf '%s' "${2:-manual}" | tr -cd 'a-zA-Z0-9_.-')"
    curl --fail-with-body -sS -m 240 \
      -X POST "${WAKE_SENDER}/wake" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"reason\": \"${REASON:-manual}\"}"
    echo
    ;;
  *)
    echo "usage: $0 {status|wake [reason]}" >&2
    exit 2
    ;;
esac
