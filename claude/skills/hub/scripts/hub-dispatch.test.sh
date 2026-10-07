#!/usr/bin/env bash
# Tests for hub-dispatch.sh ready — the list of dispatched panes the hub reads
# back. Only `ready` is unit-tested: send, capture and go need a live tmux. The
# arm and viewed calls that send and capture make are one-line calls into
# istatus-hook.sh, which has its own tests, and are exercised end to end.
#
# `ready` reads the istatus inbox, so the cases seed status files and pane
# pointers and give the inbox its pane listing through ISTATUS_TMUX_PANES. No
# `set -e`: a failing script must surface as a FAIL line from assert_eq, not as
# an abort.
#
# Run: claude/skills/hub/scripts/hub-dispatch.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/hub-dispatch.sh"
DIR=""
PASS=0
FAIL=0
TAB=$'\t'

setup() {
  DIR="$(mktemp -d)"
  export CLAUDE_TMUX_ATTENTION_DIR="$DIR"
  unset ISTATUS_TMUX_PANES
}
teardown() { [[ -n "$DIR" && -d "$DIR" ]] && rm -rf "$DIR"; DIR=""; }
trap teardown EXIT

# live_session <session_id> <pane> <items json> — a status file for a session
# whose pane is live and whose pointer names it.
live_session() {
  mkdir -p "$DIR/status" "$DIR/panes"
  jq -n -c --arg pane "$2" --argjson items "$3" '{summary: "", pane: $pane, items: $items}' \
    > "$DIR/status/$1.json"
  printf '%s' "$1" > "$DIR/panes/$2.session_id"
}

# hub_notice <id> <text> <state> <source> — a hub notice.
hub_notice() {
  jq -n -c --arg id "$1" --arg text "$2" --arg state "$3" --arg source "$4" \
    '{id: $id, kind: "notice", text: $text, source: $source, state: $state, priority: "normal", created_at: "2026-10-06T00:00:00Z"}'
}

# ready -> what `hub-dispatch.sh ready` prints, stderr dropped, stdin closed.
ready() { "$SCRIPT" ready 2>/dev/null </dev/null; }

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label (got [$got], want [$want])"
    FAIL=$((FAIL + 1))
  fi
}

# ── a finished dispatch is listed as task.ready ──────────────────────────────
setup
live_session sess-1 %42 "[$(hub_notice r1 "run the migration" unread hub.ready)]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(ready)" "task.ready${TAB}proj:3${TAB}run the migration" \
  "ready lists a finished dispatch as task.ready"
teardown

# ── a dispatch still working is listed as task.dispatched ────────────────────
setup
live_session sess-1 %42 "[$(hub_notice d1 "run the migration" read hub.dispatched)]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(ready)" "task.dispatched${TAB}proj:3${TAB}run the migration" \
  "ready lists a working dispatch as task.dispatched"
teardown

# ── a session that is not part of a dispatch is not listed ───────────────────
setup
live_session sess-1 %42 "[$(jq -n -c '{id:"b1",kind:"blocking",text:"needs approval",source:"",state:"unread",created_at:"2026-10-06T00:00:00Z"}')]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(ready)" "" \
  "ready leaves out a session with no dispatch"
teardown

# ── a dispatch that hit its own permission prompt is still listed ────────────
setup
BLOCKING_ITEM='{"id":"b1","kind":"blocking","text":"needs approval","source":"","state":"unread","created_at":"2026-10-06T00:00:00Z"}'
live_session sess-1 %42 "[$BLOCKING_ITEM, $(hub_notice d1 "run the migration" read hub.dispatched)]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(ready)" "task.dispatched${TAB}proj:3${TAB}run the migration" \
  "ready lists a dispatch whose session is also blocked, with the prompt"
teardown

# ── a finished dispatch is listed even when the session has a decide too ─────
setup
DECIDE_ITEM='{"id":"n1","kind":"notice","text":"pick a name","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"}'
live_session sess-1 %42 "[$DECIDE_ITEM, $(hub_notice r1 "run the migration" unread hub.ready)]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(ready)" "task.ready${TAB}proj:3${TAB}run the migration" \
  "ready lists a finished dispatch whose session is also flagged, with the prompt"
teardown

# ── a finished dispatch that was already viewed is still listed ──────────────
# Focusing the pane marks the ready notice read. If that dropped it from
# `ready`, the hub could not report a result Adam happened to glance at, and
# hub-wait, which counts a read ready notice as finished, would disagree.
setup
live_session sess-1 %42 "[$(hub_notice r1 "run the migration" read hub.ready)]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(ready)" "task.ready${TAB}proj:3${TAB}run the migration" \
  "ready lists a finished dispatch that was already viewed as task.ready"
teardown

# ── a prompt with tabs or newlines is still one line per pane ────────────────
setup
live_session sess-1 %42 "[$(hub_notice r1 $'run\tthe\nmigration' unread hub.ready)]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(ready)" "task.ready${TAB}proj:3${TAB}run the migration" \
  "ready turns tabs and newlines in a prompt into spaces"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
