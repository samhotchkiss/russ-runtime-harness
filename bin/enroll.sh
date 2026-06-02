#!/usr/bin/env bash
# enroll.sh — self-register this machine as a Russell runtime using a one-time
# enrollment token, then write the long-lived credential for the daemon/dispatcher.
#
# This is run by your LOCAL AGENT (Claude CLI / Codex) as the last step of the
# copy-paste bootstrap the app's "Add external" flow gives you. The agent fills
# in what it is and which models it has — that is the "self-configure" step.
#
# Env (the bootstrap prompt sets these):
#   RUSS_BASE_URL        https://<tenant>.russ.team
#   RUSS_ENROLL_TOKEN    russ_enroll_…  (single-use, short-lived, owner-minted)
#   RUSS_RUNTIME_KIND    what you are: claude-cli | codex | <other>
#   RUSS_OFFERED_MODELS  comma-separated models you can run, e.g. haiku,sonnet,opus
#   RUSS_RUNTIME_NAME    optional label (default: hostname)
#
set -euo pipefail
: "${RUSS_BASE_URL:?set RUSS_BASE_URL}"
: "${RUSS_ENROLL_TOKEN:?set RUSS_ENROLL_TOKEN (from the app's Add-external prompt)}"
: "${RUSS_RUNTIME_KIND:?set RUSS_RUNTIME_KIND (claude-cli | codex | …)}"
: "${RUSS_OFFERED_MODELS:?set RUSS_OFFERED_MODELS (comma-separated)}"
NAME="${RUSS_RUNTIME_NAME:-$(hostname)}"
CONF="${RUSS_CONFIG:-$HOME/.russ/runtime.env}"

# models CSV → JSON array
models_json=$(printf '%s' "$RUSS_OFFERED_MODELS" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')

body=$(jq -cn --arg name "$NAME" --arg kind "$RUSS_RUNTIME_KIND" --argjson models "$models_json" \
  '{name:$name, kind:$kind, offered_models:$models}')

resp=$(curl -fsS --max-time 30 -X POST "$RUSS_BASE_URL/api/runtimes" \
  -H "Authorization: Bearer $RUSS_ENROLL_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$body") || { echo "enroll: registration call failed" >&2; exit 1; }

cred=$(jq -r '.credential // empty' <<<"$resp")
rid=$(jq -r '.runtime.id // empty' <<<"$resp")
if [ -z "$cred" ]; then
  echo "enroll: no credential in response: $resp" >&2
  exit 1
fi

mkdir -p "$(dirname "$CONF")"
umask 177
cat > "$CONF" <<EOF
# Russell runtime config — written by enroll.sh. Keep this file secret.
export RUSS_BASE_URL=$RUSS_BASE_URL
export RUSS_RUNTIME_CREDENTIAL=$cred
EOF

echo "enroll: registered $NAME [$RUSS_RUNTIME_KIND] as runtime $rid" >&2
echo "enroll: credential written to $CONF" >&2
echo "enroll: next — source it and start the harness:" >&2
echo "  source $CONF" >&2
echo "  caffeinate -dimsu runtime-harness/bin/heartbeat-daemon.sh &   # liveness" >&2
echo "  # then start a Haiku Claude Code session in runtime-harness/ (runs CLAUDE.md)" >&2
