#!/usr/bin/env bash
# run-dispatcher.sh — launch the Russell dispatcher as a WARM, long-lived session.
#
# The dispatcher MUST be a warm interactive session, never a one-shot headless
# invocation. `claude -p` / `codex exec` claim a need and open a turn, then EXIT
# before the per-need sub-agent can chat.post + complete_need → "agent never
# responds". This launches a warm interactive CLI in a detached tmux session,
# seeded to run the dispatch loop forever; per-need sub-agents are spawned
# IN-SESSION (Claude Task / Codex spawn_agent).
#
# Run AFTER sourcing your runtime config + starting the heartbeat daemon.
# Idempotent: re-running while the session is up is a no-op.
#
# Env:  RUSS_RUNTIME_KIND (claude-cli|codex; default claude-cli)
#       RUSS_RUNTIME_CREDENTIAL, RUSS_BASE_URL  (required — proves config sourced)
#       RUSS_DISPATCH_MODEL (claude default: sonnet), RUSS_DISPATCH_TMUX (russ-dispatch)
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

KIND="${RUSS_RUNTIME_KIND:-claude-cli}"
SESSION="${RUSS_DISPATCH_TMUX:-russ-dispatch}"

command -v tmux >/dev/null 2>&1 || { echo "ERROR: tmux required (brew install tmux)" >&2; exit 1; }

if [ -z "${RUSS_RUNTIME_CREDENTIAL:-}" ] || [ -z "${RUSS_BASE_URL:-}" ]; then
  echo "ERROR: RUSS_BASE_URL / RUSS_RUNTIME_CREDENTIAL not set — source your runtime config first." >&2
  exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Dispatcher already running in tmux session '$SESSION' — nothing to do."
  echo "  watch:  tmux attach -t $SESSION   (detach: Ctrl-b then d)"
  echo "  log:    tail -f $ROOT/dispatch.log"
  exit 0
fi

# Seeds contain NO apostrophes (embedded single-quoted in the tmux command).
case "$KIND" in
  claude*)
    MODEL="${RUSS_DISPATCH_MODEL:-sonnet}"
    SEED="You are the Russell dispatcher defined in CLAUDE.md, loaded as your project instructions in this directory. You ARE the loop — run it yourself, forever, without waiting for any input from me. Repeat continuously: (1) run bin/dispatch-tick.sh in the FOREGROUND and WAIT for it to finish — never run it in the background, and never start a second tick while one is still running (exactly one tick in flight at a time); (2) for every tab-separated line it prints, spawn exactly one BACKGROUND Task sub-agent set to that line model value, giving it the per-need sub-agent prompt from CLAUDE.md; (3) append one line per dispatch to dispatch.log; (4) only after the tick returns and any lines are dispatched, run bin/dispatch-tick.sh again. An empty tick (no output) is normal — just tick again. Do NOT set up Monitor or background watcher tasks. Do NOT claim the loop is running in the background. Do NOT declare success and stop. Do NOT end your turn. Never call chat tools yourself, never read the bundle files yourself. Begin now and keep ticking."
    LAUNCH="claude --model $MODEL --dangerously-skip-permissions '$SEED'"
    ;;
  codex*)
    SEED="You are the Russell dispatcher defined in CODEX.md in this directory. Read CODEX.md, then run that dispatcher loop now and keep running it FOREVER without waiting for input. Each iteration: run bin/dispatch-tick.sh, and for every tab-separated line spawn one multi_agent_v1.spawn_agent worker (fork_context false) at that line model value with the per-need sub-agent prompt from CODEX.md. Append one line per dispatch to dispatch.log, then loop. Do NOT declare success and stop. Do NOT end your turn. Never call chat tools yourself. Begin now."
    if [ -n "${RUSS_DISPATCH_MODEL:-}" ]; then
      LAUNCH="codex --model $RUSS_DISPATCH_MODEL --dangerously-bypass-approvals-and-sandbox '$SEED'"
    else
      LAUNCH="codex --dangerously-bypass-approvals-and-sandbox '$SEED'"
    fi
    ;;
  *)
    echo "ERROR: unknown RUSS_RUNTIME_KIND='$KIND' (expected claude-cli or codex)." >&2
    exit 1
    ;;
esac

# Bake the runtime env into the pane command. We CANNOT rely on tmux inheriting
# this shell's environment: when a tmux server is already running, new-session
# takes the server's (stale) global env, not ours — so dispatch-tick.sh would see
# no RUSS_BASE_URL. Pass the values explicitly (tokens/URLs have no apostrophes).
PANE_ENV="export RUSS_BASE_URL='$RUSS_BASE_URL'; export RUSS_RUNTIME_CREDENTIAL='$RUSS_RUNTIME_CREDENTIAL';"
[ -n "${RUSS_NEED_DIR:-}" ]   && PANE_ENV="$PANE_ENV export RUSS_NEED_DIR='$RUSS_NEED_DIR';"
[ -n "${RUSS_CONCURRENCY:-}" ] && PANE_ENV="$PANE_ENV export RUSS_CONCURRENCY='$RUSS_CONCURRENCY';"
[ -n "${RUSS_POLL_MAX_WAIT:-}" ] && PANE_ENV="$PANE_ENV export RUSS_POLL_MAX_WAIT='$RUSS_POLL_MAX_WAIT';"
[ -n "${RUSS_TICK_HEARTBEAT:-}" ] && PANE_ENV="$PANE_ENV export RUSS_TICK_HEARTBEAT='$RUSS_TICK_HEARTBEAT';"
# Propagate the completion marker so per-need sub-agents' russ_complete_need bumps
# the SAME marker the watchdog watches for the completion-throughput wedge check.
[ -n "${RUSS_COMPLETION_MARKER:-}" ] && PANE_ENV="$PANE_ENV export RUSS_COMPLETION_MARKER='$RUSS_COMPLETION_MARKER';"
tmux new-session -d -s "$SESSION" -c "$ROOT" "$PANE_ENV exec $LAUNCH"

echo "Dispatcher launched (warm interactive session, NOT headless):"
echo "  kind:  $KIND   model: ${MODEL:-default}   tmux: $SESSION"
echo "  watch: tmux attach -t $SESSION   (detach: Ctrl-b then d)"
echo "  log:   tail -f $ROOT/dispatch.log"
