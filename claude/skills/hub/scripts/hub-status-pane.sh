#!/bin/bash
# hub-status-pane.sh — open (or close) the live hub-status dashboard in a small
# pinned pane at the bottom of the current tmux window.
#
#   hub-status-pane.sh open [HEIGHT] [INTERVAL]   split a HEIGHT-line pane (default 6)
#                                                 running hub-status --loop=INTERVAL (5)
#   hub-status-pane.sh close                       kill the dashboard pane
#   hub-status-pane.sh toggle                      open if absent, close if present
#
# The dashboard pane is tagged with a pane title ("hub-status") so we can find
# and close it without tracking pane ids. Must be run inside tmux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS="$SCRIPT_DIR/hub-status.sh"
TAG="hub-status"

err() { printf '%s\n' "$*" >&2; exit 1; }
[[ -n "${TMUX:-}" ]] || err "not inside tmux; run this from a tmux session"

# Print the pane id of the dashboard pane in the current window, if any.
find_pane() {
  tmux list-panes -F '#{pane_id} #{pane_title}' \
    | awk -v t="$TAG" '$2==t{print $1; exit}'
}

cmd_open() {
  local height="${1:-6}" interval="${2:-5}"
  local existing; existing=$(find_pane)
  [[ -n "$existing" ]] && { printf 'dashboard already open (%s)\n' "$existing"; return 0; }

  # Split a small pane below, tag it, and run the loop there. -d keeps focus in
  # the working pane so the dashboard doesn't steal the cursor.
  local pane
  pane=$(tmux split-window -v -l "$height" -d -P -F '#{pane_id}' \
    "exec '$STATUS' --loop=$interval")
  tmux select-pane -t "$pane" -T "$TAG"
  printf 'dashboard opened in %s (%s lines, %ss refresh)\n' "$pane" "$height" "$interval"
}

cmd_close() {
  local pane; pane=$(find_pane)
  [[ -z "$pane" ]] && { echo "no dashboard pane in this window"; return 0; }
  tmux kill-pane -t "$pane"
  echo "dashboard closed"
}

cmd_toggle() {
  if [[ -n "$(find_pane)" ]]; then cmd_close; else cmd_open "$@"; fi
}

main() {
  local sub="${1:-open}"; shift || true
  case "$sub" in
    open)   cmd_open "$@" ;;
    close)  cmd_close ;;
    toggle) cmd_toggle "$@" ;;
    *) err "usage: $0 {open [height] [interval] | close | toggle}" ;;
  esac
}

main "$@"
