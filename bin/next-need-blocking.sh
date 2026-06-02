#!/usr/bin/env bash
# next-need-blocking.sh — the bridge between dumb polling and the warm brain.
#
# The dispatcher (a warm Haiku Claude Code session) calls this ONE command and
# blocks on it. Internally it polls next_need every RUSS_POLL_INTERVAL seconds
# and:
#   - the instant a bundle appears, prints the full PollResult JSON and exits 0;
#   - after RUSS_POLL_MAX_WAIT seconds with nothing, prints {"needs":[],...} and
#     exits 0 so the dispatcher loops (keeps the session from parking forever and
#     lets it re-read its own instructions cheaply).
#
# Idle cost is therefore ~zero model tokens: bash is what spins, not Claude.
# Each next_need also heartbeats the runtime server-side, so polling itself
# sustains liveness; the heartbeat daemon covers the gaps while the brain is busy.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/russ-mcp.sh
source "$HERE/../lib/russ-mcp.sh"

INTERVAL="${RUSS_POLL_INTERVAL:-5}"
MAX_WAIT="${RUSS_POLL_MAX_WAIT:-45}"
deadline=$(( SECONDS + MAX_WAIT ))

while [ "$SECONDS" -lt "$deadline" ]; do
  if result=$(russ_next_need 2>/dev/null); then
    count=$(jq '(.needs // []) | length' <<<"$result" 2>/dev/null || echo 0)
    if [ "${count:-0}" -gt 0 ]; then
      echo "$result"
      exit 0
    fi
  fi
  sleep "$INTERVAL"
done

# Nothing this window — return an empty, well-formed bundle so the caller loops.
echo '{"needs":[]}'
exit 0
