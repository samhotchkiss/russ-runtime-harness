#!/usr/bin/env bash
# dispatcher-watchdog.sh — keep the warm Russell dispatcher healthy, forever.
#
# WHY: the warm, model-driven loop degrades — the model runs ONE endless turn, so
# Claude Code's between-turn auto-compaction never fires, context grows unbounded,
# and the session slows to a crawl and stops dispatching (observed ~1h stalls with
# orphan ticks). This supervisor keeps the warm session (no `claude -p`) robust:
#   - restarts on a CADENCE so context never bloats (fresh session);
#   - restarts if the per-tick heartbeat goes STALE or the tmux session died;
#   - restarts on a COMPLETION-THROUGHPUT wedge: the loop keeps TICKING (heartbeat
#     fresh) and keeps CLAIMING needs but stops FINISHING them — zero needs reach
#     `done` for COMPLETION_STALL secs while claims are recent. The stale-heartbeat
#     and dead-tmux checks all MISS this (heartbeat looks healthy the whole time);
#   - clears orphan ticks + stale locks on every restart.
#
# COMPLETION SIGNAL: the russ API exposes no need-stats / completion-count
# endpoint (MCP has only next_need + complete_need; REST only heartbeat/enroll),
# so completion is observed LOCALLY: lib/russ-mcp.sh's russ_complete_need bumps a
# per-runtime COMPLETION_MARKER's mtime on every successful ack — the one chokepoint
# every completion in this harness flows through. dispatch.log (a line per CLAIM)
# is the claim signal. Wedge = claims fresh AND newer than the last completion AND
# no completion for COMPLETION_STALL secs. dispatch.log alone can't catch this: it
# records claims, which keep flowing during the wedge — that is the whole bug.
#
# LAUNCHD COVERAGE: in this repo the launchd dispatcher agent runs THIS watchdog
# (install-runtime.sh -> warm-dispatcher.sh -> exec dispatcher-watchdog.sh), so a
# launchd-supervised dispatcher is already watched — the watchdog owns the tmux
# session and restarts the warm loop in place. When RUSS_DISPATCH_LAUNCHD_LABEL is
# set, a wedge that an in-place tmux restart can't clear ALSO escalates to
# `launchctl kickstart -k` on our own label, so launchd hands us a clean process.
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
# Completion-throughput wedge detection (the fresh-heartbeat/zero-completion case
# the stale-heartbeat + dead-tmux + cadence checks all miss). The dispatch loop
# keeps TICKING (heartbeat fresh) and keeps CLAIMING needs, but stops FINISHING
# them. Signal: every successful complete_need bumps COMPLETION_MARKER's mtime
# (lib/russ-mcp.sh). dispatch.log gets a line per CLAIM (the dispatcher's own
# log). So: claims are recent (dispatch.log fresh) AND newer than the last
# completion AND no completion for COMPLETION_STALL secs  ==>  wedged.
DISPATCH_LOG="${RUSS_DISPATCH_LOG:-$ROOT/dispatch.log}"
COMPLETION_MARKER="${RUSS_COMPLETION_MARKER:-$HOME/.russ/dispatcher-completion.marker}"
COMPLETION_STALL="${RUSS_DISPATCH_COMPLETION_STALL_SECS:-600}"
# Only treat zero-completion as a wedge if a claim happened within this window —
# an idle dispatcher (no needs to do) legitimately completes nothing and must not
# be restarted. Defaults to the completion-stall window.
CLAIM_RECENT="${RUSS_DISPATCH_CLAIM_RECENT_SECS:-$COMPLETION_STALL}"
# Optional launchd coverage: when this dispatcher is supervised by launchd (the
# label whose ProgramArguments run this watchdog, e.g.
# team.<rt>.runtime-harness.claude-dispatcher), set this so a wedge can also be
# escalated to `launchctl kickstart -k` — launchd hands us a clean process tree
# when an in-place tmux restart cannot recover. Unset = pure tmux supervision.
LAUNCHD_LABEL="${RUSS_DISPATCH_LAUNCHD_LABEL:-}"
STARTED=0
LAST_COMPLETION_RESTART=0

now() { date +%s; }
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$LOG" 2>/dev/null; }

# age_secs FILE — seconds since FILE's mtime, or a huge number if it is missing.
# Never errors (no `set -u` foot-gun): a missing/unreadable file reads as "ancient".
age_secs() {
  local f="$1" mt
  [ -f "$f" ] || { echo 999999; return; }
  mt="$(stat -f %m "$f" 2>/dev/null)"
  [ -n "$mt" ] || { echo 999999; return; }
  echo $(( $(now) - mt ))
}

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
  # shellcheck disable=SC1090  # CONFIG is a per-runtime path resolved at runtime.
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
  # Propagate the completion marker into the warm session so every per-need
  # sub-agent's russ_complete_need bumps the SAME marker this watchdog watches.
  export RUSS_COMPLETION_MARKER="$COMPLETION_MARKER"
  : > "$DISPATCH_LOG" 2>/dev/null
  touch "$HB" 2>/dev/null
  # Seed the completion marker NOW so the freshly-started loop gets a full
  # COMPLETION_STALL grace window before the throughput check can fire again
  # (a cold session legitimately completes nothing for a bit). Without this the
  # marker would look "ancient" the instant we restart and could thrash.
  mkdir -p "$(dirname "$COMPLETION_MARKER")" 2>/dev/null
  touch "$COMPLETION_MARKER" 2>/dev/null
  sleep 1
  "$ROOT/bin/run-dispatcher.sh" >> "$LOG" 2>&1
  log "restart: run-dispatcher exit=$?"
  STARTED=$(now)
}

