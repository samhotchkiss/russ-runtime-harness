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
# Auto-teardown when the external is REMOVED in the russ UI. Removing an external
# revokes the runtime, so its credential stops authenticating and the heartbeat
# returns HTTP 401/403. Transient outages are 5xx/timeouts (NOT 401), so we only
# tear down after RUSS_REVOKED_TEARDOWN_AFTER *consecutive* auth-rejections — far
# beyond any blip. Only fires when RUSS_RUNTIME_NAME is set (the launchd path); the
# legacy single-runtime setup just logs + retries forever, exactly as before.
REVOKED_AFTER="${RUSS_REVOKED_TEARDOWN_AFTER:-10}"
rejected=0

# hb_status — POST the heartbeat (refreshes the lease) and return the HTTP code.
hb_status() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST \
    "$RUSS_BASE_URL/api/runtimes/heartbeat" \
    -H "Authorization: Bearer $RUSS_RUNTIME_CREDENTIAL" 2>/dev/null
}

echo "russ-heartbeat: starting (every ${INTERVAL}s) against $RUSS_BASE_URL" >&2
while true; do
  code="$(hb_status)"
  case "$code" in
    200|204)
      rejected=0 ;;
    401|403)
      rejected=$((rejected + 1))
      echo "russ-heartbeat: auth-rejected (HTTP $code) ${rejected}/${REVOKED_AFTER} at $(date -u +%H:%M:%S)Z" >&2
      if [ -n "${RUSS_RUNTIME_NAME:-}" ] && [ "$rejected" -ge "$REVOKED_AFTER" ]; then
        echo "russ-heartbeat: runtime '$RUSS_RUNTIME_NAME' appears REMOVED/REVOKED (HTTP $code x${rejected}) — auto-tearing down its launchd agents" >&2
        setsid bash "$HERE/teardown-runtime.sh" "$RUSS_RUNTIME_NAME" --revoked \
          >>"/tmp/russ-teardown-${RUSS_RUNTIME_NAME}.log" 2>&1 &
        exit 0
      fi ;;
    *)
      # transient (5xx / 000 timeout / network) — never counts toward teardown.
      rejected=0
      echo "russ-heartbeat: beat failed (HTTP ${code:-000}) at $(date -u +%H:%M:%S)Z (will retry)" >&2 ;;
  esac
  sleep "$INTERVAL"
done
