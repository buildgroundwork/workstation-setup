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
  jq --arg id "$id" --arg text "$message" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .items += [ { id: $id, kind: "blocking", text: $text, state: "unread", created_at: $ts } ]
  ' "$status_file" > "$tmp" || { rm -f "$tmp"; die "failed to record item"; }
  mv "$tmp" "$status_file"
}

case "${1:-}" in
  add) cmd_add ;;
  *)   die "usage: istatus-hook.sh add" ;;
esac
