#!/bin/bash
# hub-wait.sh — block until a dispatched pane finishes (its dispatched notice
# turns into a ready one), then print its result. The babysitting primitive
# for the dispatch orchestrator: it does the dumb "has it finished yet?"
# polling in a cheap shell loop so the hub's Claude context isn't spent
# waiting.
#
#   hub-wait.sh <target> [timeout_seconds]
#       <target>  "<session>:<window>" of a pane previously armed by `send`.
#       timeout   max seconds to wait. Default 0 = no timeout (wait until the
#                 pane finishes or blocks). The two outcomes that matter return
#                 promptly anyway — finished (0) and blocked-on-a-prompt (4) —
#                 and a dead pane errors at resolve, so the only thing a finite
#                 timeout guards against is a truly-hung session, which is rare
#                 and harmless (Adam sees it when he visits the window). Pass a
#                 positive value only if you want a hard deadline. One case
#                 still waits: a dispatch interrupted with Esc never gets a
#                 Stop, so it stays dispatched until you give up or re-arm it.
#
# Exit codes:
#   0  finished — the pane's dispatch is ready (the Stop hook turned its
#      notice into a ready one, whether or not anyone has looked at it since);
#      prints the settled pane contents.
#   2  timed out before finishing or blocking.
#   3  pane was never armed (exits on the first look), or stopped being an
#      armed dispatch while waiting (superseded by a newer dispatch, the pane
#      died, or a /resume moved it), seen on two polls in a row.
#   4  BLOCKED — the dispatched session hit its own permission prompt (a
#      blocking item appeared for the pane). It can't proceed without
#      the user approving in that pane, so return early instead of waiting to
#      timeout, and print the pane so the user can see the ask.
#
# Polls the istatus inbox, not the pane's TUI — both signals (the Stop-hook
# ready notice and the blocking item) are facts in the status file, not
# screen-scraping. Designed to be backgrounded or run between hub turns.

set -euo pipefail

err() { printf '%s\n' "$*" >&2; exit 1; }

target="${1:?usage: hub-wait.sh <target> [timeout_seconds]}"
timeout="${2:-0}"   # 0 = no timeout; wait until finished or blocked
interval="${HUB_WAIT_INTERVAL:-3}"   # seconds between state-file checks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISTATUS_SCRIPTS="$SCRIPT_DIR/../../istatus/scripts"

# Resolve the target window's pane id — arm/ready key by pane.
pane=$(tmux display-message -t "$target" -p '#{pane_id}' 2>/dev/null) \
  || err "target not found: $target"
[[ -n "$pane" ]] || err "could not resolve pane for: $target"

# Classify this pane's state from its inbox row's ITEMS, not the row's top
# state: a blocked dispatch carries both a dispatched notice and a blocking
# item, and a finished one can sit beside a decide. Prints: ready | blocked |
# dispatched | none.
#   - any hub.ready item, read or not -> "ready"     (finished). Read counts:
#     focusing the pane marks it read, and an unread-only check would then
#     never see the dispatch finish.
#   - any blocking item               -> "blocked"   (hit a permission prompt)
#   - any hub.dispatched item         -> "dispatched"(still working)
#   - otherwise                       -> "none", which includes a pane that is
#     no longer a live inbox row.
pane_state() {
  "$ISTATUS_SCRIPTS/istatus-inbox.sh" list 2>/dev/null | jq -r --arg p "$pane" '
    [ .[] | select(.pane == $p) | .items[] ] as $items
    | if any($items[]; .source == "hub.ready") then "ready"
      elif any($items[]; .kind == "blocking") then "blocked"
      elif any($items[]; .source == "hub.dispatched") then "dispatched"
      else "none" end
  ' 2>/dev/null
}

# Poll until the pane finishes (ready), blocks on its own prompt, stops being a
# dispatch, or times out. A pane that was never armed (wrong pane, or nothing
# dispatched) ends the same way on the first look as one that loses its
# dispatch later: exit 3.
#
# One empty read can be a transient (tmux busy, so the inbox sees no live
# panes), and exiting 3 would make the hub think the dispatch is gone and
# resend it. So after the first look, a pane has to read as no dispatch twice
# in a row before the wait gives up; a pane that is no dispatch on the very
# first look is the common wrong-target case and exits 3 at once.
elapsed=0
polls=0
misses=0
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
    none)
      # No dispatch: it was never armed, or it is gone (superseded by a newer
      # one, the pane died, or a /resume moved the pane to another session).
      # Nothing will ever finish it, so don't poll forever.
      misses=$((misses + 1))
      if (( polls == 0 || misses >= 2 )); then
        printf 'pane %s (%s) is not an armed dispatch\n' "$pane" "$target" >&2
        exit 3
      fi ;;
    *) misses=0 ;;
  esac
  (( timeout > 0 && elapsed >= timeout )) && {
    printf 'timed out after %ss waiting for %s\n' "$timeout" "$target" >&2
    exit 2
  }
  sleep "$interval"
  elapsed=$((elapsed + interval))
  polls=$((polls + 1))
done
