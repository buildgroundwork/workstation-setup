#!/usr/bin/env bash
# Tests for istatus.sh: the one-time migration of a status file written by the
# pre-items version of the script, and the --pane commands the popup and the
# sidebar use to act on another session's items. The in-session commands are
# otherwise exercised by hand.
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

# outside <args...> — run istatus the way the popup and the sidebar do: from
# pane %1, outside any Claude session (no CLAUDE_CODE_SESSION_ID). Prints the
# exit status as rc=N.
outside() {
  env -u CLAUDE_CODE_SESSION_ID TMUX_PANE=%1 "$SCRIPT" "$@" >/dev/null 2>&1
  echo "rc=$?"
}

# refusal <needle> <args...> — run like outside and report whether it failed
# with an error naming <needle>. "refused" only when both hold, so a script
# that dies early for some other reason does not pass a refusal test.
refusal() {
  local needle="$1" err rc
  shift
  err=$(env -u CLAUDE_CODE_SESSION_ID TMUX_PANE=%1 "$SCRIPT" "$@" 2>&1 >/dev/null </dev/null)
  rc=$?
  [[ $rc -ne 0 && "$err" == *"$needle"* ]] && echo refused || echo "not refused (rc=$rc: $err)"
}

# point <pane> <session_id> — record that the session occupies the pane.
point() { mkdir -p "$DIR/panes"; printf '%s' "$2" > "$DIR/panes/$1.session_id"; }

# A session with a permission prompt pending and two unread decide notices.
# In ordinal order: [1] the blocking item, [2] n1, [3] n2.
SEED_MIXED='{"summary":"s","items":[
  {"id":"n1","kind":"notice","text":"first","state":"unread","priority":"normal","created_at":"2026-01-01T00:00:01Z"},
  {"id":"n2","kind":"notice","text":"second","state":"unread","priority":"normal","created_at":"2026-01-01T00:00:02Z"},
  {"id":"b1","kind":"blocking","source":"","text":"needs permission","state":"unread","created_at":"2026-01-01T00:00:00Z"}]}'

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

# ── --pane defers another session's notice by its sidebar ordinal ───────────
setup
seed sess-2 "$SEED_MIXED"
point %9 sess-2
outside --pane %9 defer 2 >/dev/null
assert_eq "$(state_of sess-2 '[.items[] | {id, state}]')" \
  '[{"id":"n1","state":"read"},{"id":"n2","state":"unread"},{"id":"b1","state":"unread"}]' \
  "--pane defer marks the target session's notice read"
teardown

# ── --pane defer --all defers every unread notice and no blocking item ──────
setup
seed sess-2 "$SEED_MIXED"
point %9 sess-2
outside --pane %9 defer --all >/dev/null
assert_eq "$(state_of sess-2 '[.items[] | {id, state}]')" \
  '[{"id":"n1","state":"read"},{"id":"n2","state":"read"},{"id":"b1","state":"unread"}]' \
  "--pane defer --all marks every notice read and leaves the blocking item"
teardown

# ── undefer marks a read notice unread again ─────────────────────────────────
setup
seed sess-2 '{"summary":"s","items":[{"id":"n1","kind":"notice","text":"first","state":"read","priority":"normal","created_at":"2026-01-01T00:00:01Z"}]}'
point %9 sess-2
outside --pane %9 undefer n1 >/dev/null
assert_eq "$(state_of sess-2 '[.items[].state]')" '["unread"]' \
  "undefer marks a read notice unread"
teardown

# ── undefer refuses a blocking item ──────────────────────────────────────────
setup
seed sess-2 "$SEED_MIXED"
point %9 sess-2
assert_eq "$(refusal "blocking" --pane %9 undefer b1)" "refused" \
  "undefer refuses a blocking item"
teardown

# ── --pane resolve removes the target session's item ─────────────────────────
setup
seed sess-2 "$SEED_MIXED"
point %9 sess-2
outside --pane %9 resolve n1 >/dev/null
assert_eq "$(state_of sess-2 '[.items[].id]')" '["n2","b1"]' \
  "--pane resolve removes the target session's item"
