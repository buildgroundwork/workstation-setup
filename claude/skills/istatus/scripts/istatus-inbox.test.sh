#!/usr/bin/env bash
# Tests for istatus-inbox.sh — the shared reader behind the status line, the
# popup and the hub scripts. It turns the per-session status files into one
# list of the sessions that are still live.
# Plain bash, no framework, no deps beyond jq, a scratch state dir per case.
#
# Tests can't make fake panes live in tmux, so ISTATUS_TMUX_PANES holds the
# lines `tmux list-panes -a -F '#{pane_id}<TAB>#{session_name}<TAB>#{window_index}'`
# would print (tab-separated, since a session name can contain spaces) and the
# reader uses it in place of tmux. Liveness stays under test. No `set -e`: a
# missing or failing reader must surface as a FAIL line from assert_eq, not as
# an abort.
#
# Run: claude/skills/istatus/scripts/istatus-inbox.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/istatus-inbox.sh"
DIR=""
PASS=0
FAIL=0

setup() {
  DIR="$(mktemp -d)"
  export CLAUDE_TMUX_ATTENTION_DIR="$DIR"
  unset ISTATUS_TMUX_PANES
}
teardown() { [[ -n "$DIR" && -d "$DIR" ]] && rm -rf "$DIR"; DIR=""; }
trap teardown EXIT

# seed <session_id> <json> — write a session's status file.
seed() {
  mkdir -p "$DIR/status"
  printf '%s' "$2" > "$DIR/status/$1.json"
}

# occupy <pane> <session_id> — write the pane's occupancy pointer.
occupy() {
  mkdir -p "$DIR/panes"
  printf '%s' "$2" > "$DIR/panes/$1.session_id"
}

# list_of <jq projection> -> compact JSON of the projection over `list`, or
# nothing when the reader is missing or fails.
list_of() { "$SCRIPT" list 2>/dev/null </dev/null | jq -c "$1"; }

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

# ── a live session is listed with where it lives ─────────────────────────────
setup
seed sess-1 '{"summary":"working on X","pane":"%42","items":[]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[] | {session_id, pane, tmux_session, tmux_window, summary}]')" \
  '[{"session_id":"sess-1","pane":"%42","tmux_session":"proj","tmux_window":"3","summary":"working on X"}]' \
  "list shows a live session with its pane and tmux location"
teardown

# ── no sessions have written anything yet ────────────────────────────────────
setup
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '.')" '[]' \
  "list is an empty array when there is no status directory"
teardown

# ── a pane taken over by another session drops the old session's file ───────
setup
seed sess-old '{"summary":"old","pane":"%42","items":[]}'
occupy %42 sess-new
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].session_id]')" '[]' \
  "list omits a session whose pane now belongs to another session"
teardown

# ── a tmux session name containing spaces is kept whole ──────────────────────
setup
seed sess-1 '{"summary":"working on X","pane":"%42","items":[]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tReBAC Relationship Writer\t3'
assert_eq "$(list_of '[.[].tmux_session]')" '["ReBAC Relationship Writer"]' \
  "list keeps a tmux session name that contains spaces"
teardown

# ── one malformed status file does not hide the others ───────────────────────
setup
seed sess-1 '{"summary":"working on X","pane":"%42","items":[]}'
occupy %42 sess-1
seed sess-bad '{not json'
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].session_id]')" '["sess-1"]' \
  "list skips a malformed status file and still shows the others"
teardown

# ── a status file that is valid JSON but not an object is skipped ────────────
setup
seed sess-1 '{"summary":"working on X","pane":"%42","items":[]}'
occupy %42 sess-1
seed sess-arr '[]'
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].session_id]')" '["sess-1"]' \
  "list skips a status file that is not a JSON object"
teardown

# ── a status file whose pane is not a string is skipped ──────────────────────
setup
seed sess-1 '{"summary":"working on X","pane":"%42","items":[]}'
occupy %42 sess-1
seed sess-num '{"summary":"s","pane":42,"items":[]}'
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].session_id]')" '["sess-1"]' \
  "list skips a status file whose pane is not a string"
teardown

# ── every status file is malformed ───────────────────────────────────────────
setup
seed sess-bad '{not json'
seed sess-worse 'also not json'
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '.')" '[]' \
  "list is an empty array when every status file is malformed"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
