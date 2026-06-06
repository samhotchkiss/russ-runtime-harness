#!/usr/bin/env bash
# teardown-runtime.sh <runtime> [--revoked] — stop and remove a runtime's LOCAL
# footprint: its launchd agents, warm dispatcher, heartbeat, tmux session and
# scratch. Idempotent. Two ways it runs:
#   - automatically: the heartbeat daemon calls it (--revoked) when the runtime is
#     removed in the russ UI (the credential stops authenticating -> HTTP 401);
#   - manually: `bin/teardown-runtime.sh <runtime>` to retire a runtime by hand.
# Safe to run while it is tearing down its own caller: launchd bootout of the
# heartbeat agent kills the daemon, but the daemon launches us detached (setsid).
set -uo pipefail
RT="${1:?usage: teardown-runtime.sh <runtime-name> [--revoked]}"
REVOKED=0; [ "${2:-}" = "--revoked" ] && REVOKED=1

export HOME="${HOME:-/Users/sam}"
uid="$(id -u)"
log() { echo "[teardown $RT] $*" >&2; }

dispatch_label="team.$RT.runtime-harness.claude-dispatcher"
heartbeat_label="team.$RT.runtime-harness.heartbeat"
LA="$HOME/Library/LaunchAgents"

log "starting (revoked=$REVOKED)"

# 1. Stop the dispatcher launchd agent (warm session + watchdog).
launchctl bootout "gui/$uid/$dispatch_label" 2>/dev/null && log "booted out $dispatch_label" || true
# 2. Reap this runtime's tmux session + any scoped stragglers (matched by the
#    runtime name in their argv — never a global pkill).
tmux kill-session -t "russ-dispatch-$RT" 2>/dev/null && log "killed tmux russ-dispatch-$RT" || true
pkill -f "warm-dispatcher.sh $RT" 2>/dev/null || true
pkill -f "heartbeat-runner.sh $RT" 2>/dev/null || true
pkill -f "runtime-$RT.env" 2>/dev/null || true
# 3. Stop the heartbeat launchd agent (this may terminate our caller — fine, we are
#    setsid-detached when called from the daemon).
launchctl bootout "gui/$uid/$heartbeat_label" 2>/dev/null && log "booted out $heartbeat_label" || true
# 4. Remove the plists so nothing reloads on next login.
rm -f "$LA/$dispatch_label.plist" "$LA/$heartbeat_label.plist" 2>/dev/null && log "removed launchd plists" || true
# 5. Clean scratch + archive (revoked) or remove (manual) the credential config.
rm -f "$HOME/.russ/dispatcher-tick-$RT.heartbeat" 2>/dev/null || true
rm -rf "/tmp/russ-needs-$RT" 2>/dev/null || true
if [ -f "$HOME/.russ/runtime-$RT.env" ]; then
  if [ "$REVOKED" = "1" ]; then
    mv -f "$HOME/.russ/runtime-$RT.env" "$HOME/.russ/runtime-$RT.env.revoked" 2>/dev/null && log "archived credential -> runtime-$RT.env.revoked" || true
  else
    rm -f "$HOME/.russ/runtime-$RT.env" 2>/dev/null && log "removed credential runtime-$RT.env" || true
  fi
fi
log "teardown complete"
