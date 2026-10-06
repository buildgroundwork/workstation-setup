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

# start <pane> <session_id> — feed a SessionStart payload for a pane.
start() {
  local pane="$1" sid="$2"
  printf '{"session_id":"%s","cwd":"/tmp/proj","hook_event_name":"SessionStart","source":"startup"}' "$sid" \
    | TMUX=fake TMUX_PANE="$pane" "$SCRIPT" start
}

# arm <target_pane> <prompt> — run as the hub (TMUX_PANE is the hub's pane, %1,
# not the target's) to record that a prompt was dispatched to the target pane.
arm() {
  printf '%s' "$2" | TMUX=fake TMUX_PANE=%1 "$SCRIPT" arm "$1"
}

# stop <pane> <session_id> — feed a Stop payload (the end of a turn) for a pane.
stop() {
  local pane="$1" sid="$2"
  printf '{"session_id":"%s","cwd":"/tmp/proj","hook_event_name":"Stop"}' "$sid" \
    | TMUX=fake TMUX_PANE="$pane" "$SCRIPT" stop
}

# hold_lock <session_id> — take the session's lock in a background process and
# keep it until release_lock. Waits for the holder to acquire it, so a writer
# started afterwards finds it taken.
hold_lock() {
  mkfifo "$DIR/release"
  ( flock -x 9; read -r _ < "$DIR/release" ) 9>"$DIR/status-$1.lock" &
  HOLDER=$!
  sleep 0.2
}
release_lock() {
  echo > "$DIR/release"
  wait "$HOLDER"
}

