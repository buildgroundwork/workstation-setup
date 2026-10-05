#!/bin/bash
# istatus-hook — Claude Code hook entry point that records "blocking" items in
# a session's istatus file (see istatus.sh for the item model and file shape).
#
# Usage (wired as a hook command; payload is the hook JSON on stdin):
#   istatus-hook.sh add
#     Adds a "blocking" item, unread, to status/<session_id>.json. Its text is
#     the payload's `message` (a permission prompt) or, failing that, the first
#     question of an AskUserQuestion menu; `source` is the payload's tool_name
#     (empty for a permission prompt).
#
#   istatus-hook.sh remove
#     Clears blocking items the payload resolves; notices and the summary are
#     never touched. No tool_name (UserPromptSubmit, SessionEnd) clears every
#     blocking item. A tool_name clears the items that tool raised, plus
#     permission prompts unless the payload carries an agent_id: a subagent's
#     auto-approved tools finish while the parent's prompt is still pending.
#     A session with no status file is a silent no-op, since this fires on
#     every tool call and most sessions never block.
#
#   istatus-hook.sh start
#     Records which session occupies this pane (panes/<pane>.session_id) and
#     nothing else; it creates no status file. Wired on SessionStart.
#
#   istatus-hook.sh arm <target-pane>   (prompt on stdin; run by the hub)
#     Adds a read, low-priority "hub.dispatched" notice, whose text is the
#     prompt, to the session that occupies <target-pane>, and records
#     <target-pane> as the file's pane. Any earlier item whose source starts
#     with "hub." is removed first, so a re-dispatch supersedes the last one;
#     other notices and blocking items are untouched. The session is found through the
#     pane's occupancy pointer, so it is a silent no-op when there is none: a
#     session that was already running before start was wired may not have one
#     yet. Never reads TMUX_PANE, which here is the hub's pane.
#
#   istatus-hook.sh stop
#     Wired on Stop, in the dispatched session itself. Turns its
#     "hub.dispatched" notice into an unread, normal-priority "hub.ready" one
#     (same text, fresh created_at); does nothing if there is no such notice.
#     Stop does not fire when a turn is interrupted with Esc, so an
#     interrupted dispatch stays a read "hub.dispatched" notice until the next
#     arm replaces it. A ready notice the human deferred (read) is left alone.

set -euo pipefail

# A hook must never break or pollute the session it runs in. A non-zero exit
# surfaces as a hook error (and exit 2 can block the action), and stdout on
# exit 0 is injected into Claude's context for some events, so: send stdout
# nowhere and force exit 0 on the way out. The work above still fails fast
# under set -e; at worst a failure costs a missed item. stderr stays for
# anyone running the script by hand.
exec >/dev/null
trap 'exit 0' EXIT

ATTENTION_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}"
STATUS_DIR="$ATTENTION_DIR/status"
PANES_DIR="$ATTENTION_DIR/panes"

die() { printf 'istatus-hook: %s\n' "$*" >&2; exit 1; }

cmd_add() {
  local text source
  read_payload
  text=$(jq -r '.message // .tool_input.questions[0].question // empty' <<<"$PAYLOAD")
  source=$(jq -r '.tool_name // empty' <<<"$PAYLOAD")

  mkdir -p "$STATUS_DIR"
  LOCK_FILE="$ATTENTION_DIR/status-${SESSION_ID}.lock"
  with_lock record_blocking_item "$SESSION_ID" "$text" "$source"
}

cmd_remove() {
  local tool agent status_file
  read_payload
  tool=$(jq -r '.tool_name // empty' <<<"$PAYLOAD")
  agent=$(jq -r '.agent_id // empty' <<<"$PAYLOAD")

  # Checked before taking the lock so a session that never blocks, which is
  # most of them, doesn't get a lock file created on every tool call.
  status_file="$STATUS_DIR/${SESSION_ID}.json"
  [[ -f "$status_file" ]] || return 0
  LOCK_FILE="$ATTENTION_DIR/status-${SESSION_ID}.lock"
  with_lock clear_resolved_items "$status_file" "$tool" "$agent"
}

cmd_start() {
  read_payload
  record_pane_occupant "$SESSION_ID"
}

cmd_stop() {
  local status_file
  read_payload

  # Stop fires at the end of every turn in every session, so both checks run
  # before taking the lock: no status file, or no dispatched item in it, means
  # there is nothing to do. Writers replace the file atomically, so an unlocked
  # read sees a whole file; at worst it misses an arm that lands right after.
  status_file="$STATUS_DIR/${SESSION_ID}.json"
  [[ -f "$status_file" ]] || return 0
  has_dispatched_item "$status_file" || return 0
  LOCK_FILE="$ATTENTION_DIR/status-${SESSION_ID}.lock"
  with_lock raise_ready_notice "$status_file"
}

# Run by the hub, not by the target session, so TMUX_PANE here is the hub's
# pane and must never be read: the target is the argument.
cmd_arm() {
  local target="$1" prompt pointer sid
  prompt=$(cat)
  pointer="$PANES_DIR/${target}.session_id"
  [[ -n "$target" && -n "$prompt" && -f "$pointer" ]] || return 0
  sid=$(<"$pointer")
  [[ -n "$sid" ]] || return 0

  mkdir -p "$STATUS_DIR"
  LOCK_FILE="$ATTENTION_DIR/status-${sid}.lock"
  with_lock record_dispatch "$sid" "$target" "$prompt"
}

