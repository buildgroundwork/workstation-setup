#!/bin/bash
# istatus-sidebar — live-render a paired pane's current istatus state
# (open decisions + work summary) into this pane, refreshing on change.
#
# Intended to run in its own tmux split, paired with one Claude pane. Usage:
#   istatus-sidebar.sh <paired-tmux-pane-id>   (e.g. %83)
#
# Re-resolves which Claude session_id currently occupies the paired pane on
# every render (not just once at startup) — a /resume into that pane swaps
# the session_id while keeping the same bus name, so caching the mapping
# would silently show a stale session's state after a resume.

set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
RESOLVE_PANE="$SCRIPT_DIR/istatus-resolve-pane.sh"
# The state directory keeps the name of the old claude-tmux-attention plugin.
STATUS_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/status"

PAIRED_PANE="${1:?usage: istatus-sidebar.sh <paired-tmux-pane-id>}"

render() {
  clear
  local session_id
  session_id=$("$RESOLVE_PANE" "$PAIRED_PANE" 2>/dev/null) || session_id=""

  printf '\033[1m istatus — %s \033[0m\n' "$PAIRED_PANE"
  printf '%s\n' "────────────────────────────────────────"

  if [[ -z "$session_id" ]]; then
    printf ' (no session resolved for this pane yet)\n'
    return
  fi

  local status_file="$STATUS_DIR/${session_id}.json"
  if [[ ! -f "$status_file" ]]; then
    printf ' (no istatus state for this session yet)\n'
    return
  fi

  local summary
  summary=$(jq -r '.summary' "$status_file" 2>/dev/null)
  if [[ -n "$summary" && "$summary" != "null" ]]; then
    printf '\033[1mWorking on:\033[0m\n %s\n\n' "$summary"
  fi

  local item_count
  item_count=$(jq '.items | length' "$status_file" 2>/dev/null) || item_count=0

  if [[ "$item_count" -eq 0 ]]; then
    printf '\033[2m(nothing open)\033[0m\n'
    return
  fi

  # Same order istatus resolve's ordinals use: blocking first, then notices by
  # priority, then oldest first. Read notices are dimmed; they stay listed
  # until resolved.
  printf '\033[1mOpen (%s):\033[0m\n' "$item_count"
  jq -r '
    .items
    | sort_by(
        (if .kind == "blocking" then 0 else 1 end),
        (if .kind == "notice" then
           (if .priority == "high" then 0 elif .priority == "low" then 2 else 1 end)
         else 0 end),
        .created_at)
    | to_entries[]
    | .key as $i | .value
    | (if .kind == "blocking" then "\u001b[31mblocked\u001b[0m"
       elif .state == "read" then "\u001b[2mread\u001b[0m"
       else "\u001b[35munread\u001b[0m" end) as $tag
    | "  [\($i + 1)] \($tag)  " + .text + "\n"
  ' "$status_file" 2>/dev/null
}

render

# fswatch on the status dir catches both file-content changes and a session
# switch creating/touching a different status file; the pane-resolution
# itself is re-run on every event rather than cached, so a /resume is
# picked up even though fswatch is only watching file changes, not pane
# occupancy.
fswatch -o "$STATUS_DIR" 2>/dev/null | while read -r _; do
  render
done
