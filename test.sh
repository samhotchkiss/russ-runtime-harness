#!/usr/bin/env bash
# test.sh — unit tests for the runtime harness.
#
# Focus of this suite: the dispatcher-watchdog COMPLETION-THROUGHPUT detector
# (Refs #1617) — the fresh-heartbeat / zero-completion wedge that the
# stale-heartbeat, dead-tmux, and cadence checks all miss. Plus the local
# completion signal in lib/russ-mcp.sh (russ_complete_need bumps the marker).
#
# Pure bash, no network: we source the watchdog with RUSS_WATCHDOG_NO_MAIN=1 to
# get its functions without launching anything, and drive russ_complete_need
# against a fake `curl` on PATH.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
failures=0

log()  { printf '[harness-test] %s\n' "$*"; }
fail() { printf '[harness-test] FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

run_test() {
  local name=$1; shift
  log "running $name"
  if ( set +e; "$@" ); then
    log "pass $name"
  else
    fail "$name"
  fi
}

# Load the watchdog functions (age_secs, is_completion_wedged, …) without main.
load_watchdog() {
  # Defaults the watchdog reads at source-time; override per test as needed.
  : "${STALL:=150}" "${COMPLETION_STALL:=600}" "${CLAIM_RECENT:=600}"
  : "${LAST_COMPLETION_RESTART:=0}"
  export RUSS_WATCHDOG_NO_MAIN=1
  export RUSS_DISPATCH_STALL_SECS="$STALL"
  export RUSS_DISPATCH_COMPLETION_STALL_SECS="$COMPLETION_STALL"
  export RUSS_DISPATCH_CLAIM_RECENT_SECS="$CLAIM_RECENT"
  # shellcheck disable=SC1091  # sourced at runtime to expose watchdog functions
  source "$ROOT_DIR/bin/dispatcher-watchdog.sh"
}

# ---- completion-throughput detector --------------------------------------

# THE BUG: heartbeat fresh (ticking), claim recent (still grabbing needs), but no
# completion for longer than COMPLETION_STALL → must be flagged as wedged.
test_wedge_fires_on_fresh_hb_recent_claim_stale_completion() {
  ( load_watchdog
    LAST_COMPLETION_RESTART=0
    # hb_age=30 (fresh), claim_age=60 (recent, < comp_age), comp_age=900 (>600 stall)
    is_completion_wedged 30 60 900
  )
}

# Healthy: completions are flowing (comp_age small) → NOT wedged, even though the
# dispatcher is ticking and claiming.
test_wedge_quiet_when_completions_healthy() {
  ( load_watchdog
    LAST_COMPLETION_RESTART=0
    # comp_age=20 → well under stall, and newer than claim → not wedged
    ! is_completion_wedged 30 60 20
  )
}

# Idle dispatcher: no recent claim (claim_age huge) → there is simply nothing to
# complete; must NOT be treated as a wedge.
test_wedge_quiet_when_idle_no_recent_claims() {
  ( load_watchdog
    LAST_COMPLETION_RESTART=0
    # claim_age=5000 > CLAIM_RECENT(600) → idle, not wedged
    ! is_completion_wedged 30 5000 900
  )
}

# Stale heartbeat is the OTHER branch's job (restart "stalled"); the completion
# detector must not also claim it (avoids double-counting / wrong reason).
test_wedge_quiet_when_heartbeat_stale() {
  ( load_watchdog
    LAST_COMPLETION_RESTART=0
    # hb_age=400 > STALL(150) → not a completion wedge (stalled branch handles it)
    ! is_completion_wedged 400 60 900
  )
}

# Completion newer than the last claim → all claimed work has been finished;
# nothing outstanding → not wedged.
test_wedge_quiet_when_completion_newer_than_claim() {
  ( load_watchdog
    LAST_COMPLETION_RESTART=0
    # comp_age=50 < claim_age=60 → last completion is more recent than last claim
    ! is_completion_wedged 30 60 50
  )
}

# Cooldown: right after a completion-wedge restart, a still-cold session that has
# not completed anything yet must NOT immediately re-trip.
test_wedge_respects_cooldown_after_restart() {
  ( load_watchdog
    # Just restarted "now" → since_last ~0 < COMPLETION_STALL → suppressed
    LAST_COMPLETION_RESTART="$(date +%s)"
    ! is_completion_wedged 30 60 900
  )
}

# After the cooldown window elapses, a persistent wedge fires again.
test_wedge_fires_again_after_cooldown_elapses() {
  ( load_watchdog
    # Last restart far in the past → cooldown elapsed → wedge fires
    LAST_COMPLETION_RESTART="$(( $(date +%s) - COMPLETION_STALL - 100 ))"
    is_completion_wedged 30 60 900
  )
}

# ---- fixture-driven (real files → age_secs → is_completion_wedged) --------

# End-to-end of the detector path the supervise loop runs: build real heartbeat /
# dispatch.log / completion-marker files on disk, age them with `touch -t`, and
# feed age_secs's output into is_completion_wedged exactly like the loop does.

# Set a file's mtime to N seconds ago (BSD touch -t, macOS).
backdate() { touch -t "$(date -v-"$2"S +%Y%m%d%H%M.%S)" "$1"; }

# Fixture: heartbeat fresh, a claim 60s ago, completion 900s ago → WEDGED.
test_fixture_fresh_hb_zero_completion_triggers_restart() {
  ( load_watchdog
    LAST_COMPLETION_RESTART=0
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    hb="$tmp/hb"; dl="$tmp/dispatch.log"; cm="$tmp/marker"
    touch "$hb"                 # fresh tick
    backdate "$dl" 60           # claimed 60s ago (recent, outstanding)
    backdate "$cm" 900          # last completion 900s ago (> 600 stall)
    is_completion_wedged "$(age_secs "$hb")" "$(age_secs "$dl")" "$(age_secs "$cm")"
  )
}

# Fixture: same activity but completions are flowing (marker fresh) → NOT wedged.
test_fixture_fresh_hb_healthy_completions_no_restart() {
  ( load_watchdog
    LAST_COMPLETION_RESTART=0
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    hb="$tmp/hb"; dl="$tmp/dispatch.log"; cm="$tmp/marker"
    touch "$hb"                 # fresh tick
    backdate "$dl" 60           # claimed 60s ago
    touch "$cm"                 # just completed → healthy
    ! is_completion_wedged "$(age_secs "$hb")" "$(age_secs "$dl")" "$(age_secs "$cm")"
  )
}

# ---- age_secs helper ------------------------------------------------------

test_age_secs_reports_ancient_for_missing_file() {
  ( load_watchdog
    a="$(age_secs "/no/such/file/$$")"
    [ "$a" -ge 999999 ]
  )
}

test_age_secs_reports_small_for_fresh_file() {
  ( load_watchdog
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
    touch "$tmp"
    a="$(age_secs "$tmp")"
    [ "$a" -ge 0 ] && [ "$a" -le 5 ]
  )
}

# ---- completion marker (the local signal) ---------------------------------

make_fake_mcp_curl() {  # <bin-dir> <exit-code>
  local dir=$1 code=$2
  mkdir -p "$dir"
  cat > "$dir/curl" <<SH
#!/usr/bin/env bash
# Fake curl: echoes a JSON-RPC result and exits $code (to simulate ack success/failure).
cat >/dev/null 2>&1 || true
printf '{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"ok":true}}}\n'
exit $code
SH
  chmod +x "$dir/curl"
}

# On a SUCCESSFUL ack, the per-runtime completion marker's mtime is bumped — this
# is the signal the watchdog reads.
test_complete_need_bumps_marker_on_success() {
  ( tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    make_fake_mcp_curl "$tmp/bin" 0
    marker="$tmp/marker"
    PATH="$tmp/bin:$PATH" \
    RUSS_BASE_URL=https://acme.russ.team \
    RUSS_RUNTIME_CREDENTIAL=russ_runtime_test \
    RUSS_COMPLETION_MARKER="$marker" \
      bash -c 'source "$1"; russ_complete_need 00000000-0000-0000-0000-000000000001 >/dev/null' \
        bash "$ROOT_DIR/lib/russ-mcp.sh"
    [ -f "$marker" ]
  )
}

# On a FAILED ack (curl non-zero), the marker is NOT created — a wedge must not be
# masked by failed completions.
test_complete_need_skips_marker_on_failure() {
  ( tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    make_fake_mcp_curl "$tmp/bin" 1
    marker="$tmp/marker"
    PATH="$tmp/bin:$PATH" \
    RUSS_BASE_URL=https://acme.russ.team \
    RUSS_RUNTIME_CREDENTIAL=russ_runtime_test \
    RUSS_COMPLETION_MARKER="$marker" \
      bash -c 'source "$1"; russ_complete_need 00000000-0000-0000-0000-000000000001 >/dev/null 2>&1 || true' \
        bash "$ROOT_DIR/lib/russ-mcp.sh"
    [ ! -f "$marker" ]
  )
}

# With no marker configured, russ_complete_need is a plain no-op write-wise (does
# not error, does not create stray files).
test_complete_need_noop_marker_when_unset() {
  ( tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    make_fake_mcp_curl "$tmp/bin" 0
    PATH="$tmp/bin:$PATH" \
    RUSS_BASE_URL=https://acme.russ.team \
    RUSS_RUNTIME_CREDENTIAL=russ_runtime_test \
      bash -c 'unset RUSS_COMPLETION_MARKER; source "$1"; russ_complete_need 00000000-0000-0000-0000-000000000001 >/dev/null' \
        bash "$ROOT_DIR/lib/russ-mcp.sh"
  )
}

run_test "wedge fires on fresh-hb + recent-claim + stale-completion"   test_wedge_fires_on_fresh_hb_recent_claim_stale_completion
run_test "wedge quiet when completions are healthy"                    test_wedge_quiet_when_completions_healthy
run_test "wedge quiet when idle (no recent claims)"                    test_wedge_quiet_when_idle_no_recent_claims
run_test "wedge quiet when heartbeat is stale (stalled branch owns it)" test_wedge_quiet_when_heartbeat_stale
run_test "wedge quiet when completion is newer than last claim"        test_wedge_quiet_when_completion_newer_than_claim
run_test "wedge respects cooldown right after a restart"               test_wedge_respects_cooldown_after_restart
run_test "wedge fires again once the cooldown window elapses"          test_wedge_fires_again_after_cooldown_elapses
run_test "fixture: fresh-hb + zero-completion triggers restart"        test_fixture_fresh_hb_zero_completion_triggers_restart
run_test "fixture: fresh-hb + healthy-completions does NOT restart"    test_fixture_fresh_hb_healthy_completions_no_restart
run_test "age_secs reports ancient for a missing file"                 test_age_secs_reports_ancient_for_missing_file
run_test "age_secs reports small for a fresh file"                     test_age_secs_reports_small_for_fresh_file
run_test "complete_need bumps the completion marker on success"        test_complete_need_bumps_marker_on_success
run_test "complete_need skips the marker on a failed ack"              test_complete_need_skips_marker_on_failure
run_test "complete_need is a no-op marker-wise when unset"             test_complete_need_noop_marker_when_unset

if [ "$failures" -ne 0 ]; then
  log "$failures test(s) failed"
  exit 1
fi
log "all tests passed"
