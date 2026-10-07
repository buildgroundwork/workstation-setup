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

# ── a session with a blocking item is blocked ───────────────────────────────
setup
seed sess-1 '{"summary":"","pane":"%42","items":[{"id":"b1","kind":"blocking","text":"needs approval","source":"","state":"unread","created_at":"2026-10-06T00:00:00Z"}]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].state]')" '["blocked"]' \
  "list marks a session with a blocking item as blocked"
teardown

# ── a session that only ever ran istatus decide is still listed ──────────────
# istatus.sh never writes a pane into the file, only the hooks do, so the pane
# has to come from the occupancy pointer.
setup
seed sess-1 '{"summary":"","items":[{"id":"n1","kind":"notice","text":"pick a name","state":"unread","priority":"normal","created_at":"2026-10-07T00:00:00Z"}]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[] | {session_id, pane, state}]')" \
  '[{"session_id":"sess-1","pane":"%42","state":"flagged"}]' \
  "list shows a session whose file has no pane, using the pane its pointer names"
teardown

# ── a session with an unread decide notice is flagged ────────────────────────
setup
seed sess-1 '{"summary":"","pane":"%42","items":[{"id":"n1","kind":"notice","text":"pick a name","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"}]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].state]')" '["flagged"]' \
  "list marks a session with an unread decide notice as flagged"
teardown

# ── a blocking item outranks an unread decide notice ─────────────────────────
setup
seed sess-1 '{"summary":"","pane":"%42","items":[{"id":"n1","kind":"notice","text":"pick a name","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"},{"id":"b1","kind":"blocking","text":"needs approval","source":"","state":"unread","created_at":"2026-10-06T00:00:01Z"}]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].state]')" '["blocked"]' \
  "list marks a session with both a blocking item and a decide notice as blocked"
teardown

# ── a session whose dispatched task finished is ready ────────────────────────
setup
seed sess-1 '{"summary":"","pane":"%42","items":[{"id":"r1","kind":"notice","text":"run the migration","source":"hub.ready","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"}]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].state]')" '["ready"]' \
  "list marks a session with an unread ready notice as ready"
teardown

# ── an unread decide notice outranks a finished dispatch ─────────────────────
setup
seed sess-1 '{"summary":"","pane":"%42","items":[{"id":"r1","kind":"notice","text":"run the migration","source":"hub.ready","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"},{"id":"n1","kind":"notice","text":"pick a name","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:01Z"}]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].state]')" '["flagged"]' \
  "list marks a session with a decide notice and a finished dispatch as flagged"
teardown

# ── a finished dispatch the human deferred no longer counts ──────────────────
setup
seed sess-1 '{"summary":"","pane":"%42","items":[{"id":"r1","kind":"notice","text":"run the migration","source":"hub.ready","state":"read","priority":"normal","created_at":"2026-10-06T00:00:00Z"}]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].state]')" '[""]' \
  "list leaves the state empty when the only item is a deferred ready notice"
teardown

# ── a session still working on a dispatched task is dispatched ───────────────
setup
seed sess-1 '{"summary":"","pane":"%42","items":[{"id":"d1","kind":"notice","text":"run the migration","source":"hub.dispatched","state":"read","priority":"low","created_at":"2026-10-06T00:00:00Z"}]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].state]')" '["dispatched"]' \
  "list marks a session with a dispatched notice as dispatched"
teardown

# ── nothing actionable leaves the state empty ───────────────────────────────
setup
seed sess-1 '{"summary":"","pane":"%42","items":[{"id":"n1","kind":"notice","text":"pick a name","state":"read","priority":"normal","created_at":"2026-10-06T00:00:00Z"}]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].state]')" '[""]' \
  "list leaves the state empty when the only item is a read decide notice"
teardown

# ── each state's row says why ────────────────────────────────────────────────
setup
seed sess-b '{"summary":"","pane":"%41","items":[{"id":"b1","kind":"blocking","text":"needs approval","source":"","state":"unread","created_at":"2026-10-06T00:00:00Z"}]}'
seed sess-f '{"summary":"","pane":"%42","items":[{"id":"n1","kind":"notice","text":"pick a name","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"}]}'
seed sess-r '{"summary":"","pane":"%43","items":[{"id":"r1","kind":"notice","text":"done task","source":"hub.ready","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"}]}'
seed sess-d '{"summary":"","pane":"%44","items":[{"id":"d1","kind":"notice","text":"working task","source":"hub.dispatched","state":"read","priority":"low","created_at":"2026-10-06T00:00:00Z"}]}'
seed sess-n '{"summary":"","pane":"%45","items":[]}'
occupy %41 sess-b
occupy %42 sess-f
occupy %43 sess-r
occupy %44 sess-d
occupy %45 sess-n
export ISTATUS_TMUX_PANES=$'%41\tp\t1\n%42\tp\t2\n%43\tp\t3\n%44\tp\t4\n%45\tp\t5'
assert_eq "$(list_of '[.[] | {session_id, reason}] | sort_by(.session_id) | map(.reason)')" \
  '["needs approval","working task","pick a name","","done task"]' \
  "list gives each state's row the text of the item behind it"
