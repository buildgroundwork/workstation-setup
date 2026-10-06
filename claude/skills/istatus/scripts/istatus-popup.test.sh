#!/usr/bin/env bash
# Tests for istatus-popup.sh rows — the list the tmux popup shows. One row per
# live session that has something to act on or watch, most urgent first, as
# tab-separated columns: label, session:window, reason, summary, pane.
# Plain bash, no framework, no deps beyond jq, a scratch state dir per case.
#
# `rows` calls the real inbox, so the cases seed status files and pane
# pointers and give the inbox its pane listing through ISTATUS_TMUX_PANES. The
# fzf popup half of the script is not unit-tested; it is exercised end to end.
# No `set -e`: a missing or failing script must surface as a FAIL line from
# assert_eq, not as an abort.
#
# Run: claude/skills/istatus/scripts/istatus-popup.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/istatus-popup.sh"
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

# live_session <session_id> <pane> <summary> <items json> — a status file for a
# session whose pane is live and whose pointer names it.
live_session() {
  mkdir -p "$DIR/status" "$DIR/panes"
  jq -n -c --arg pane "$2" --arg summary "$3" --argjson items "$4" \
    '{summary: $summary, pane: $pane, items: $items}' > "$DIR/status/$1.json"
  printf '%s' "$1" > "$DIR/panes/$2.session_id"
}

# blocking <text> — a blocking item.
blocking() {
  jq -n -c --arg text "$1" \
    '{id: "b1", kind: "blocking", text: $text, source: "", state: "unread", created_at: "2026-10-06T00:00:00Z"}'
}

# notice <id> <text> <state> <created_at> [source] — a notice; with no source it
# is a decide notice, otherwise a hub one.
notice() {
  jq -n -c --arg id "$1" --arg text "$2" --arg state "$3" --arg ts "$4" --arg source "${5:-}" '
    { id: $id, kind: "notice", text: $text, state: $state, priority: "normal", created_at: $ts }
    + (if $source != "" then { source: $source } else {} end)'
}

# rows -> what `istatus-popup.sh rows` prints, stderr dropped, stdin closed.
rows() { "$SCRIPT" rows 2>/dev/null </dev/null; }

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

# ── a blocked session is one row ─────────────────────────────────────────────
setup
live_session sess-1 %42 "working on X" "[$(blocking "Claude needs your permission to use Bash")]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(rows)" "needs you${TAB}proj:3${TAB}Claude needs your permission to use Bash${TAB}working on X${TAB}%42" \
  "a blocked session is a needs-you row with its blocking text"
teardown

# ── an unread decide notice is a wants-you row ───────────────────────────────
setup
live_session sess-1 %42 "working on X" "[$(notice n1 "pick a name" unread 2026-10-06T00:00:00Z)]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(rows)" "wants you${TAB}proj:3${TAB}pick a name${TAB}working on X${TAB}%42" \
  "a flagged session is a wants-you row with its decide text"
teardown

# ── a finished dispatch is a ready row ───────────────────────────────────────
setup
live_session sess-1 %42 "" "[$(notice r1 "run the migration" unread 2026-10-06T00:00:00Z hub.ready)]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(rows)" "ready${TAB}proj:3${TAB}run the migration${TAB}${TAB}%42" \
  "a ready session is a ready row with the dispatched prompt"
teardown

# ── a dispatch still working is a working row ────────────────────────────────
setup
live_session sess-1 %42 "" "[$(notice d1 "run the migration" read 2026-10-06T00:00:00Z hub.dispatched)]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(rows)" "working${TAB}proj:3${TAB}run the migration${TAB}${TAB}%42" \
  "a dispatched session is a working row with the dispatched prompt"
teardown

# ── rows come most urgent first ──────────────────────────────────────────────
setup
live_session sess-a %41 "" "[$(notice d1 "dispatched task" read 2026-10-06T00:00:00Z hub.dispatched)]"
live_session sess-b %42 "" "[$(notice r1 "finished task" unread 2026-10-06T00:00:00Z hub.ready)]"
live_session sess-c %43 "" "[$(notice n1 "a decision" unread 2026-10-06T00:00:00Z)]"
live_session sess-d %44 "" "[$(blocking "a prompt")]"
export ISTATUS_TMUX_PANES="%41${TAB}proj${TAB}1
%42${TAB}proj${TAB}2
%43${TAB}proj${TAB}3
%44${TAB}proj${TAB}4"
assert_eq "$(rows | cut -f1 | paste -sd, -)" "needs you,wants you,ready,working" \
  "rows run from blocked to dispatched"
teardown

# ── equally urgent rows keep a stable order by session and window ────────────
setup
live_session sess-a %41 "" "[$(blocking "first")]"
live_session sess-b %42 "" "[$(blocking "second")]"
export ISTATUS_TMUX_PANES="%41${TAB}proj${TAB}10
%42${TAB}proj${TAB}2"
assert_eq "$(rows | cut -f2 | paste -sd, -)" "proj:2,proj:10" \
  "equally urgent rows are ordered by window number"
teardown

# ── the reason is the newest unread decide notice ────────────────────────────
setup
live_session sess-1 %42 "" "[$(notice n1 "old question" unread 2026-10-06T00:00:01Z), $(notice n2 "new question" unread 2026-10-06T00:00:02Z)]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(rows | cut -f3)" "new question" \
  "a flagged row shows the newest unread decide notice"
teardown

# ── tabs and newlines in a text cannot split a row ───────────────────────────
setup
live_session sess-1 %42 $'x\ny' "[$(blocking $'a\tb\nc')]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(rows)" "needs you${TAB}proj:3${TAB}a b c${TAB}x y${TAB}%42" \
  "tabs and newlines in a reason or summary become spaces"
teardown

# ── nothing to act on or watch prints nothing ────────────────────────────────
setup
live_session sess-1 %42 "working on X" "[$(notice n1 "pick a name" read 2026-10-06T00:00:00Z)]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(rows)" "" \
  "a session with nothing actionable is not a row"
teardown

# ── an item with a non-string source does not blank the list ─────────────────
setup
live_session sess-1 %42 "" "[$(notice n1 "odd source" unread 2026-10-06T00:00:00Z | jq -c '.source = 5')]"
export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
assert_eq "$(rows)" "wants you${TAB}proj:3${TAB}odd source${TAB}${TAB}%42" \
  "a flagged row still shows when its item's source is not a string"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
