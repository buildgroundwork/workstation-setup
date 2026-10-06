#!/usr/bin/env bash
# Tests for hub-status.sh's attention lookup: the one label per tmux session
# that the dashboard shows, taken from the istatus inbox. The rest of the
# script (transcripts, context bars, layout) needs a live machine and is not
# tested here.
#
# The script is sourced, not run, so its functions can be called without
# hub-map.sh. The inbox is real: the cases seed status files and pane pointers
# and give it its pane listing through ISTATUS_TMUX_PANES. Each lookup runs in
# a subshell, because the script turns on `set -e`. A failing lookup shows as
# an empty answer and a FAIL line from assert_eq.
#
# Run: claude/skills/hub/scripts/hub-status.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/hub-status.sh"
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

DECIDE='{"id":"n1","kind":"notice","text":"pick a name","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"}'

# attn_of <tmux session name> -> the label the dashboard resolves for it.
attn_of() {
  ( source "$SCRIPT"; load_attention; attn_kind "$1" ) 2>/dev/null </dev/null
}

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

# ── a session with an unread decide notice is flagged ────────────────────────
setup
live_session sess-1 %42 "[$DECIDE]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(attn_of proj)" "flagged" \
  "a tmux session holding a flagged Claude session resolves to flagged"
teardown

# ── the other states keep the dashboard's own words ──────────────────────────
BLOCKING='{"id":"b1","kind":"blocking","text":"needs approval","source":"","state":"unread","created_at":"2026-10-06T00:00:00Z"}'
READY='{"id":"r1","kind":"notice","text":"done","source":"hub.ready","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"}'
DISPATCHED='{"id":"d1","kind":"notice","text":"working","source":"hub.dispatched","state":"read","priority":"low","created_at":"2026-10-06T00:00:00Z"}'
READ_DECIDE='{"id":"n1","kind":"notice","text":"pick a name","state":"read","priority":"normal","created_at":"2026-10-06T00:00:00Z"}'

# resolves_to <items json> <want> <label> — one live session in proj with these
# items resolves to the wanted label.
resolves_to() {
  setup
  live_session sess-1 %42 "[$1]"
  export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
  assert_eq "$(attn_of proj)" "$2" "$3"
  teardown
}
resolves_to "$BLOCKING" "waiting" "a blocked Claude session resolves to waiting"
resolves_to "$READY" "ready" "a finished dispatch resolves to ready"
resolves_to "$DISPATCHED" "dispatched" "a dispatch in flight resolves to dispatched"
resolves_to "$READ_DECIDE" "" "a session with nothing actionable resolves to nothing"

# ── several Claude sessions in one tmux session show the most urgent ─────────
setup
live_session sess-a %41 "[$DISPATCHED]"
live_session sess-b %42 "[$BLOCKING]"
live_session sess-c %43 "[$READY]"
export ISTATUS_TMUX_PANES="%41${TAB}proj${TAB}1
%42${TAB}proj${TAB}2
%43${TAB}proj${TAB}3"
assert_eq "$(attn_of proj)" "waiting" \
  "a tmux session with several Claude sessions resolves to the most urgent"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