# other_tool <pane> <session_id> <tool_name> — feed a PreToolUse payload for a
# tool that carries neither a `message` nor a question.
other_tool() {
  local pane="$1" sid="$2" tool="$3"
  printf '{"session_id":"%s","cwd":"/tmp/proj","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":"ls"}}' "$sid" "$tool" \
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
seed sess-1 "$SEED_WITH_NOTICE"
add %42 sess-1 "Claude needs your permission to use Bash"
assert_eq "$(items_of sess-1 '{summary, kinds: [.items[].kind]}')" \
  '{"summary":"working on X","kinds":["notice","blocking"]}' \
  "add into an existing status file keeps the summary and appends"
teardown

# ── add converts a pre-items file's decisions into notices ───────────────────
setup
seed sess-1 '{"summary":"s","decisions":[{"id":"d1","text":"old q","created_at":"2026-01-01T00:00:00Z"}]}'
add %42 sess-1 "Claude needs your permission to use Bash"
assert_eq "$(items_of sess-1 '{has_decisions: has("decisions"), kinds: [.items[].kind]}')" \
  '{"has_decisions":false,"kinds":["notice","blocking"]}' \
  "add migrates a pre-items file's decisions into notices"
teardown

# ── arm converts a pre-items file's decisions into notices ───────────────────
setup
start %50 sess-2
seed sess-2 '{"summary":"s","decisions":[{"id":"d1","text":"old q","created_at":"2026-01-01T00:00:00Z"}]}'
arm %50 "run the migration"
assert_eq "$(items_of sess-2 '{has_decisions: has("decisions"), kinds: [.items[].kind]}')" \
  '{"has_decisions":false,"kinds":["notice","notice"]}' \
  "arm migrates a pre-items file's decisions into notices"
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

# ── a payload with nothing to show records no blocking item ──────────────────
setup
other_tool %42 sess-1 Bash
assert_eq "$(items_of sess-1 '[.items[].kind]')" '[]' \
  "add records nothing when the payload has no text"
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

# ── a resolution with nothing to clear does not take the session lock ───────
setup
seed sess-1 "$SEED_WITH_NOTICE"
complete_tool sess-1 Bash
assert_eq "$([[ -e "$DIR/status-sess-1.lock" ]] && echo present || echo absent)" "absent" \
  "remove takes no lock when the session has no blocking item"
teardown

# ── a hook failure never reaches the session ─────────────────────────────────
setup
assert_eq "$(printf 'not json' | "$SCRIPT" add 2>/dev/null; echo "rc=$?")" "rc=0" \
  "a malformed payload exits 0 with nothing on stdout"
teardown

# ── a write waits for the session lock istatus.sh also takes ─────────────────
setup
hold_lock sess-1
add %42 sess-1 "Claude needs your permission to use Bash" &
adder=$!
sleep 0.3
assert_eq "$(items_of sess-1 '[.items[].kind]')" '[]' \
  "add waits while another writer holds the session lock"
release_lock
wait "$adder"
teardown

# ── a write gives up on a lock that stays held ───────────────────────────────
setup
export ISTATUS_LOCK_TIMEOUT=0.5
hold_lock sess-1
add %42 sess-1 "Claude needs your permission to use Bash" &
adder=$!
sleep 1.5
assert_eq "$(kill -0 "$adder" 2>/dev/null && echo running || echo exited)" "exited" \
  "add gives up once the lock wait times out"
release_lock
wait "$adder"
unset ISTATUS_LOCK_TIMEOUT
teardown

# ── a write that gives up on the lock drops its item ─────────────────────────
setup
export ISTATUS_LOCK_TIMEOUT=0.5
hold_lock sess-1
add %42 sess-1 "Claude needs your permission to use Bash" &
adder=$!
sleep 1.5
assert_eq "$(items_of sess-1 '[.items[].kind]')" '[]' \
  "add records nothing when the lock wait times out"
release_lock
wait "$adder"
unset ISTATUS_LOCK_TIMEOUT
teardown

# ── a new session announces which pane it occupies ──────────────────────────
setup
start %50 sess-2
assert_eq "$(pointer_of %50)" "sess-2" \
  "start writes the pane occupancy pointer"
teardown

# ── the hub dispatching a prompt is recorded on the target session ───────────
setup
start %50 sess-2
arm %50 "run the migration"
assert_eq "$(items_of sess-2 '{pane, items: [.items[] | {kind, state, priority, source, text}]}')" \
  '{"pane":"%50","items":[{"kind":"notice","state":"read","priority":"low","source":"hub.dispatched","text":"run the migration"}]}' \
  "arm records a dispatched notice on the target pane's session"
teardown

# ── a new dispatch supersedes earlier hub items and leaves the rest ──────────
setup
start %50 sess-2
seed sess-2 "$(jq -c '.items += [{"id":"r1","kind":"notice","text":"old task","source":"hub.ready","state":"unread","priority":"normal","created_at":"2026-10-05T00:00:00Z"}]' <<<"$SEED_WITH_NOTICE")"
arm %50 "new task"
assert_eq "$(items_of sess-2 '[.items[] | {source, text}]')" \
  '[{"source":null,"text":"pick a name"},{"source":"hub.dispatched","text":"new task"}]' \
  "arm supersedes earlier hub items and keeps other notices"
teardown

# ── a dispatched task finishing raises an unread ready notice ────────────────
setup
start %50 sess-2
arm %50 "run the migration"
stop %50 sess-2
assert_eq "$(items_of sess-2 '[.items[] | {source, state, priority, text}]')" \
  '[{"source":"hub.ready","state":"unread","priority":"normal","text":"run the migration"}]' \
  "stop turns a dispatched notice into an unread ready notice"
teardown

# ── a ready notice the human already deferred is not raised again ────────────
setup
seed sess-2 "$(jq -c '.items += [{"id":"r2","kind":"notice","text":"done task","source":"hub.ready","state":"read","priority":"normal","created_at":"2026-10-05T00:00:00Z"}]' <<<"$SEED_WITH_NOTICE")"
stop %50 sess-2
assert_eq "$(items_of sess-2 '[.items[] | {source, state}]')" \
  '[{"source":null,"state":"unread"},{"source":"hub.ready","state":"read"}]' \
  "stop does not re-raise a deferred ready notice"
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
