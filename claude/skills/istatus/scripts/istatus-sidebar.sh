#!/bin/bash
# istatus-sidebar — the live, interactive istatus view of a paired pane: its
# summary and its items, which j/k select and r/u/e mark read, mark unread and
# resolve. The sidebar itself is istatus_sidebar.py; see it for the keys.
#
# Intended to run in its own tmux split, paired with one Claude pane. Usage:
#   istatus-sidebar.sh <paired-tmux-pane-id>   (e.g. %83)
#
# This name is the entry point because istatus-attach.sh and
# istatus-toggle.sh find a window's sidebar by it in #{pane_start_command}.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
exec python3 "$SCRIPT_DIR/istatus_sidebar.py" "$@"
