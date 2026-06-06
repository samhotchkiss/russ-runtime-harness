#!/usr/bin/env bash
# warm-dispatcher.sh <runtime> — launch a WARM dispatcher for ONE runtime, fully
# namespaced so any number of runtimes coexist on one machine (the watchdog's reap
# is scoped per tmux-session + per-credential lock). Sources ~/.russ/runtime-<rt>.env
# (written by enroll.sh). Driven by the per-runtime launchd agent (install-runtime.sh).
set -uo pipefail
RT="${1:-${RUSS_RUNTIME_NAME:-}}"
[ -n "$RT" ] || { echo "usage: warm-dispatcher.sh <runtime-name>" >&2; exit 2; }

export HOME="${HOME:-/Users/sam}"
export PATH="/Users/sam/.local/bin:/Users/sam/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HOME/.russ/runtime-$RT.env"
[ -f "$CONF" ] || { echo "ERROR: $CONF not found — run bin/enroll.sh for '$RT' first." >&2; exit 1; }

# shellcheck disable=SC1090
source "$CONF"
export RUSS_RUNTIME_NAME="$RT"
export RUSS_DISPATCH_MODEL="${RUSS_DISPATCH_MODEL:-sonnet}"
export RUSS_CONCURRENCY="${RUSS_CONCURRENCY:-4}"
export RUSS_POLL_MAX_WAIT="${RUSS_POLL_MAX_WAIT:-30}"
# Per-runtime isolation (everything keyed by the runtime name):
export RUSS_DISPATCH_TMUX="russ-dispatch-$RT"
export RUSS_TICK_HEARTBEAT="$HOME/.russ/dispatcher-tick-$RT.heartbeat"
export RUSS_CONFIG="$CONF"
export RUSS_DISPATCH_WATCHDOG_LOG="/tmp/russ-dispatch-watchdog-$RT.log"
export RUSS_NEED_DIR="${RUSS_NEED_DIR:-/tmp/russ-needs-$RT}"

exec "$HERE/dispatcher-watchdog.sh"
