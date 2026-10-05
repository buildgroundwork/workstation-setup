#!/bin/bash
# istatus-toggle — toggle a pane's istatus sidebar: attach one if the window
# doesn't have one, kill it if it does. Mirrors hub-status-pane.sh's toggle
# semantics so the two keybindings (dashboard vs. sidebar) behave the same.
#
# Usage: istatus-toggle.sh [target-pane-id]
#   No argument: toggles the sidebar for the CURRENT pane.
#   With an argument: toggles the sidebar paired with that specific pane id.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ATTACH_SCRIPT="$SCRIPT_DIR/istatus-attach.sh"

die() { printf 'istatus-toggle: %s\n' "$*" >&2; exit 1; }

if [[ $# -eq 0 ]]; then
  [[ -n "${TMUX_PANE:-}" ]] || die "no pane id given and not running inside tmux"
  TARGET_PANE="$TMUX_PANE"
else
  TARGET_PANE="$1"
fi

tmux display-message -t "$TARGET_PANE" -p '#{pane_id}' >/dev/null 2>&1 \
  || die "pane $TARGET_PANE does not exist"

WINDOW=$(tmux display-message -t "$TARGET_PANE" -p '#{window_id}')

existing=$(tmux list-panes -t "$WINDOW" -F '#{pane_id} #{pane_start_command}' 2>/dev/null \
  | grep -F "istatus-sidebar.sh \"$TARGET_PANE\"" || true)

if [[ -n "$existing" ]]; then
  SIDEBAR_PANE="${existing%% *}"
  tmux kill-pane -t "$SIDEBAR_PANE"
  printf 'istatus-toggle: sidebar closed for pane %s\n' "$TARGET_PANE"
else
  "$ATTACH_SCRIPT" "$TARGET_PANE"
fi
