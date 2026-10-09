#!/bin/bash
# hub-status.sh — render a compact, live status panel for Adam's running
# Claude sessions.
#
#   hub-status.sh            print the panel once and exit
#   hub-status.sh --loop[=N] clear-and-redraw every N seconds (default 5) until
#                            killed; for an always-on dashboard pane
#
# Reconciles three sources per session:
#   1. hub-map.sh        — which tmuxinator projects are running + claude target
#   2. the transcript    — newest ~/.claude/projects/<slug>/*.jsonl for the
#                          project root: context size (sum of the last assistant
#                          message's cache_read + cache_creation + input tokens)
#                          and recency (file mtime)
#   3. the istatus inbox — istatus-inbox.sh list: which live sessions are
#                          blocked, flagged, ready or dispatched. The
#                          authoritative signal when the istatus hooks are
#                          installed. Degrades to a recency heuristic when
#                          nothing is recorded.
#
# State precedence: the inbox's state wins; else mtime heuristic.
# Cold sessions (transcript untouched > COLD_MIN) are folded into one count line.
#
# Pure read. No mutation of any session, the state file, or tmux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOW_TOKENS="${HUB_CONTEXT_WINDOW:-1000000}"      # opus 1m context
WORKING_MIN="${HUB_WORKING_MIN:-60}"                # transcript touched <= this (min) => working. Default 1h: "sessions I'm working on today", not "generating right now". Tune via HUB_WORKING_MIN.
COLD_MIN="${HUB_COLD_MIN:-1440}"                    # transcript untouched > this (min) => cold (24h)
MAX_LINES="${HUB_MAX_LINES:-12}"                    # pane never grows past this; working rows past the budget fold to "+N more working"
PROJECTS_DIR="$HOME/.claude/projects"
ISTATUS_SCRIPTS="$SCRIPT_DIR/../../istatus/scripts"

