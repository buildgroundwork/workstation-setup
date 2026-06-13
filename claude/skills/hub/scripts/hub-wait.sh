#!/bin/bash
# hub-wait.sh — block until a dispatched pane finishes (flips to task.ready),
# then print its result. The babysitting primitive for the dispatch
# orchestrator: it does the dumb "has it finished yet?" polling in a cheap
# shell loop so the hub's Claude context isn't spent waiting.
#
#   hub-wait.sh <target> [timeout_seconds]
#       <target>  "<session>:<window>" of a pane previously armed by `send`.
#       timeout   max seconds to wait (default 1800 = 30 min). 0 = no timeout.
#
# Exits 0 and prints the settled pane contents (a clean capture, since the
# session has stopped) when the pane reaches task.ready. Exits 2 on timeout,
# 3 if the pane was never armed / not found in the state file. Polls the state
# file, not the pane's TUI — the finish signal is the Stop-hook flip, not
# screen-scraping. Designed to be backgrounded or run between hub turns.

set -euo pipefail

err() { printf '%s\n' "$*" >&2; exit 1; }

target="${1:?usage: hub-wait.sh <target> [timeout_seconds]}"
timeout="${2:-1800}"
interval="${HUB_WAIT_INTERVAL:-3}"   # seconds between state-file checks

STATE_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}"
STATE_FILE="$STATE_DIR/pending.json"

# Resolve the target window's pane id — arm/ready key by pane.
pane=$(tmux display-message -t "$target" -p '#{pane_id}' 2>/dev/null) \
  || err "target not found: $target"
[[ -n "$pane" ]] || err "could not resolve pane for: $target"

# Read this pane's current kind from the state file. Empty if no row.
pane_kind() {
  [[ -f "$STATE_FILE" ]] || return 0
  jq -r --arg p "$pane" '
    (map(select(.tmux_pane == $p)) | last | .kind) // ""
  ' "$STATE_FILE" 2>/dev/null
}

# Must be armed (dispatched) or already ready when we start — otherwise there's
# nothing to wait on (the caller dispatched to the wrong pane, or never armed).
start_kind=$(pane_kind)
case "$start_kind" in
  task.ready) ;;                      # already done; fall through to capture
  task.dispatched) ;;                 # the normal case; wait for the flip
  *) printf 'pane %s (%s) is not an armed dispatch (kind=%s)\n' \
       "$pane" "$target" "${start_kind:-none}" >&2; exit 3 ;;
esac

# Poll until task.ready or timeout.
elapsed=0
while [[ "$(pane_kind)" != "task.ready" ]]; do
  (( timeout > 0 && elapsed >= timeout )) && {
    printf 'timed out after %ss waiting for %s to finish\n' "$timeout" "$target" >&2
    exit 2
  }
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

# Finished. The session has stopped, so the pane is settled — capture is clean.
tmux capture-pane -t "$target" -p 2>/dev/null
exit 0
