#!/bin/bash
# istatus-resolve-pane — given a tmux pane id, print the session_id of the
# Claude Code session currently occupying it.
#
# Why this exists: a sidebar pane is paired with a specific tmux pane, not a
# specific Claude session — a `/resume` of a different session UUID into the
# same pane keeps the same inter-session bus name but swaps the actual
# session_id, so the sidebar must re-resolve "who's in this pane right now"
# on every render rather than caching it once.
#
# Method: the attention-plugin debug log (CLAUDE_TMUX_ATTENTION_DEBUG=1)
# pairs TMUX_PANE with session_id on every hook event. The most recent entry
# for the target pane is that pane's current occupant. Scanned from the end
# of the file (tail, not grep-from-start) since the log is large (10MB+) and
# only ever grows — the newest matching entry is always near the end.
#
# Usage: istatus-resolve-pane.sh <tmux-pane-id>   (e.g. %83)
# Prints the session_id to stdout, or nothing + exit 1 if unresolved.

set -euo pipefail

DEBUG_LOG="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/debug.log"
TARGET_PANE="${1:?usage: istatus-resolve-pane.sh <tmux-pane-id>}"

[[ -f "$DEBUG_LOG" ]] || exit 1

# The log alternates a PAYLOAD line (has session_id, no TMUX_PANE) with the
# TMUX_PANE line directly after it. Scan backward in chunks of recent lines
# until a TMUX_PANE line for the target pane is found, then look one line up
# for the session_id. Bounded tail size keeps this fast even on a huge log.
tail -n 4000 "$DEBUG_LOG" | awk -v target="TMUX_PANE: $TARGET_PANE" '
  /^PAYLOAD: /  { payload = $0 }
  $0 == target  { match_line = payload }
  END {
    if (match_line != "") {
      print match_line
    }
  }
' | grep -o '"session_id":"[^"]*"' | tail -1 | cut -d'"' -f4
