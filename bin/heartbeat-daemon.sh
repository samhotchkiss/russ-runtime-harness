#!/usr/bin/env bash
# heartbeat-daemon.sh — keep this runtime's leases alive, forever, in bash.
#
# This is the load-bearing liveness mechanism and it lives entirely OUTSIDE the
# model. It runs every RUSS_HEARTBEAT_INTERVAL seconds regardless of what the
# dispatcher (or any sub-agent) is doing, so a long-running need can never let
# the lease go stale. The server's freshness window is 5 minutes; we beat well
# under it.
#
# Run it once, supervised, e.g.:
#   caffeinate -dimsu runtime-harness/bin/heartbeat-daemon.sh
# (or a launchd LaunchAgent / tmux session).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/russ-mcp.sh
source "$HERE/../lib/russ-mcp.sh"

INTERVAL="${RUSS_HEARTBEAT_INTERVAL:-60}"
echo "russ-heartbeat: starting (every ${INTERVAL}s) against $RUSS_BASE_URL" >&2
while true; do
  if russ_heartbeat >/dev/null 2>&1; then
    :
  else
    # A failed heartbeat is not fatal: the next tick may recover, and if the
    # whole runtime is unreachable the server simply reclaims our needs. Never
    # exit — that is what would actually drop liveness.
    echo "russ-heartbeat: beat failed at $(date -u +%H:%M:%S)Z (will retry)" >&2
  fi
  sleep "$INTERVAL"
done
