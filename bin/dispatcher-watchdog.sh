#!/usr/bin/env bash
# dispatcher-watchdog.sh — keep the warm Russell dispatcher healthy, forever.
#
# WHY: the warm, model-driven loop degrades — the model runs ONE endless turn, so
# Claude Code's between-turn auto-compaction never fires, context grows unbounded,
# and the session slows to a crawl and stops dispatching (observed ~1h stalls with
# orphan ticks). This supervisor keeps the warm session (no `claude -p`) robust:
#   - restarts on a CADENCE so context never bloats (fresh session);
#   - restarts if the per-tick heartbeat goes STALE or the tmux session died;
#   - clears orphan ticks + stale locks on every restart.
#
# Run detached under caffeinate. Owns the `russ-dispatch` tmux session.
# Deliberately NOT `set -u` (a stray unset var must not silently kill the
# supervisor). Logs every decision so it can never exit invisibly.
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SESSION="${RUSS_DISPATCH_TMUX:-russ-dispatch}"
HB="${RUSS_TICK_HEARTBEAT:-$HOME/.russ/dispatcher-tick.heartbeat}"
CONFIG="${RUSS_CONFIG:-$HOME/.russ/runtime-claude.env}"
STALL="${RUSS_DISPATCH_STALL_SECS:-150}"
MAX_AGE="${RUSS_DISPATCH_MAX_AGE_SECS:-1500}"
LOG="${RUSS_DISPATCH_WATCHDOG_LOG:-/tmp/russ-dispatch-watchdog.log}"
STARTED=0

now() { date +%s; }
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$LOG" 2>/dev/null; }

# Kill a process and its whole descendant tree (scoped reap). Used instead of a
# global pkill so a restart NEVER cross-kills a coexisting runtime's dispatcher.
kill_tree() {
  local p="$1" c
  for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c"; done
  kill -9 "$p" 2>/dev/null
}

restart() {
  log "restart: $1"
  # Reap ONLY this runtime's tmux session process-tree. Capture the pane PIDs
  # BEFORE killing the session so orphan tick/next-need children that outlived the
  # pane are cleaned up too — scoped to this runtime, never a global pkill, so two
  # runtimes (russell + another tenant) can run side by side on one machine.
  local pane_pids p
  pane_pids="$(tmux list-panes -t "$SESSION" -F '#{pane_pid}' 2>/dev/null)"
  tmux kill-session -t "$SESSION" 2>/dev/null
  for p in $pane_pids; do kill_tree "$p"; done
  # The session MUST be gone before run-dispatcher.sh, or it no-ops ("already
  # running") and the refresh never happens. Re-kill until it's actually gone.
  k=0
  while tmux has-session -t "$SESSION" 2>/dev/null; do
    tmux kill-session -t "$SESSION" 2>/dev/null
    sleep 1; k=$((k+1)); [ "$k" -ge 8 ] && break
  done
  if [ -f "$CONFIG" ]; then . "$CONFIG"; fi
  # Clear ONLY this runtime's per-credential tick lock (dispatch-tick.sh keys its
  # lock on the runtime credential), never the global /tmp/russ-dispatch-tick*.lock.
  local cred_key lock_dir
  cred_key="$(printf '%s' "${RUSS_RUNTIME_CREDENTIAL:-default}" | cksum | cut -d' ' -f1)"
  lock_dir="${RUSS_TICK_LOCK:-/tmp/russ-dispatch-tick-$cred_key.lock}"
  rmdir "$lock_dir" 2>/dev/null
  rm -f "$HB" 2>/dev/null
  export RUSS_DISPATCH_MODEL="${RUSS_DISPATCH_MODEL:-sonnet}"
  export RUSS_POLL_MAX_WAIT="${RUSS_POLL_MAX_WAIT:-30}"
  export RUSS_POLL_INTERVAL="${RUSS_POLL_INTERVAL:-3}"
  export RUSS_CONCURRENCY="${RUSS_CONCURRENCY:-4}"
  export RUSS_TICK_HEARTBEAT="$HB"
  : > "$ROOT/dispatch.log" 2>/dev/null
  touch "$HB" 2>/dev/null
  sleep 1
  "$ROOT/bin/run-dispatcher.sh" >> "$LOG" 2>&1
  log "restart: run-dispatcher exit=$?"
  STARTED=$(now)
}

log "watchdog: starting (stall=${STALL}s cadence=${MAX_AGE}s)"
restart "initial"
log "watchdog: entering supervise loop"
while true; do
  sleep 30
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    restart "session-gone"
    continue
  fi
  hb_age=999999
  if [ -f "$HB" ]; then
    mt="$(stat -f %m "$HB" 2>/dev/null)"
    [ -n "$mt" ] && hb_age=$(( $(now) - mt ))
  fi
  age=$(( $(now) - STARTED ))
  log "supervise: hb_age=${hb_age}s session_age=${age}s"
  if [ "$hb_age" -gt "$STALL" ]; then
    restart "stalled (no tick ${hb_age}s)"
  elif [ "$age" -gt "$MAX_AGE" ]; then
    restart "cadence (${age}s — refresh context)"
  fi
done
