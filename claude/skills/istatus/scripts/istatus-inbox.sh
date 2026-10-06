#!/bin/bash
# istatus-inbox — the one reader the status line, the popup and the hub
# scripts share. It turns the per-session status files (see istatus.sh for
# their shape) into a list of the sessions that are still live, so the
# liveness rule and the labels are derived in one place.
#
# Usage:
#   istatus-inbox.sh list
#     Prints a JSON array, one row per live session:
#       { session_id, pane, tmux_session, tmux_window, summary, items, state,
#         reason }
#     items is always a list of objects, whatever the file held. state is the
#     highest of: "blocked" (a blocking item), "flagged" (an unread notice
#     that is not from the hub, i.e. a decide), "ready" (an unread
#     hub.ready), "dispatched" (a hub.dispatched), else "". reason is the text
#     of the item behind the state (for "flagged", the newest unread decide
#     notice), or "" when there is no state.
#     A session is live while its file's pane is a live tmux pane AND the
#     pane's occupancy pointer (panes/<pane>.session_id) still names it, so
#     a pane taken over by another session, as after /resume, drops the old
#     session's file.
#     session_id comes from the file name; the file has no such field.
#     tmux_window is a string, as tmux prints it. With no status files it
#     prints [] and exits 0.
#
# Live panes come from ONE `tmux list-panes -a` call, tab-separated because a
# session name can contain spaces. For tests only, ISTATUS_TMUX_PANES holds
# those lines and is used in place of tmux, so liveness stays under test. When
# it is set but empty there are no live panes; it never falls back to tmux.

set -euo pipefail

ATTENTION_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}"
STATUS_DIR="$ATTENTION_DIR/status"
PANES_DIR="$ATTENTION_DIR/panes"

cmd_list() {
  local files panes occupants rows
  files=("$STATUS_DIR"/*.json)
  [[ -e "${files[0]}" ]] || { echo '[]'; return 0; }
  panes=$(live_panes)
  occupants=$(pane_occupants "$panes")

  # The fast path is one pass over every file. If a file is malformed that
  # pass fails whole, so retry once over just the files that parse: healthy
  # runs pay nothing, and one bad file can't hide every other session.
  rows=$(live_sessions "$panes" "$occupants" "${files[@]}" 2>/dev/null) || {
    local parsable=() file
    while IFS= read -r file; do parsable+=("$file"); done < <(parsable_files "${files[@]}")
    [[ ${#parsable[@]} -gt 0 ]] || { echo '[]'; return 0; }
    rows=$(live_sessions "$panes" "$occupants" "${parsable[@]}")
  }
  printf '%s\n' "$rows"
}

# live_sessions <live panes> <occupants> <status files...> — one jq pass over
# the files, with the listing and the pane occupants passed in, rather than a
# fork per file: the status line calls this every few seconds. A file counts
# only while its pane's pointer still names it.
live_sessions() {
  local panes="$1" occupants="$2"
  shift 2
  jq -n -c --arg panes "$panes" --arg occupants "$occupants" '
    # The items of a file that may be odd: a non-list counts as none, and
    # entries that are not objects are dropped, so one odd file cannot abort
    # the pass for every session.
    def items_of:
      if (.items | type) == "array" then [.items[] | select(type == "object")]
      else [] end;
    def from_hub: (.source | type) == "string" and (.source | startswith("hub."));
    # The items behind each state, so the state and its reason are derived from
    # the same predicates and cannot drift apart.
    def blocking_items: [.[] | select(.kind == "blocking")];
    def decide_items: [.[] | select(.kind == "notice" and .state == "unread" and (from_hub | not))];
    def ready_items: [.[] | select(.source == "hub.ready" and .state == "unread")];
    def dispatched_items: [.[] | select(.source == "hub.dispatched")];
    # The one label a consumer shows for a list of items, highest first:
    # blocked (a blocking item), flagged (an unread decide notice, meaning one
    # that is not from the hub), ready (an unread finished dispatch), dispatched
    # (a dispatch still running), else empty.
    def state_of:
      if (blocking_items | length) > 0 then "blocked"
      elif (decide_items | length) > 0 then "flagged"
      elif (ready_items | length) > 0 then "ready"
      elif (dispatched_items | length) > 0 then "dispatched"
      else "" end;
    # Why the session is in its state: the text of the item that put it there.
    # For flagged that is the newest unread decide notice. Empty when there is
    # no state.
    def reason_of:
      (if (blocking_items | length) > 0 then blocking_items[0]
       elif (decide_items | length) > 0 then (decide_items | sort_by(.created_at) | last)
       elif (ready_items | length) > 0 then ready_items[0]
       elif (dispatched_items | length) > 0 then dispatched_items[0]
       else null end)
      | (.text // "") | tostring;
    ($panes | split("\n")
            | map(select(length > 0) | split("\t") | { key: .[0], value: { session: .[1], window: .[2] } })
            | from_entries) as $live
    | ($occupants | split("\n")
                  | map(select(length > 0) | split("\t") | { key: .[0], value: .[1] })
                  | from_entries) as $occupant
    | [ inputs
        | (input_filename | split("/") | last | rtrimstr(".json")) as $sid
        | select(type == "object" and (.pane | type) == "string" and $live[.pane] != null and $occupant[.pane] == $sid)
        | { session_id: $sid,
            pane,
            tmux_session: $live[.pane].session,
            tmux_window: $live[.pane].window,
            summary,
            items: items_of,
            state: (items_of | state_of),
            reason: (items_of | reason_of) } ]
  ' "$@"
}

# The files among the arguments that parse as JSON, one per line. A malformed
# one is named on stderr and skipped.
parsable_files() {
  local file
  for file in "$@"; do
    if jq empty "$file" 2>/dev/null; then
      printf '%s\n' "$file"
    else
      echo "istatus-inbox: skipping malformed status file $file" >&2
    fi
  done
}

# The live panes, one "pane<TAB>session<TAB>window" line each. A tmux failure
# (no server running) means no live panes.
live_panes() {
  if [[ -n "${ISTATUS_TMUX_PANES+x}" ]]; then
    printf '%s\n' "$ISTATUS_TMUX_PANES"
  else
    tmux list-panes -a -F $'#{pane_id}\t#{session_name}\t#{window_index}' 2>/dev/null || true
  fi
}

# Who holds each live pane, one "pane<TAB>session_id" line per live pane that
# has an occupancy pointer. There are far fewer live panes than status files.
# $1 is the live-pane listing.
pane_occupants() {
  local pane pointer
  while IFS=$'\t' read -r pane _; do
    pointer="$PANES_DIR/${pane}.session_id"
    if [[ -n "$pane" && -f "$pointer" ]]; then
      printf '%s\t%s\n' "$pane" "$(<"$pointer")"
    fi
  done <<<"$1"
}

case "${1:-}" in
  list) cmd_list ;;
  *)    echo "usage: istatus-inbox.sh list" >&2; exit 1 ;;
esac
