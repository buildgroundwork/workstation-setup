#!/usr/bin/env bash
# Tests for istatus.sh. Minimal: only the one-time migration of a status file
# written by the pre-items version of the script, which the hooks and the
# reader now share a file with. The commands themselves are exercised by hand.
# Plain bash, no framework, no deps beyond jq, a scratch state dir per case.
#
# istatus.sh needs a session id, so each case runs it with
# CLAUDE_CODE_SESSION_ID set, and with TMUX_PANE unset so it writes no pane
# pointer. No `set -e`: a failing script must surface as a FAIL line from
# assert_eq, not as an abort.
#
# Run: claude/skills/istatus/scripts/istatus.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/istatus.sh"
DIR=""
PASS=0
FAIL=0

setup() {
  DIR="$(mktemp -d)"
  export CLAUDE_TMUX_ATTENTION_DIR="$DIR"
  mkdir -p "$DIR/status"
}
teardown() { [[ -n "$DIR" && -d "$DIR" ]] && rm -rf "$DIR"; DIR=""; }
trap teardown EXIT

# seed <session_id> <json> — write a session's status file.
seed() { printf '%s' "$2" > "$DIR/status/$1.json"; }

# summary <session_id> — run `istatus summary` for the session.
summary() {
  printf 'working\n' | env -u TMUX_PANE CLAUDE_CODE_SESSION_ID="$1" "$SCRIPT" summary >/dev/null 2>&1
}

# state_of <session_id> <jq projection> -> compact JSON, or nothing when the
# file is absent.
state_of() {
  local file="$DIR/status/$1.json"
  [[ -f "$file" ]] || return 0
  jq -c "$2" "$file"
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

# ── migrating a pre-items file keeps its other keys ──────────────────────────
# The hooks record the session's pane in the same file; the migration used to
# rebuild it as just { summary, items } and drop the pane.
setup
seed sess-1 '{"summary":"old","pane":"%42","decisions":[{"id":"d1","text":"old q","created_at":"2026-01-01T00:00:00Z"}]}'
summary sess-1
assert_eq "$(state_of sess-1 '{pane, has_decisions: has("decisions"), kinds: [.items[].kind]}')" \
  '{"pane":"%42","has_decisions":false,"kinds":["notice"]}' \
  "migrating a pre-items file converts its decisions and keeps its pane"
teardown

# ── a file with items and a lingering decisions key keeps its items ──────────
setup
seed sess-1 '{"summary":"s","pane":"%42","items":[{"id":"n1","kind":"notice","text":"keep me","state":"unread","priority":"normal","created_at":"2026-01-01T00:00:00Z"}],"decisions":[{"id":"d1","text":"stale","created_at":"2026-01-01T00:00:00Z"}]}'
summary sess-1
assert_eq "$(state_of sess-1 '{has_decisions: has("decisions"), texts: [.items[].text]}')" \
  '{"has_decisions":false,"texts":["keep me"]}' \
  "a lingering decisions key is dropped and the existing items win"
teardown

# ── a file with neither items nor decisions gets an empty item list ──────────
setup
seed sess-1 '{"summary":"s","pane":"%42"}'
summary sess-1
assert_eq "$(state_of sess-1 '{pane, items}')" '{"pane":"%42","items":[]}' \
  "a file with no items gets an empty list and keeps its pane"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
