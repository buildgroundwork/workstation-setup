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

# A session that already ran istatus summary and istatus decide.
SEED_WITH_NOTICE='{"summary":"working on X","items":[{"id":"n1","kind":"notice","text":"pick a name","state":"unread","priority":"normal","created_at":"2026-10-05T00:00:00Z"}]}'

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

# ask_question <pane> <session_id> <question> — feed a PreToolUse payload for an
# AskUserQuestion menu (tool-use events carry no `message` field).
ask_question() {
  local pane="$1" sid="$2" question="$3"
  printf '{"session_id":"%s","cwd":"/tmp/proj","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"%s","header":"h","options":[],"multiSelect":false}]}}' "$sid" "$question" \
    | TMUX=fake TMUX_PANE="$pane" "$SCRIPT" add
}

# resolve <session_id> — feed a resolution payload with no tool_name (models a
# non-tool resolution: UserPromptSubmit / SessionEnd).
resolve() {
  printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$1" | "$SCRIPT" remove
}

# complete_tool <session_id> <tool_name> [agent_id] — feed a PostToolUse
# resolution for a completing tool; agent_id is included only when given (a
# subagent's tool completing).
complete_tool() {
  local sid="$1" tool="$2" agent="${3:-}" agent_field=""
  [[ -z "$agent" ]] || agent_field=",\"agent_id\":\"$agent\""
  printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"%s"%s}' "$sid" "$tool" "$agent_field" \
    | "$SCRIPT" remove
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
seed sess-1 "$SEED_WITH_NOTICE"
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

# ── an AskUserQuestion menu records what raised it ───────────────────────────
setup
ask_question %42 sess-1 "Which database?"
assert_eq "$(items_of sess-1 '[.items[] | {kind, source}]')" \
  '[{"kind":"blocking","source":"AskUserQuestion"}]' \
  "AskUserQuestion PreToolUse records what raised the block"
teardown

# ── an AskUserQuestion menu shows the question being asked ───────────────────
setup
ask_question %42 sess-1 "Which database?"
assert_eq "$(items_of sess-1 '[.items[] | {kind, text}]')" \
  '[{"kind":"blocking","text":"Which database?"}]' \
  "AskUserQuestion PreToolUse records the question as the item text"
teardown

# ── a non-tool resolution clears blocking items and leaves notices alone ─────
setup
seed sess-1 "$SEED_WITH_NOTICE"
add %42 sess-1 "Claude needs your permission to use Bash"
resolve sess-1
assert_eq "$(items_of sess-1 '{summary, kinds: [.items[].kind]}')" \
  '{"summary":"working on X","kinds":["notice"]}' \
  "a non-tool resolution clears blocking items and keeps the notice and summary"
teardown

# ── an unrelated tool finishing leaves a pending menu in place ───────────────
setup
ask_question %42 sess-1 "Which database?"
complete_tool sess-1 Bash
assert_eq "$(items_of sess-1 '[.items[] | {kind, source}]')" \
  '[{"kind":"blocking","source":"AskUserQuestion"}]' \
  "a different tool completing does not clear a pending menu"
teardown

# ── the tool that raised a menu finishing clears it ──────────────────────────
setup
ask_question %42 sess-1 "Which database?"
complete_tool sess-1 AskUserQuestion
assert_eq "$(items_of sess-1 '[.items[].kind]')" '[]' \
  "the raising tool completing clears its menu"
teardown

# ── a subagent's tool finishing leaves the parent's permission prompt ────────
setup
add %42 sess-1 "Claude needs your permission to use Bash"
complete_tool sess-1 Bash agent-7
assert_eq "$(items_of sess-1 '[.items[].kind]')" '["blocking"]' \
  "a subagent tool completing does not clear a permission prompt"
teardown

# ── a session with no status file resolves silently ──────────────────────────
setup
assert_eq "$(complete_tool sess-9 Bash 2>&1; echo "rc=$?")" "rc=0" \
  "remove for a session with no status file is a silent no-op"
teardown

# ── a hook failure never reaches the session ─────────────────────────────────
setup
assert_eq "$(printf 'not json' | "$SCRIPT" add 2>/dev/null; echo "rc=$?")" "rc=0" \
  "a malformed payload exits 0 with nothing on stdout"
teardown

# ── a write waits for the session lock istatus.sh also takes ─────────────────
setup
mkfifo "$DIR/release"
( flock -x 9; read -r _ < "$DIR/release" ) 9>"$DIR/status-sess-1.lock" &
holder=$!
sleep 0.2
add %42 sess-1 "Claude needs your permission to use Bash" &
adder=$!
sleep 0.3
assert_eq "$(items_of sess-1 '[.items[].kind]')" '[]' \
  "add waits while another writer holds the session lock"
echo > "$DIR/release"
wait "$holder" "$adder"
teardown

# ── a top-level tool finishing clears a pending permission prompt ────────────
setup
add %42 sess-1 "Claude needs your permission to use Bash"
complete_tool sess-1 Bash
assert_eq "$(items_of sess-1 '[.items[].kind]')" '[]' \
  "a top-level tool completing clears a permission prompt"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
