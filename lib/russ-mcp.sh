#!/usr/bin/env bash
# russ-mcp.sh — thin shell client for Russell's runtime/MCP contract.
#
# Source this from the dispatcher and from per-need sub-agents:
#   source "$(dirname "$0")/../lib/russ-mcp.sh"
#
# Required env:
#   RUSS_BASE_URL            your tenant's base URL, e.g. https://russell.russ.team
#   RUSS_RUNTIME_CREDENTIAL  the russ_runtime_… bearer minted at registration
#
# Every function prints the server's JSON-RPC *result payload* (the
# .result.structuredContent object) to stdout, or fails non-zero with the
# JSON-RPC error on stderr. Nothing here retries — reclaim is the server's job.
set -euo pipefail

: "${RUSS_BASE_URL:?set RUSS_BASE_URL to your tenant URL (e.g. https://russell.russ.team)}"
: "${RUSS_RUNTIME_CREDENTIAL:?set RUSS_RUNTIME_CREDENTIAL to the russ_runtime_… bearer}"

# _russ_rpc METHOD PARAMS_JSON — POST a JSON-RPC tools/call-style envelope to
# /api/mcp and echo .result.structuredContent. PARAMS_JSON is the full "params".
_russ_rpc() {
  local params="$1" body resp
  body=$(jq -cn --argjson params "$params" \
    '{jsonrpc:"2.0", id:1, method:"tools/call", params:$params}')
  resp=$(curl -fsS --max-time 60 -X POST "$RUSS_BASE_URL/api/mcp" \
    -H "Authorization: Bearer $RUSS_RUNTIME_CREDENTIAL" \
    -H "Content-Type: application/json" \
    --data "$body") || { echo "russ: transport error calling $RUSS_BASE_URL/api/mcp" >&2; return 1; }
  if [ "$(jq 'has("error")' <<<"$resp")" = "true" ]; then
    jq -c '.error' <<<"$resp" >&2
    return 1
  fi
  jq -c '.result.structuredContent' <<<"$resp"
}

# _russ_tool NAME ARGS_JSON — call a named tool with the given arguments object.
_russ_tool() {
  _russ_rpc "$(jq -cn --arg name "$1" --argjson args "$2" '{name:$name, arguments:$args}')"
}

# russ_heartbeat — refresh the runtime lease (REST). Run this on a timer from the
# heartbeat daemon; it is what keeps every in-flight claim alive (5-min window).
russ_heartbeat() {
  curl -fsS --max-time 30 -X POST "$RUSS_BASE_URL/api/runtimes/heartbeat" \
    -H "Authorization: Bearer $RUSS_RUNTIME_CREDENTIAL"
}

# russ_next_need — claim the next need for every bound agent. Prints the
# PollResult: {needs:[{need,identity,tool_manifest,context,claimed,runtime}], runtime}.
# This call ALSO heartbeats the runtime server-side.
russ_next_need() { _russ_tool "next_need" '{}'; }

# russ_complete_need NEED_ID — ack a finished need (the lease is released).
#
# On a SUCCESSFUL ack this also bumps the per-runtime COMPLETION MARKER's mtime.
# That marker is the local, dispatcher-independent "a need actually reached done"
# signal the watchdog uses to catch a fresh-heartbeat/zero-completion wedge (the
# loop keeps ticking + claiming but stops finishing needs). Every completion in
# this harness flows through this one function, so the marker can never drift from
# reality. It is opt-in via RUSS_COMPLETION_MARKER (the warm-dispatcher sets it
# per runtime, namespaced like RUSS_TICK_HEARTBEAT); unset = no-op, so sourcing
# this lib outside the dispatcher (e.g. a per-need worker that has its own env)
# costs nothing.
russ_complete_need() {
  local out rc=0
  # Guard against `set -e` (this lib runs under `set -euo pipefail`): a failed ack
  # must let us still inspect $? and propagate it, not abort the caller mid-completion.
  out="$(_russ_tool "complete_need" "$(jq -cn --arg id "$1" '{need_id:$id}')")" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "${RUSS_COMPLETION_MARKER:-}" ]; then
    mkdir -p "$(dirname "$RUSS_COMPLETION_MARKER")" 2>/dev/null || true
    : >> "$RUSS_COMPLETION_MARKER" 2>/dev/null || true
    touch "$RUSS_COMPLETION_MARKER" 2>/dev/null || true
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return "$rc"
}

# russ_chat_post NEED_ID IDEMPOTENCY_KEY BODY [PARENT_MESSAGE_ID]
# Post a reply AS the need's agent. Idempotency key MUST be stable across
# reclaims (derive it from NEED_ID) so a retried post de-dups server-side.
russ_chat_post() {
  local need="$1" key="$2" body="$3" parent="${4:-}"
  local inner
  if [ -n "$parent" ]; then
    inner=$(jq -cn --arg b "$body" --arg p "$parent" '{body:$b, parent_message_id:$p}')
  else
    inner=$(jq -cn --arg b "$body" '{body:$b}')
  fi
  _russ_tool "chat.post" "$(jq -cn --arg n "$need" --arg k "$key" --argjson a "$inner" \
    '{need_id:$n, idempotency_key:$k, arguments:$a}')"
}

# russ_chat_react NEED_ID IDEMPOTENCY_KEY MESSAGE_ID EMOJI [SIGNAL(-1|0|1)]
russ_chat_react() {
  local need="$1" key="$2" msg="$3" emoji="$4" signal="${5:-1}"
  local inner
  inner=$(jq -cn --arg m "$msg" --arg e "$emoji" --argjson s "$signal" \
    '{message_id:$m, emoji:$e, signal:$s}')
  _russ_tool "chat.react" "$(jq -cn --arg n "$need" --arg k "$key" --argjson a "$inner" \
    '{need_id:$n, idempotency_key:$k, arguments:$a}')"
}

# russ_chat_read_context NEED_ID [MESSAGE_ID] [RECENT_LIMIT]
# The long-tail fetch. Prefer the context already shipped in the need bundle;
# only call this when the bundle isn't enough. Read-only (no idempotency key).
russ_chat_read_context() {
  local need="$1" msg="${2:-}" limit="${3:-}"
  local inner='{}'
  if [ -n "$msg" ] && [ -n "$limit" ]; then
    inner=$(jq -cn --arg m "$msg" --argjson l "$limit" '{message_id:$m, recent_limit:$l}')
  elif [ -n "$msg" ]; then
    inner=$(jq -cn --arg m "$msg" '{message_id:$m}')
  elif [ -n "$limit" ]; then
    inner=$(jq -cn --argjson l "$limit" '{recent_limit:$l}')
  fi
  _russ_tool "chat.read_context" "$(jq -cn --arg n "$need" --argjson a "$inner" \
    '{need_id:$n, arguments:$a}')"
}