# Reads the hook payload from stdin into PAYLOAD and its session_id into
# SESSION_ID. Globals rather than a subshell capture, so a missing session_id
# can die the whole invocation.
read_payload() {
  PAYLOAD=$(cat)
  SESSION_ID=$(jq -r '.session_id // empty' <<<"$PAYLOAD")
  [[ -n "$SESSION_ID" ]] || die "no session_id in payload"
}

# The read-modify-write for add. Runs under the session lock.
record_blocking_item() {
  local sid="$1" text="$2" source="$3" status_file id
  status_file="$STATUS_DIR/${sid}.json"
  id=$(date -u +%Y%m%dT%H%M%SZ)-$$
  [[ -f "$status_file" ]] || printf '{"summary":"","items":[]}' > "$status_file"
  rewrite_status "$status_file" \
    --arg id "$id" --arg text "$text" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pane "${TMUX_PANE:-}" --arg source "$source" '
    .pane = $pane
    | .items += [ { id: $id, kind: "blocking", text: $text, source: $source, state: "unread", created_at: $ts } ]
  '

  record_pane_occupant "$sid"
}

# The read-modify-write for arm. Runs under the session lock.
record_dispatch() {
  local sid="$1" pane="$2" prompt="$3" status_file id
  status_file="$STATUS_DIR/${sid}.json"
  id=$(date -u +%Y%m%dT%H%M%SZ)-$$
  [[ -f "$status_file" ]] || printf '{"summary":"","items":[]}' > "$status_file"
  rewrite_status "$status_file" \
    --arg id "$id" --arg text "$prompt" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pane "$pane" '
    .pane = $pane
    | .items |= map(select((.source // "") | startswith("hub.") | not))
    | .items += [ { id: $id, kind: "notice", text: $text, source: "hub.dispatched",
                    state: "read", priority: "low", created_at: $ts } ]
  '
}

has_dispatched_item() {
  jq -e '[.items[] | select(.source == "hub.dispatched")] | length > 0' "$1" >/dev/null 2>&1
}

# The read-modify-write for stop. Runs under the session lock. Phase lives in
# `source`, not in read/unread: a ready notice the human deferred is read but
# is not dispatched, so it must not be raised again on the next Stop.
raise_ready_notice() {
  rewrite_status "$1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .items |= map(
      if .source == "hub.dispatched"
      then .source = "hub.ready" | .state = "unread" | .priority = "normal" | .created_at = $ts
      else . end)
  '
}

# The read-modify-write for remove. Runs under the session lock.
clear_resolved_items() {
  local status_file="$1" tool="$2" agent="$3"
  rewrite_status "$status_file" --arg tool "$tool" --arg agent "$agent" '
    # Does this resolution payload resolve this item? A payload with no tool
    # resolves every blocking item. A tool-bearing one resolves the items it
    # raised, plus permission prompts (empty source) unless it came from a
    # subagent, whose auto-approved tools finish while the parent still waits.
    def resolves($tool; $agent):
      .kind == "blocking"
      and ($tool == ""
           or (if (.source // "") == "" then $agent == "" else .source == $tool end));
    .items = [ .items[] | select(resolves($tool; $agent) | not) ]
  '
}

# Same lock istatus.sh takes (status-<sid>.lock in the attention dir; flock when
# available, a mkdir-based spinlock otherwise), so a hook write can't race an
# istatus call, or another hook, in the same session and lose an item. Copied
# from istatus.sh; the mkdir fallback is untested here.
with_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -x 9
    "$@"
  else
    local lock="$LOCK_FILE.d"
    local tries=50
    while ! mkdir "$lock" 2>/dev/null; do
      tries=$((tries - 1))
      [[ $tries -le 0 ]] && { rm -rf "$lock"; mkdir "$lock"; break; }
      sleep 0.05
    done
    local status=0
    "$@" || status=$?
    rmdir "$lock" 2>/dev/null || true
    return "$status"
  fi
}

# rewrite_status <status_file> <jq args...> — apply a jq program to the status
# file atomically (mktemp + mv), leaving the file untouched if jq fails.
rewrite_status() {
  local status_file="$1" tmp
  shift
  tmp=$(mktemp "${status_file}.XXXXXX")
  jq "$@" "$status_file" > "$tmp" || { rm -f "$tmp"; die "failed to update $status_file"; }
  mv "$tmp" "$status_file"
}

# Records "this pane currently holds this session_id" so a consumer can trust
# the status file only while the pointer still names its session. Same pointer
# istatus.sh writes; the hook writes it too because a session can block before
# it ever calls istatus.
record_pane_occupant() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  local pane_tmp
  mkdir -p "$PANES_DIR"
  pane_tmp=$(mktemp "${PANES_DIR}/.XXXXXX")
  printf '%s' "$1" > "$pane_tmp"
  mv "$pane_tmp" "${PANES_DIR}/${TMUX_PANE}.session_id"
}

case "${1:-}" in
  add)    cmd_add ;;
  remove) cmd_remove ;;
  start)  cmd_start ;;
  arm)    cmd_arm "${2:-}" ;;
  stop)   cmd_stop ;;
  *)      die "usage: istatus-hook.sh add|remove|start|arm <pane>|stop" ;;
esac
