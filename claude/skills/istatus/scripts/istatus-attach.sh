#!/bin/bash
# istatus-attach — add a live istatus sidebar split to a tmux window's
# existing Claude pane. Safe to run on an already-running session (this is
# the retrofit path) or from a launch script right after starting a new one.
#
# Usage: istatus-attach.sh [target-pane-id]
#   No argument: attaches a sidebar to the CURRENT pane (run this from
#   inside the Claude pane you want a sidebar next to).
#   With an argument: attaches a sidebar paired with that specific pane id
#   (e.g. for retrofitting many sessions from one driver script).
#
# Splits the target pane's window with a new pane to the right (25% width —
# wide enough for a decision line to be readable, narrow enough to leave
# the main pane usable), running istatus-sidebar.sh paired with the target.
# Refuses to attach a second sidebar to a window that already has one.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SIDEBAR_SCRIPT="$SCRIPT_DIR/istatus-sidebar.sh"

die() { printf 'istatus-attach: %s\n' "$*" >&2; exit 1; }

if [[ $# -eq 0 ]]; then
  [[ -n "${TMUX_PANE:-}" ]] || die "no pane id given and not running inside tmux"
  TARGET_PANE="$TMUX_PANE"
else
  TARGET_PANE="$1"
fi

tmux display-message -t "$TARGET_PANE" -p '#{pane_id}' >/dev/null 2>&1 \
  || die "pane $TARGET_PANE does not exist"

WINDOW=$(tmux display-message -t "$TARGET_PANE" -p '#{window_id}')

# Refuse a duplicate: a window already running istatus-sidebar.sh for this
# exact pane means a sidebar is already attached.
existing=$(tmux list-panes -t "$WINDOW" -F '#{pane_id} #{pane_start_command}' 2>/dev/null \
  | grep -F "istatus-sidebar.sh \"$TARGET_PANE\"" || true)
if [[ -n "$existing" ]]; then
  die "window $WINDOW already has a sidebar for pane $TARGET_PANE"
fi

tmux split-window -t "$TARGET_PANE" -h -l 25% \
  "$SIDEBAR_SCRIPT" "$TARGET_PANE"

printf 'istatus-attach: sidebar attached to window %s, paired with pane %s\n' "$WINDOW" "$TARGET_PANE"