teardown

# ── a flagged row's reason is the newest unread decide notice ────────────────
setup
seed sess-1 '{"summary":"","pane":"%42","items":[{"id":"n1","kind":"notice","text":"old question","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:01Z"},{"id":"n2","kind":"notice","text":"new question","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:02Z"}]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[].reason]')" '["new question"]' \
  "list gives a flagged row the newest unread decide notice"
teardown

# ── an item whose source is not a string still gives its row a reason ────────
setup
seed sess-1 '{"summary":"","pane":"%42","items":[{"id":"n1","kind":"notice","text":"odd source","source":5,"state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"}]}'
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(list_of '[.[] | {state, reason}]')" '[{"state":"flagged","reason":"odd source"}]' \
  "list gives a reason to a flagged row whose item source is not a string"
teardown

# ── a status file whose items is not a list does not hide the others ─────────
setup
seed sess-1 '{"summary":"working on X","pane":"%42","items":[]}'
occupy %42 sess-1
seed sess-odd '{"summary":"s","pane":"%43","items":"oops"}'
occupy %43 sess-odd
export ISTATUS_TMUX_PANES=$'%42\tproj\t3\n%43\tproj\t4'
assert_eq "$(list_of '[.[].session_id | select(. == "sess-1")]')" '["sess-1"]' \
  "list keeps the other sessions when one file's items is not a list"
teardown

# ── a status file whose items are not objects does not hide the others ───────
setup
seed sess-1 '{"summary":"working on X","pane":"%42","items":[]}'
occupy %42 sess-1
seed sess-odd '{"summary":"s","pane":"%43","items":[1,"x",null]}'
occupy %43 sess-odd
export ISTATUS_TMUX_PANES=$'%42\tproj\t3\n%43\tproj\t4'
assert_eq "$(list_of '[.[].session_id | select(. == "sess-1")]')" '["sess-1"]' \
  "list keeps the other sessions when one file's items are not objects"
teardown

# ── a status file whose item source is not a string does not hide the others ─
setup
seed sess-1 '{"summary":"working on X","pane":"%42","items":[]}'
occupy %42 sess-1
seed sess-odd '{"summary":"s","pane":"%43","items":[{"kind":"notice","state":"unread","source":5}]}'
occupy %43 sess-odd
export ISTATUS_TMUX_PANES=$'%42\tproj\t3\n%43\tproj\t4'
assert_eq "$(list_of '[.[].session_id | select(. == "sess-1")]')" '["sess-1"]' \
  "list keeps the other sessions when one file's item source is not a string"
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

# ── the pane written in a status file is not what places the session ────────
# It used to be, which is why a file with a pane of the wrong type had its own
# case. The pointer decides now, so a pane of the wrong type, or a stale one,
# changes nothing.
setup
seed sess-num '{"summary":"s","pane":42,"items":[]}'
occupy %43 sess-num
seed sess-stale '{"summary":"s","pane":"%99","items":[]}'
occupy %44 sess-stale
export ISTATUS_TMUX_PANES=$'%43\tproj\t3\n%44\tproj\t4'
assert_eq "$(list_of '[.[] | {session_id, pane}] | sort_by(.session_id)')" \
  '[{"session_id":"sess-num","pane":"%43"},{"session_id":"sess-stale","pane":"%44"}]' \
  "list places a session by its pointer, whatever pane its file says"
teardown

# ── a session named by two live panes is listed once ─────────────────────────
setup
seed sess-1 '{"summary":"s","items":[]}'
occupy %41 sess-1
occupy %42 sess-1
export ISTATUS_TMUX_PANES=$'%41\tproj\t1\n%42\tproj\t2'
assert_eq "$(list_of '[.[] | {session_id, pane}]')" \
  '[{"session_id":"sess-1","pane":"%41"}]' \
  "list shows a session named by two live panes once, at the first listed"
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