# cwd -> the project dir slug Claude uses (every non-alphanumeric becomes '-').
project_slug() { echo "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

# Newest transcript for a project root, or empty.
newest_transcript() {
  local dir="${1/#\~/$HOME}"
  ls -t "$PROJECTS_DIR/$(project_slug "$dir")"/*.jsonl 2>/dev/null | head -1
}

# Context tokens in use = last assistant message's cache_read + cache_creation
# + input. This is the live working-set size against the context window.
transcript_context() {
  local f="$1"
  grep '"role":"assistant"' "$f" 2>/dev/null | tail -1 \
    | jq -r '(.message.usage.cache_read_input_tokens//0)
             + (.message.usage.cache_creation_input_tokens//0)
             + (.message.usage.input_tokens//0)' 2>/dev/null
}

# A snapshot of the istatus state as "tmux session<TAB>label" lines (bash 3.2
# has no associative arrays — macOS ships 3.2). Empty if the inbox has nothing
# or fails. attn_kind() looks a tmux session up in it.
ATTN=""
load_attention() {
  # This dashboard wants a single label per tmux session. Each inbox row
  # already carries its session's top state; the rows are sorted here, most
  # urgent first (blocked, flagged, ready, dispatched), so a tmux session that
  # holds several Claude sessions gets the highest, because attn_kind takes the
  # first line for it. The labels are the dashboard's own vocabulary: a blocked
  # session is "waiting" here.
  ATTN=$("$ISTATUS_SCRIPTS/istatus-inbox.sh" list 2>/dev/null | jq -r '
    def dashboard_label: { blocked: "waiting", flagged: "flagged", ready: "ready", dispatched: "dispatched" }[.state];
    def urgency: { blocked: 0, flagged: 1, ready: 2, dispatched: 3 }[.state];
    [ .[] | select(.state != "" and .tmux_session != "") ]
    | sort_by(urgency)
    | .[]
    | "\(.tmux_session)\t\(dashboard_label)"
  ' 2>/dev/null || true)
}

# attn_kind <session-name> -> its label, or empty.
attn_kind() {
  [[ -n "$ATTN" ]] || return 0
  printf '%s\n' "$ATTN" | awk -F'\t' -v s="$1" '$1==s{print $2; exit}'
}

# state <session-name> <age-min> -> flagged|waiting|dispatched|ready|idle|cold|working
resolve_state() {
  local name="$1" age="$2" kind
  kind=$(attn_kind "$name")
  case "$kind" in
    flagged|waiting|dispatched|ready) echo "$kind"; return ;;
  esac
  if   (( age > COLD_MIN ));    then echo cold
  elif (( age <= WORKING_MIN ));then echo working
  else                              echo idle
  fi
}

icon() {
  case "$1" in
    flagged)    printf '✋' ;;   # an unread decide notice — a session is asking for you
    waiting)    printf '⏸' ;;   # a blocking item — blocked on a prompt
    working)    printf '●' ;;
    dispatched) printf '◐' ;;   # a hub dispatch still working
    ready)      printf '✓' ;;   # a hub dispatch that finished
    idle)       printf '○' ;;
    cold)       printf '◌' ;;
  esac
}

# A 10-cell context bar. Guards the zero-width case that tripped the prototype.
bar() {
  local pct="$1" width=10 full empty
  full=$(( pct * width / 100 ))
  (( full < 0 )) && full=0
  (( full > width )) && full=$width
  empty=$(( width - full ))
  local out=""
  (( full > 0 ))  && out+=$(printf '█%.0s' $(seq 1 "$full"))
  (( empty > 0 )) && out+=$(printf '░%.0s' $(seq 1 "$empty"))
  printf '%s' "$out"
}

# Render the panel once to stdout.
render() {
  local now; now=$(date +%s)
  load_attention

  # Build the per-session rows: name \t pct \t age \t state
  local rows
  rows=$(bash "$SCRIPT_DIR/hub-map.sh" \
    | jq -r '.[] | select(.running and .claude_target != "") | "\(.name)\t\(.root)"' \
    | while IFS=$'\t' read -r name root; do
        f=$(newest_transcript "$root")
        ctx=0; age=999999
        if [[ -f "$f" ]]; then
          ctx=$(transcript_context "$f"); ctx=${ctx:-0}
          age=$(( (now - $(stat -f %m "$f")) / 60 ))
        fi
        pct=$(( ctx * 100 / WINDOW_TOKENS ))
        state=$(resolve_state "$name" "$age")
        printf '%s\t%s\t%s\t%s\n' "$name" "$pct" "$age" "$state"
      done)

  local total clock
  total=$(printf '%s\n' "$rows" | awk 'NF{n++} END{print n+0}')
  clock=$(date '+%H:%M')

  # Build the idle and cold summary lines first — each is 0 or 1 line — so the
  # working rows know how much of the MAX_LINES budget is left for them.
  local idle coldn idle_line="" cold_line=""
  idle=$(printf '%s\n' "$rows" | awk -F'\t' '$4=="idle"{printf "%s · ",$1}' | sed 's/ · $//')
  [[ -n "$idle" ]] && idle_line=$(printf ' ○ idle: %s' "$idle")
  # Cold sessions fold to a bare count — the names are low-signal ("these exist,
  # ignore them") and a long name list wraps in a narrow pane, eating rows the
  # height calc doesn't account for. The count carries what matters.
  # Count with awk's own accumulator (print n+0) rather than `| grep -c .`:
  # grep -c exits 1 on a zero count, which under `set -e` aborts the whole
  # render — and it conflates "zero matches" with "grep failed," so it can't be
  # guarded cleanly. awk prints 0 for no matches AND exits 0, so a real pipe
  # failure still propagates while a legitimate zero count does not kill us.
  coldn=$(printf '%s\n' "$rows" | awk -F'\t' '$4=="cold"{n++} END{print n+0}')
  # NB: `(( expr )) &&` at statement level ABORTS under `set -e` when expr is
  # false (arithmetic-false returns exit 1). Use an `if` so a zero cold-count
  # (the common all-active case) doesn't kill the render — the bug that made the
  # dashboard silently fail to open whenever no session was cold.
  if (( coldn > 0 )); then cold_line=$(printf ' ◌ cold (%s)' "$coldn"); fi

  # Active rows (working/waiting/dispatched/ready), context-heavy first.
  local active
  active=$(printf '%s\n' "$rows" \
    | awk -F'\t' '$4!="idle" && $4!="cold"' \
    | sort -t$'\t' -k4,4 -k2,2rn \
    | while IFS=$'\t' read -r name pct age state; do
        # Truncate names past the 18-col field to a 17-char stem + ellipsis, so a
        # long session name (e.g. "ReBAC Relationship Writer") can't overflow the
        # column and shove the %/bar right, misaligning the row from the others.
        [[ ${#name} -gt 18 ]] && name="${name:0:17}…"
        printf ' %s %-18s %3s%% %s\n' "$(icon "$state")" "$name" "$pct" "$(bar "$pct")"
      done)
  # awk non-blank-line count, not `grep -c .` (see coldn note: grep -c exits 1 on
  # zero, aborting the render under set -e when there are no active rows).
  local active_n; active_n=$(printf '%s\n' "$active" | awk 'NF{n++} END{print n+0}')

  # Budget: MAX_LINES minus header(1) minus idle/cold lines = room for active
  # rows. If active rows overflow, show (budget - 1) and a "+N more working".
  local reserved=1
  [[ -n "$idle_line" ]] && reserved=$((reserved + 1))
  [[ -n "$cold_line" ]] && reserved=$((reserved + 1))
  local budget=$((MAX_LINES - reserved))
  if (( budget < 1 )); then budget=1; fi

  printf ' HUB · %s live · %s\n' "$total" "$clock"
  if (( active_n > budget )); then
    local shown=$((budget - 1))
    printf '%s\n' "$active" | head -n "$shown"
    printf ' … +%s more working\n' "$((active_n - shown))"
  else
    [[ -n "$active" ]] && printf '%s\n' "$active"
  fi
  # `if`, not `[[ -n ]] &&`: a false `&&` guard returns 1, and as the last
  # statement in render() that makes the function exit non-zero despite a
  # complete render — which a caller running this under `set -e` (the pane-open
  # height calc) treats as failure. An `if` with a false condition returns 0, so
  # an empty idle/cold line no longer poisons the exit status. Nothing absorbed:
  # a genuine failure on any line above still aborts under `set -e`.
  if [[ -n "$idle_line" ]]; then printf '%s\n' "$idle_line"; fi
  if [[ -n "$cold_line" ]]; then printf '%s\n' "$cold_line"; fi
}

# fit_pane <rows> — resize this dashboard's own pane to <rows>.
fit_pane() {
  tmux resize-pane -t "$TMUX_PANE" -y "$1" 2>/dev/null || true
}

# --loop[=N]: clear-and-redraw every N seconds until killed. Render to a buffer
# first, then clear+print in one shot, so the pane never shows a half-drawn frame.
main() {
  local arg="${1:-}"
  case "$arg" in
    --loop|--loop=*)
      local interval=5
      [[ "$arg" == --loop=* ]] && interval="${arg#--loop=}"
      # Restore the cursor and clear on exit so the pane isn't left mid-frame.
      trap 'tput cnorm 2>/dev/null; exit 0' INT TERM
      tput civis 2>/dev/null || true
      while :; do
        local frame; frame=$(render)
        # Resize our own pane to fit the frame (grow and shrink), capped at
        # MAX_LINES. Only when running inside tmux with a known pane. The list
        # changes mainly when Adam interacts with a session, so this rarely
        # fires mid-keystroke. Resize before drawing so the frame fills it.
        if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]]; then
          local want; want=$(printf '%s\n' "$frame" | awk 'NF{n++} END{print n+0}')
          (( want > MAX_LINES )) && want=$MAX_LINES
          (( want < 1 )) && want=1
          fit_pane "$want"
        fi
        clear
        printf '%s\n' "$frame"
        sleep "$interval"
      done
      ;;
    ''|--once)
      render
      ;;
    *)
      echo "usage: $0 [--once | --loop[=SECONDS]]" >&2
      exit 2
      ;;
  esac
}

# Run only when executed, not when sourced, so the tests can load the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
