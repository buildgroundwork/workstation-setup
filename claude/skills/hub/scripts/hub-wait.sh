#!/bin/bash
# hub-wait.sh — block until a dispatched pane finishes (flips to task.ready),
# then print its result. The babysitting primitive for the dispatch
# orchestrator: it does the dumb "has it finished yet?" polling in a cheap
# shell loop so the hub's Claude context isn't spent waiting.
#
#   hub-wait.sh <target> [timeout_seconds]
#       <target>  "<session>:<window>" of a pane previously armed by `send`.
#       timeout   max seconds to wait. Default 0 = no timeout (wait until the
#                 pane finishes or blocks). The two outcomes that matter return
#                 promptly anyway — finished (0) and blocked-on-a-prompt (4) —
#                 and a dead pane errors at resolve, so the only thing a finite
#                 timeout guards against is a truly-hung session, which is rare
#                 and harmless (Adam sees it when he visits the window). Pass a
#                 positive value only if you want a hard deadline.
#
# Exit codes:
#   0  finished — pane reached task.ready; prints the settled pane contents.
#   2  timed out before finishing or blocking.
#   3  pane was never armed / not found in the state file.
#   4  BLOCKED — the dispatched session hit its own permission prompt (an
#      attention.needed row appeared for the pane). It can't proceed without
#      the user approving in that pane, so return early instead of waiting to
#      timeout, and print the pane so the user can see the ask.
#
# Polls the state file, not the pane's TUI — both signals (the Stop-hook
# task.ready flip and the plugin's attention.needed) are facts in the file, not
# screen-scraping. Designed to be backgrounded or run between hub turns.

set -euo pipefail

err() { printf '%s\n' "$*" >&2; exit 1; }

target="${1:?usage: hub-wait.sh <target> [timeout_seconds]}"
timeout="${2:-0}"   # 0 = no timeout; wait until finished or blocked
interval="${HUB_WAIT_INTERVAL:-3}"   # seconds between state-file checks

STATE_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}"
STATE_FILE="$STATE_DIR/pending.json"

# Resolve the target window's pane id — arm/ready key by pane.
pane=$(tmux display-message -t "$target" -p '#{pane_id}' 2>/dev/null) \
  || err "target not found: $target"
[[ -n "$pane" ]] || err "could not resolve pane for: $target"

# Classify this pane's state from the state file, by its rows (matched on
# tmux_pane). A blocked dispatch can carry BOTH a task.dispatched row and an
# attention.needed row, so check kinds explicitly rather than taking the last
# row. Prints: ready | blocked | dispatched | none.
#   - any task.ready row              -> "ready"     (finished)
#   - any attention.needed row        -> "blocked"   (hit a permission prompt)
#   - any task.dispatched row         -> "dispatched"(still working)
#   - otherwise                       -> "none"
pane_state() {
  [[ -f "$STATE_FILE" ]] || { echo none; return; }
  jq -r --arg p "$pane" '
    [ .[] | select(.tmux_pane == $p) | .kind ] as $kinds
    | if   ($kinds | index("task.ready"))       then "ready"
      elif ($kinds | index("attention.needed")) then "blocked"
      elif ($kinds | index("task.dispatched"))  then "dispatched"
      else "none" end
  ' "$STATE_FILE" 2>/dev/null
}

# Must be a live dispatch when we start (armed, ready, or already blocked) —
# otherwise there's nothing to wait on (wrong pane, or never armed).
case "$(pane_state)" in
  ready|dispatched|blocked) ;;
  *) printf 'pane %s (%s) is not an armed dispatch\n' "$pane" "$target" >&2; exit 3 ;;
esac

# Poll until the pane finishes (ready), blocks on its own prompt, or times out.
elapsed=0
while :; do
  case "$(pane_state)" in
    ready)
      # Finished. Session stopped, so the pane is settled — capture is clean.
      tmux capture-pane -t "$target" -p 2>/dev/null
      exit 0 ;;
    blocked)
      printf 'BLOCKED: %s is waiting on its own permission prompt — approve in that pane, then re-wait.\n' "$target" >&2
      tmux capture-pane -t "$target" -p 2>/dev/null
      exit 4 ;;
  esac
  (( timeout > 0 && elapsed >= timeout )) && {
    printf 'timed out after %ss waiting for %s\n' "$timeout" "$target" >&2
    exit 2
  }
  sleep "$interval"
  elapsed=$((elapsed + interval))
done
