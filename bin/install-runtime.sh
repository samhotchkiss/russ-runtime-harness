#!/usr/bin/env bash
# install-runtime.sh <runtime> — install launchd agents so a runtime auto-starts on
# login and is supervised (like russell), coexisting with any others on the machine.
# Run AFTER bin/enroll.sh has written ~/.russ/runtime-<runtime>.env.
#
# Creates two user LaunchAgents, both caffeinated + KeepAlive:
#   team.<runtime>.runtime-harness.heartbeat          -> bin/heartbeat-runner.sh <runtime>
#   team.<runtime>.runtime-harness.claude-dispatcher  -> bin/warm-dispatcher.sh  <runtime>
# Removal: bin/teardown-runtime.sh <runtime>  (or just remove the external in the
# russ UI — the heartbeat daemon auto-tears down on revocation).
set -euo pipefail
RT="${1:?usage: install-runtime.sh <runtime-name>}"

export HOME="${HOME:-/Users/sam}"
uid="$(id -u)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONF="$HOME/.russ/runtime-$RT.env"
[ -f "$CONF" ] || { echo "ERROR: $CONF not found — run bin/enroll.sh for '$RT' first." >&2; exit 1; }
LA="$HOME/Library/LaunchAgents"; mkdir -p "$LA"

dispatch_label="team.$RT.runtime-harness.claude-dispatcher"
heartbeat_label="team.$RT.runtime-harness.heartbeat"

write_plist() {  # <label> <program-arg>...
  local label="$1"; shift
  local f="$LA/$label.plist" arg
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>${label}</string>"
    echo '  <key>ProgramArguments</key><array>'
    for arg in "$@"; do echo "    <string>${arg}</string>"; done
    echo '  </array>'
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>KeepAlive</key><true/>'
    echo "  <key>WorkingDirectory</key><string>${ROOT}</string>"
    echo "  <key>StandardOutPath</key><string>/tmp/russ-${label}.log</string>"
    echo "  <key>StandardErrorPath</key><string>/tmp/russ-${label}.log</string>"
    echo '</dict></plist>'
  } > "$f"
  echo "$f"
}

hp="$(write_plist "$heartbeat_label" /usr/bin/caffeinate -dimsu /bin/bash "$ROOT/bin/heartbeat-runner.sh" "$RT")"
dp="$(write_plist "$dispatch_label"  /usr/bin/caffeinate -dimsu /bin/bash "$ROOT/bin/warm-dispatcher.sh"  "$RT")"

# Reload cleanly (bootout any prior, then bootstrap).
for lbl in "$heartbeat_label" "$dispatch_label"; do
  launchctl bootout "gui/$uid/$lbl" 2>/dev/null || true
done
launchctl bootstrap "gui/$uid" "$hp"
launchctl bootstrap "gui/$uid" "$dp"

echo "installed launchd agents for runtime '$RT':"
echo "  heartbeat:  $heartbeat_label   ($hp)"
echo "  dispatcher: $dispatch_label   ($dp)"
echo "  watch:  tmux attach -t russ-dispatch-$RT"
echo "  remove: bin/teardown-runtime.sh $RT   (or remove the external in the russ UI)"
