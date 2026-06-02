#!/usr/bin/env bash
# dispatch-tick.sh — one detection tick for the dispatcher.
#
# Blocks until needs arrive (or the poll window lapses), writes each need's full
# bundle to a file, and prints ONLY a compact TSV summary, one line per need:
#
#   <need_id>\t<model>\t<trigger_kind>\t@<slug>\t<bundle_path>
#
# The point of this script is CONTEXT HYGIENE: the heavy bundle (the 30-message
# context envelope, about_md, operator_instructions, tool manifest) flows through
# a bash pipe to a file and NEVER enters the dispatcher's context window. The
# dispatcher reads only these short lines and spawns one sub-agent per line.
#
# Model resolution (single source of truth, here in bash so the dispatcher stays
# dumb): identity.model_policy.model if set, else a trigger-based default
# (review needs are cheap/often no-op → haiku; pinged needs → opus). The value
# must be one of: haiku | sonnet | opus (the sub-agent spawn's model arg).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NEED_DIR="${RUSS_NEED_DIR:-/tmp/russ-needs}"
mkdir -p "$NEED_DIR"

result="$("$HERE/next-need-blocking.sh")"

# Emit the summary; persist each bundle to its own file as we go.
jq -r '.needs[]?.need.id' <<<"$result" | while read -r id; do
  [ -n "$id" ] || continue
  jq -c --arg id "$id" '.needs[] | select(.need.id == $id)' <<<"$result" > "$NEED_DIR/$id.json"
  model=$(jq -r --arg id "$id" '
    .needs[] | select(.need.id == $id) |
    (.identity.model_policy.model)
      // (if .need.trigger_kind == "review" then "haiku" else "opus" end)
  ' <<<"$result")
  trigger=$(jq -r --arg id "$id" '.needs[] | select(.need.id==$id) | .need.trigger_kind' <<<"$result")
  slug=$(jq -r --arg id "$id" '.needs[] | select(.need.id==$id) | .identity.slug' <<<"$result")
  printf '%s\t%s\t%s\t@%s\t%s\n' "$id" "$model" "$trigger" "$slug" "$NEED_DIR/$id.json"
done
