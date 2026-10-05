#!/bin/bash
# istatus-hook — Claude Code hook entry point that records "blocking" items in
# a session's istatus file (see istatus.sh for the item model and file shape).
#
# Usage (wired as a hook command; payload is the hook JSON on stdin):
#   istatus-hook.sh add
#     Adds a "blocking" item, unread, whose text is the payload's `message`,
#     to status/<session_id>.json.

set -euo pipefail

STATUS_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/status"
PANES_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/panes"

die() { printf 'istatus-hook: %s\n' "$*" >&2; exit 1; }

cmd_add() {
  local payload sid message id tmp status_file
  payload=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$payload")
  [[ -n "$sid" ]] || die "no session_id in payload"
  message=$(jq -r '.message // empty' <<<"$payload")

  mkdir -p "$STATUS_DIR"
  status_file="$STATUS_DIR/${sid}.json"
  id=$(date -u +%Y%m%dT%H%M%SZ)-$$
  [[ -f "$status_file" ]] || printf '{"summary":"","items":[]}' > "$status_file"
  tmp=$(mktemp "${status_file}.XXXXXX")
  jq --arg id "$id" --arg text "$message" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg pane "${TMUX_PANE:-}" '
    .pane = $pane
    | .items += [ { id: $id, kind: "blocking", text: $text, state: "unread", created_at: $ts } ]
  ' "$status_file" > "$tmp" || { rm -f "$tmp"; die "failed to record item"; }
  mv "$tmp" "$status_file"

  record_pane_occupant "$sid"
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
  add) cmd_add ;;
  *)   die "usage: istatus-hook.sh add" ;;
esac
