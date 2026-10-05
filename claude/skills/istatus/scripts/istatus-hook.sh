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

set -euo pipefail

STATUS_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/status"
PANES_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/panes"

die() { printf 'istatus-hook: %s\n' "$*" >&2; exit 1; }

cmd_add() {
  local payload sid text source id status_file
  payload=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$payload")
  [[ -n "$sid" ]] || die "no session_id in payload"
  text=$(jq -r '.message // .tool_input.questions[0].question // empty' <<<"$payload")
  source=$(jq -r '.tool_name // empty' <<<"$payload")

  mkdir -p "$STATUS_DIR"
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

cmd_remove() {
  local payload sid tool agent status_file
  payload=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$payload")
  [[ -n "$sid" ]] || die "no session_id in payload"
  tool=$(jq -r '.tool_name // empty' <<<"$payload")
  agent=$(jq -r '.agent_id // empty' <<<"$payload")

  status_file="$STATUS_DIR/${sid}.json"
  [[ -f "$status_file" ]] || return 0
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
  *)      die "usage: istatus-hook.sh add|remove" ;;
esac
