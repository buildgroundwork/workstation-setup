#!/usr/bin/env bash
# Tests for hub-wait.sh — block until a dispatched pane finishes, then print it.
#
# hub-wait resolves its target and prints the pane with tmux, so the cases put a
# stub `tmux` first on PATH: display-message prints the pane id %42 and
# capture-pane prints the line CAPTURE. The state comes from the real istatus
# inbox, seeded through status files and pane pointers, with the inbox's pane
# listing given by ISTATUS_TMUX_PANES. Exit codes are read back with `rc=`.
# No `set -e`: a failing script must surface as a FAIL line from assert_eq.
#
# Run: claude/skills/hub/scripts/hub-wait.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/hub-wait.sh"
DIR=""
PASS=0
FAIL=0
TAB=$'\t'

setup() {
  DIR="$(mktemp -d)"
  export CLAUDE_TMUX_ATTENTION_DIR="$DIR"
  export ISTATUS_TMUX_PANES="%42${TAB}proj${TAB}3"
  export HUB_WAIT_INTERVAL=1
  mkdir "$DIR/bin"
  cat > "$DIR/bin/tmux" <<'STUB'
#!/bin/bash
case "$1" in
  display-message) echo '%42' ;;
  capture-pane)    echo 'CAPTURE' ;;
esac
STUB
  chmod +x "$DIR/bin/tmux"
}
teardown() { [[ -n "$DIR" && -d "$DIR" ]] && rm -rf "$DIR"; DIR=""; }
trap teardown EXIT

# live_session <session_id> <items json> — a status file for a session that
# occupies the live pane %42.
live_session() {
  mkdir -p "$DIR/status" "$DIR/panes"
  # Written to a temp file and moved into place, as the hooks do, so a poll
  # that lands mid-write never reads a half-written status file.
  jq -n -c --argjson items "$2" '{summary: "", pane: "%42", items: $items}' > "$DIR/status/$1.tmp"
  mv "$DIR/status/$1.tmp" "$DIR/status/$1.json"
  printf '%s' "$1" > "$DIR/panes/%42.session_id"
}

# hub_notice <id> <text> <state> <source> — a hub notice.
hub_notice() {
  jq -n -c --arg id "$1" --arg text "$2" --arg state "$3" --arg source "$4" \
    '{id: $id, kind: "notice", text: $text, source: $source, state: $state, priority: "normal", created_at: "2026-10-06T00:00:00Z"}'
}

BLOCKING='{"id":"b1","kind":"blocking","text":"needs approval","source":"","state":"unread","created_at":"2026-10-06T00:00:00Z"}'

# wait_for [timeout] -> stdout of hub-wait.sh proj:3, then its exit status as
# rc=N. Stderr is dropped. The default timeout of 10 stops a stuck wait from
# hanging the suite; it would show as rc=2.
wait_for() {
  PATH="$DIR/bin:$PATH" "$SCRIPT" proj:3 "${1:-10}" 2>/dev/null </dev/null
  echo "rc=$?"
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

# ── a finished dispatch returns the pane ─────────────────────────────────────
setup
live_session sess-1 "[$(hub_notice r1 "run the migration" unread hub.ready)]"
assert_eq "$(wait_for)" $'CAPTURE\nrc=0' \
  "a finished dispatch prints the pane and exits 0"
teardown

# ── a dispatch blocked on its own prompt returns early ───────────────────────
setup
live_session sess-1 "[$BLOCKING, $(hub_notice d1 "run the migration" read hub.dispatched)]"
assert_eq "$(wait_for)" $'CAPTURE\nrc=4' \
  "a blocked dispatch prints the pane and exits 4"
teardown

# ── a pane that was never armed is not waited on ─────────────────────────────
setup
live_session sess-1 '[]'
assert_eq "$(wait_for)" 'rc=3' \
  "a pane with no dispatch exits 3"
teardown

# ── a finished dispatch the human already viewed still counts as finished ────
# Focusing the pane marks the ready notice read while hub-wait may still be
# polling; an unread-only check would then never see it finish.
setup
live_session sess-1 "[$(hub_notice r1 "run the migration" read hub.ready)]"
assert_eq "$(wait_for)" $'CAPTURE\nrc=0' \
  "a finished dispatch that was already viewed still exits 0"
teardown

# ── a dispatch that finishes while waiting returns the pane ──────────────────
setup
live_session sess-1 "[$(hub_notice d1 "run the migration" read hub.dispatched)]"
( sleep 1.5
  live_session sess-1 "[$(hub_notice r1 "run the migration" unread hub.ready)]" ) &
bg=$!
assert_eq "$(wait_for)" $'CAPTURE\nrc=0' \
  "a dispatch that finishes mid-wait prints the pane and exits 0"
wait "$bg"
teardown

# ── a dispatch that disappears while waiting stops the wait ──────────────────
setup
live_session sess-1 "[$(hub_notice d1 "run the migration" read hub.dispatched)]"
( sleep 1.5
  live_session sess-1 '[]' ) &
bg=$!
assert_eq "$(wait_for 6)" 'rc=3' \
  "a dispatch that is no longer armed mid-wait exits 3"
wait "$bg"
teardown

# ── a first look that misses the dispatch for one poll is still waited on ───
# The same transient (tmux busy, so the inbox sees no live panes) can hit the
# very first poll. The dispatch shows up before the second one, then finishes.
setup
live_session sess-1 '[]'
( sleep 0.4
  live_session sess-1 "[$(hub_notice d1 "run the migration" read hub.dispatched)]"
  sleep 1.6
  live_session sess-1 "[$(hub_notice r1 "run the migration" unread hub.ready)]" ) &
bg=$!
assert_eq "$(wait_for 15)" $'CAPTURE\nrc=0' \
  "a dispatch missing on the first look only is still waited on"
wait "$bg"
teardown

# ── a dispatch that blinks out for one poll is still waited on ───────────────
# One empty read can be a transient (tmux busy, so the inbox sees no live
# panes). The status goes empty between two polls and comes back before the
# next, then the dispatch finishes.
setup
live_session sess-1 "[$(hub_notice d1 "run the migration" read hub.dispatched)]"
( sleep 0.4
  live_session sess-1 '[]'
  sleep 1.2
  live_session sess-1 "[$(hub_notice d1 "run the migration" read hub.dispatched)]"
  sleep 1.4
  live_session sess-1 "[$(hub_notice r1 "run the migration" unread hub.ready)]" ) &
bg=$!
assert_eq "$(wait_for 15)" $'CAPTURE\nrc=0' \
  "a dispatch missing for a single poll does not end the wait"
wait "$bg"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
