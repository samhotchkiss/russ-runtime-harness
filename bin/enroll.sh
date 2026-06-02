#!/usr/bin/env bash
# enroll.sh — self-register this machine as a Russell runtime using a one-time
# enrollment token, then write the long-lived credential for the daemon/dispatcher.
#
# Run by your LOCAL AGENT (Claude CLI / Codex) as the last step of the "Add
# external" bootstrap. Set RUSS_RUNTIME_KIND to what you ACTUALLY are (claude-cli
# if you're Claude Code, codex if you're Codex) and RUSS_OFFERED_MODELS to the
# models you can really run.
#
# Env:
#   RUSS_BASE_URL        https://<tenant>.russ.team
#   RUSS_ENROLL_TOKEN    russ_enroll_... (single-use, short-lived)
#   RUSS_RUNTIME_KIND    what you are: claude-cli, codex, or other
#   RUSS_OFFERED_MODELS  comma-separated models you can run, e.g. haiku,sonnet,opus
#   RUSS_RUNTIME_NAME    optional; defaults to hostname
#   RUSS_CONFIG          optional; credential path (default ~/.russ/runtime.env)
#
# Written for bash 3.2 (macOS default). Deliberately avoids heredocs, <<<
# herestrings, multi-line $()/||, ${VAR:?...}, and non-ASCII in code — bash 3.2
# mis-parses those together and silently scrambles execution.
set -eu

fail() { echo "enroll: $1" >&2; exit 1; }

[ -n "${RUSS_BASE_URL:-}" ]       || fail "set RUSS_BASE_URL"
[ -n "${RUSS_ENROLL_TOKEN:-}" ]   || fail "set RUSS_ENROLL_TOKEN (from the Add-external prompt)"
[ -n "${RUSS_RUNTIME_KIND:-}" ]   || fail "set RUSS_RUNTIME_KIND (claude-cli, codex, ...)"
[ -n "${RUSS_OFFERED_MODELS:-}" ] || fail "set RUSS_OFFERED_MODELS (comma-separated)"

NAME="${RUSS_RUNTIME_NAME:-}"
[ -n "$NAME" ] || NAME=$(hostname)
CONF="${RUSS_CONFIG:-$HOME/.russ/runtime.env}"

models_json=$(printf '%s' "$RUSS_OFFERED_MODELS" | jq -Rc 'split(",")|map(gsub("^ +| +$";""))|map(select(length>0))')
[ -n "$models_json" ] || fail "could not parse RUSS_OFFERED_MODELS"

body=$(jq -cn --arg name "$NAME" --arg kind "$RUSS_RUNTIME_KIND" --argjson models "$models_json" '{name:$name,kind:$kind,offered_models:$models}')

if ! resp=$(curl -fsS --max-time 30 -X POST "$RUSS_BASE_URL/api/runtimes" -H "Authorization: Bearer $RUSS_ENROLL_TOKEN" -H "Content-Type: application/json" --data "$body"); then
  fail "registration call failed (token expired/used, or server unreachable)"
fi

cred=$(printf '%s' "$resp" | jq -r '.credential // empty')
rid=$(printf '%s' "$resp" | jq -r '.runtime.id // empty')
[ -n "$cred" ] || fail "no credential in response: $resp"

mkdir -p "$(dirname "$CONF")"
umask 177
{
  printf '%s\n' '# Russell runtime config — keep this file secret.'
  printf 'export RUSS_BASE_URL=%s\n' "$RUSS_BASE_URL"
  printf 'export RUSS_RUNTIME_CREDENTIAL=%s\n' "$cred"
} > "$CONF"

echo "enroll: registered $NAME [$RUSS_RUNTIME_KIND] as runtime $rid" >&2
echo "enroll: credential written to $CONF" >&2
echo "enroll: next - source it and start the harness:" >&2
echo "  source $CONF" >&2
echo "  caffeinate -dimsu ./bin/heartbeat-daemon.sh &   # liveness (off-model)" >&2
echo "  # then start your warm dispatcher session in this directory (see CLAUDE.md)" >&2
