#!/usr/bin/env bash
# Tests for istatus-hook.sh — the Claude Code hook entry point that writes
# "blocking" items into a session's istatus file.
# Plain bash, no framework, no deps beyond jq, a scratch state dir per case.
#
# The hook keys off CLAUDE_TMUX_ATTENTION_DIR, so each case points it at a
# temp dir. No `set -e`: a missing or failing hook must surface as a FAIL line
# from assert_eq, not as an abort.
#
# Run: claude/skills/istatus/scripts/istatus-hook.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/istatus-hook.sh"
DIR=""
PASS=0
FAIL=0

setup() {
  DIR="$(mktemp -d)"
  export CLAUDE_TMUX_ATTENTION_DIR="$DIR"
}
teardown() { [[ -n "$DIR" && -d "$DIR" ]] && rm -rf "$DIR"; DIR=""; }
trap teardown EXIT

# add <pane> <session_id> [message] — feed a Notification payload for a pane.
add() {
  local pane="$1" sid="$2" msg="${3:-blocked}"
  printf '{"session_id":"%s","cwd":"/tmp/proj","hook_event_name":"Notification","message":"%s"}' "$sid" "$msg" \
    | TMUX=fake TMUX_PANE="$pane" "$SCRIPT" add
}

# seed <session_id> <json> — write a pre-existing status file for a session.
seed() {
  mkdir -p "$DIR/status"
  printf '%s' "$2" > "$DIR/status/$1.json"
}

# items_of <session_id> <jq projection> -> compact JSON of the projection, or
# [] when the status file is absent.
items_of() {
  local file="$DIR/status/$1.json"
  [[ -f "$file" ]] || { echo '[]'; return 0; }
  jq -c "$2" "$file"
}

# pointer_of <pane> -> the session id the pane's occupancy pointer names, or
# nothing when the pointer file is absent.
pointer_of() {
  local file="$DIR/panes/$1.session_id"
  [[ -f "$file" ]] || return 0
  cat "$file"
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

# ── a permission prompt records one unread blocking item ─────────────────────
setup
add %42 sess-1 "Claude needs your permission to use Bash"
assert_eq "$(items_of sess-1 '[.items[] | {kind, state, text}]')" \
  '[{"kind":"blocking","state":"unread","text":"Claude needs your permission to use Bash"}]' \
  "permission_prompt Notification adds one unread blocking item"
teardown

# ── add appends to an existing status file, preserving summary and items ─────
setup
seed sess-1 '{"summary":"working on X","items":[{"id":"n1","kind":"notice","text":"pick a name","state":"unread","priority":"normal","created_at":"2026-10-05T00:00:00Z"}]}'
add %42 sess-1 "Claude needs your permission to use Bash"
assert_eq "$(items_of sess-1 '{summary, kinds: [.items[].kind]}')" \
  '{"summary":"working on X","kinds":["notice","blocking"]}' \
  "add into an existing status file keeps the summary and appends"
teardown

# ── add records the pane the session lives in ────────────────────────────────
setup
add %42 sess-1 "Claude needs your permission to use Bash"
assert_eq "$(items_of sess-1 '.pane')" '"%42"' \
  "add records the pane in the status file"
teardown

# ── add records which session occupies the pane ──────────────────────────────
setup
add %42 sess-1 "Claude needs your permission to use Bash"
assert_eq "$(pointer_of %42)" "sess-1" \
  "add writes the pane occupancy pointer"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
