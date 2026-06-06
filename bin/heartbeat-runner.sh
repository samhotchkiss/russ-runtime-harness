#!/usr/bin/env bash
# heartbeat-runner.sh <runtime> — keep ONE runtime's lease alive. Sources
# ~/.russ/runtime-<rt>.env and runs heartbeat-daemon.sh with RUSS_RUNTIME_NAME set,
# so the daemon can auto-teardown this runtime if it is removed in the russ UI.
# Driven by the per-runtime launchd agent (install-runtime.sh).
set -uo pipefail
RT="${1:-${RUSS_RUNTIME_NAME:-}}"
[ -n "$RT" ] || { echo "usage: heartbeat-runner.sh <runtime-name>" >&2; exit 2; }

export HOME="${HOME:-/Users/sam}"
export PATH="/Users/sam/.local/bin:/Users/sam/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HOME/.russ/runtime-$RT.env"
[ -f "$CONF" ] || { echo "ERROR: $CONF not found — run bin/enroll.sh for '$RT' first." >&2; exit 1; }

# shellcheck disable=SC1090
source "$CONF"
export RUSS_RUNTIME_NAME="$RT"

exec "$HERE/heartbeat-daemon.sh"