# kickstart_self — escalate to launchd when in-place tmux restarts cannot clear a
# wedge. Only used if RUSS_DISPATCH_LAUNCHD_LABEL is set (this watchdog IS the
# launchd job's program). `launchctl kickstart -k` SIGKILLs and relaunches the
# job, handing us a brand-new process tree — the strongest local recovery short
# of a reboot. Scoped to OUR label only, never a blanket bootout.
kickstart_self() {
  [ -n "$LAUNCHD_LABEL" ] || return 1
  local uid; uid="$(id -u)"
  log "kickstart: launchctl kickstart -k gui/$uid/$LAUNCHD_LABEL ($1)"
  launchctl kickstart -k "gui/$uid/$LAUNCHD_LABEL" >> "$LOG" 2>&1
  return 0
}

# is_completion_wedged HB_AGE CLAIM_AGE COMP_AGE — true (exit 0) iff the dispatcher
# is ticking and claiming but has stopped completing needs. Pure arithmetic on the
# three ages so it is unit-testable in isolation. All four conditions must hold:
#   1. heartbeat FRESH (hb_age <= STALL)               -> the loop is alive/ticking
#   2. a claim happened RECENTLY (claim_age <= CLAIM_RECENT) -> work is in flight,
#      so this is NOT a legitimately idle dispatcher with nothing to complete
#   3. last claim is NEWER than last completion (claim_age < comp_age)
#      -> there is claimed-but-unfinished work, the defining shape of the wedge
#   4. NO completion for COMPLETION_STALL seconds (comp_age > COMPLETION_STALL)
# Plus a cooldown so a just-restarted session gets its grace window, not a re-trip.
is_completion_wedged() {
  local hb_age="$1" claim_age="$2" comp_age="$3"
  [ "$hb_age" -le "$STALL" ] || return 1
  [ "$claim_age" -le "$CLAIM_RECENT" ] || return 1
  [ "$claim_age" -lt "$comp_age" ] || return 1
  [ "$comp_age" -gt "$COMPLETION_STALL" ] || return 1
  # Cooldown: don't re-fire before the new session has had a full stall window.
  local since_last=$(( $(now) - LAST_COMPLETION_RESTART ))
  [ "$LAST_COMPLETION_RESTART" -eq 0 ] || [ "$since_last" -gt "$COMPLETION_STALL" ] || return 1
  return 0
}

# Testability: when sourced with RUSS_WATCHDOG_NO_MAIN=1, expose the functions
# (age_secs, is_completion_wedged, …) WITHOUT launching anything. The supervisor
# never sets this, so production behavior is unchanged.
if [ "${RUSS_WATCHDOG_NO_MAIN:-0}" = "1" ]; then
  # `return` works when sourced (tests); `exit` is the fallback when run directly.
  # shellcheck disable=SC2317  # the exit IS reachable when executed, not sourced.
  return 0 2>/dev/null || exit 0
fi

log "watchdog: starting (stall=${STALL}s cadence=${MAX_AGE}s completion_stall=${COMPLETION_STALL}s launchd_label=${LAUNCHD_LABEL:-none})"
restart "initial"
log "watchdog: entering supervise loop"
while true; do
  sleep 30
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    restart "session-gone"
    continue
  fi
  hb_age="$(age_secs "$HB")"
  claim_age="$(age_secs "$DISPATCH_LOG")"   # last need CLAIMED (dispatcher's own log)
  comp_age="$(age_secs "$COMPLETION_MARKER")"  # last need actually COMPLETED
  age=$(( $(now) - STARTED ))
  log "supervise: hb_age=${hb_age}s claim_age=${claim_age}s comp_age=${comp_age}s session_age=${age}s"
  if [ "$hb_age" -gt "$STALL" ]; then
    restart "stalled (no tick ${hb_age}s)"
  elif is_completion_wedged "$hb_age" "$claim_age" "$comp_age"; then
    # Ticking + claiming but NOT finishing — the fresh-heartbeat/zero-completion
    # wedge. In-place restart first; escalate to launchd if even that won't take.
    restart "completion-wedge (ticking+claiming, no completion ${comp_age}s, last claim ${claim_age}s ago)"
    LAST_COMPLETION_RESTART=$(now)
    sleep 5
    tmux has-session -t "$SESSION" 2>/dev/null || kickstart_self "tmux session did not come back after completion-wedge restart"
  elif [ "$age" -gt "$MAX_AGE" ]; then
    restart "cadence (${age}s — refresh context)"
  fi
done
