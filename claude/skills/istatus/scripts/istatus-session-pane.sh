#!/bin/bash
# istatus-session-pane — the tmux pane that shows a background session.
#
# A `claude --bg` session runs under the background daemon, so its TMUX_PANE is
# whatever the daemon had when it started, not the pane the session is shown
# in. The pane runs `claude attach <session id>` instead, so the pane is the one
# whose process tree holds a claude attach naming the session.
#
# Usage: istatus-session-pane.sh <session_id>
#   Prints the pane id and exits 0. Exits 1, printing nothing, when no live pane
#   shows the session (a session that does not run in the background, say), so
#   the caller falls back to TMUX_PANE. The attach names the session by an id
#   prefix of eight or more characters.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: istatus-session-pane.sh <session_id>" >&2
  exit 2
fi
sid="$1"

panes=$(tmux list-panes -a -F $'#{pane_id}\t#{pane_pid}' 2>/dev/null) || exit 1
[[ -n "$panes" ]] || exit 1

# The panes' lines come first, then ps's pid, ppid, and command.
pane=$({ printf '%s\n' "$panes"; ps -axo pid=,ppid=,args= 2>/dev/null || true; } | awk -v sid="$sid" '
  NF == 2 && index($0, "\t") { pane_of[$2] = $1; next }
  { parent[$1] = $2
    for (i = 3; i < NF; i++)
      if ($i ~ /(^|\/)claude$/ && $(i + 1) == "attach" && length($(i + 2)) >= 8 \
          && index(sid, $(i + 2)) == 1) { attach[$1] = 1; break } }
  END {
    for (p in attach) {
      for (n = 0; n < 20 && p != "" && p != 0; n++) {
        if (p in pane_of) { print pane_of[p]; exit }
        p = parent[p]
      }
    }
  }')

[[ -n "$pane" ]] || exit 1
echo "$pane"