teardown

# ── --pane never records the caller's pane as the target's ───────────────────
setup
seed sess-2 "$SEED_MIXED"
point %9 sess-2
outside --pane %9 defer n1 >/dev/null
# Both facts in one value, so this cannot pass by the command not running.
assert_eq "$(state_of sess-2 '[.items[] | select(.id == "n1") | .state][0]'):$([[ -e "$DIR/panes/%1.session_id" ]] && echo present || echo absent)" \
  '"read":absent' \
  "--pane acts on the target and writes no occupancy pointer for the caller's pane"
teardown

# ── --pane on a pane with no known session fails ─────────────────────────────
setup
seed sess-2 "$SEED_MIXED"
point %9 sess-2
assert_eq "$(refusal "no session" --pane %77 defer --all)" "refused" \
  "--pane fails for a pane no session is recorded in"
teardown

# ── --pane does not create a status file for the target session ─────────────
setup
point %9 sess-2
assert_eq "$(refusal "no istatus state" --pane %9 defer --all):$([[ -e "$DIR/status/sess-2.json" ]] && echo present || echo absent)" \
  "refused:absent" \
  "--pane fails, and creates nothing, for a session with no status file"
teardown

# ── resolving a notice keeps it in the done list ─────────────────────────────
setup
seed sess-2 "$SEED_MIXED"
point %9 sess-2
outside --pane %9 resolve n1 >/dev/null
assert_eq "$(state_of sess-2 '{items: [.items[].id], done: [.done[] | {id, resolved: has("resolved_at")}]}')" \
  '{"items":["n2","b1"],"done":[{"id":"n1","resolved":true}]}' \
  "a resolved notice moves to done, stamped with when"
teardown

# ── resolving a blocking item does not keep it ───────────────────────────────
setup
seed sess-2 "$SEED_MIXED"
point %9 sess-2
outside --pane %9 resolve b1 >/dev/null
assert_eq "$(state_of sess-2 '{items: [.items[].id], done: (.done // [])}')" \
  '{"items":["n1","n2"],"done":[]}' \
  "a force-cleared blocking item is gone, not done"
teardown

# ── the done list keeps the last 20 ──────────────────────────────────────────
setup
seed sess-2 "$(jq -c '.done = [range(20) | {id: "old\(.)", kind: "notice", text: "old", state: "read", priority: "normal", created_at: "2026-01-01T00:00:00Z", resolved_at: "2026-01-01T00:00:00Z"}]' <<<"$SEED_MIXED")"
point %9 sess-2
outside --pane %9 resolve n1 >/dev/null
assert_eq "$(state_of sess-2 '[(.done | length), .done[0].id, .done[-1].id]')" \
  '[20,"old1","n1"]' \
  "resolving past 20 done drops the oldest"
teardown

# ── restore brings a done notice back, unread ────────────────────────────────
setup
seed sess-2 '{"summary":"s","items":[],"done":[{"id":"n1","kind":"notice","text":"first","state":"read","priority":"normal","created_at":"2026-01-01T00:00:01Z","resolved_at":"2026-01-01T00:00:05Z"}]}'
point %9 sess-2
outside --pane %9 restore n1 >/dev/null
assert_eq "$(state_of sess-2 '{items: [.items[] | {id, state, resolved: has("resolved_at")}], done}')" \
  '{"items":[{"id":"n1","state":"unread","resolved":false}],"done":[]}' \
  "restore moves a done notice back to the open items, unread"
teardown

# ── restore refuses an id that is not done ───────────────────────────────────
setup
seed sess-2 "$SEED_MIXED"
point %9 sess-2
assert_eq "$(refusal "no done item" --pane %9 restore n1)" "refused" \
  "restore refuses an item that is still open"
teardown

# ── --pane only runs the commands that act on existing items ─────────────────
setup
seed sess-2 "$SEED_MIXED"
point %9 sess-2
assert_eq "$(refusal "--pane" --pane %9 summary)" "refused" \
  "--pane refuses summary, which belongs to the session itself"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
