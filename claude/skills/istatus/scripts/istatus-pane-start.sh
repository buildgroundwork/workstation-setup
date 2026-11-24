#!/bin/bash
# istatus-pane-start — when each tmux pane's process started, so a pane's
# occupancy pointer can be told from one left by an earlier pane.
#
# tmux hands out pane ids again after a restart, so panes/<pane>.session_id may
# date from a pane that no longer exists. A pointer is written by a session
# running in its pane, so a live pointer is never older than the pane. One
# older than the pane is stale and names nobody.
#
# Usage:
#   istatus-pane-start.sh starts [pane...]
#     Prints "pane<TAB>epoch" for each live pane (just the named ones when
#     given): the epoch second its process started, from the pane's pid and
#     `ps` elapsed time. A pane whose process can't be read is left out, so a
#     caller can't judge it and treats its pointer as current.
#   istatus-pane-start.sh stale <pane>
#     Exits 0 when the pane's pointer is older than the pane, 1 when it is
#     current or can't be judged (no pointer, or no start time for the pane).
#
# For tests only, ISTATUS_TMUX_PANES holds the live-pane lines
# (pane<TAB>session<TAB>window<TAB>start epoch) and is used in place of tmux
# and ps, as in istatus-inbox.sh. When it is set but empty there are no live
# panes.

set -euo pipefail

PANES_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/panes"
SLACK=2 # seconds: ps elapsed time has one-second resolution

# "pane<TAB>epoch" for every live pane that has a start time.
all_starts() {
  if [[ -n "${ISTATUS_TMUX_PANES+x}" ]]; then
    awk -F'\t' 'NF >= 4 && $4 != "" { print $1 "\t" $4 }' <<<"$ISTATUS_TMUX_PANES"
    return 0
  fi
  local pids
  pids=$(tmux list-panes -a -F $'#{pane_id}\t#{pane_pid}' 2>/dev/null) || return 0
  [[ -n "$pids" ]] || return 0
  # One ps call scans every process, and the awk keeps the panes' pids. Naming
  # the pids with -p is slower: ps took 1.5 to 2 s for a list of several, against
  # 0.06 s for the full scan. A pid that has gone is just absent from the scan.
  ps -axo pid=,etime= 2>/dev/null \
    | awk -v now="$(date +%s)" -F'\t' '
        NR == FNR { split($0, f, " "); elapsed[f[1]] = f[2]; next }
        { e = elapsed[$2]; if (e == "") next
          days = 0
          if (index(e, "-")) { split(e, d, "-"); days = d[1]; e = d[2] }
          n = split(e, t, ":"); secs = 0
          for (i = 1; i <= n; i++) secs = secs * 60 + t[i]
          print $1 "\t" now - (days * 86400 + secs) }
      ' - <(printf '%s\n' "$pids") || true
}

file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

case "${1:-}" in
  starts)
    shift
    if [[ $# -eq 0 ]]; then
      all_starts
    else
      all_starts | awk -F'\t' -v want=" $* " 'index(want, " " $1 " ") { print }'
    fi
    ;;
  stale)
    pane="${2:?usage: istatus-pane-start.sh stale <pane>}"
    pointer="$PANES_DIR/${pane}.session_id"
    [[ -f "$pointer" ]] || exit 1
    start=$(all_starts | awk -F'\t' -v p="$pane" '$1 == p { print $2 }')
    [[ -n "$start" ]] || exit 1
    (( $(file_mtime "$pointer") + SLACK < start ))
    ;;
  *)
    echo "usage: istatus-pane-start.sh starts [pane...] | stale <pane>" >&2
    exit 2
    ;;
esac
