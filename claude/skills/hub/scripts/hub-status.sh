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
#   3. attention-state   — claude-tmux-attention's `list` (the published consumer
#                          API): the authoritative working/waiting signal when
#                          the notifier hooks are installed. Degrades to a
#                          recency heuristic when the state file is empty/absent.
#
# State precedence: attention-state `kind` wins; else mtime heuristic.
# Cold sessions (transcript untouched > COLD_MIN) are folded into one count line.
#
# Pure read. No mutation of any session, the state file, or tmux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOW_TOKENS="${HUB_CONTEXT_WINDOW:-1000000}"   # opus 1m context
WORKING_MIN=3                                    # transcript touched <= this => working
COLD_MIN=1440                                    # transcript untouched > this => cold (24h)
PROJECTS_DIR="$HOME/.claude/projects"
STATE_SCRIPT="$(find "$HOME/.claude" "$HOME/workspace/claude-code" -name attention-state.sh 2>/dev/null | head -1)"

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

# A snapshot of the attention state as "session<TAB>kind" lines (bash 3.2 has
# no associative arrays — macOS ships 3.2). Empty if the state script or file
# is unavailable. attn_kind() looks a session up in it.
ATTN=""
load_attention() {
  [[ -n "$STATE_SCRIPT" && -x "$STATE_SCRIPT" ]] || return 0
  local json
  json=$("$STATE_SCRIPT" list 2>/dev/null) || return 0
  ATTN=$(jq -r '.[] | select(.tmux_session != "") | "\(.tmux_session)\t\(.kind)"' <<<"$json" 2>/dev/null || true)
}

# attn_kind <session-name> -> its kind, or empty.
attn_kind() {
  [[ -n "$ATTN" ]] || return 0
  printf '%s\n' "$ATTN" | awk -F'\t' -v s="$1" '$1==s{print $2; exit}'
}

# state <session-name> <age-min> -> working|waiting|dispatched|ready|idle|cold
resolve_state() {
  local name="$1" age="$2" kind
  kind=$(attn_kind "$name")
  case "$kind" in
    attention.needed) echo waiting;    return ;;
    task.dispatched)  echo dispatched; return ;;
    task.ready)       echo ready;      return ;;
  esac
  if   (( age > COLD_MIN ));    then echo cold
  elif (( age <= WORKING_MIN ));then echo working
  else                              echo idle
  fi
}

icon() {
  case "$1" in
    working)    printf '●' ;;
    waiting)    printf '⏸' ;;
    dispatched) printf '◐' ;;
    ready)      printf '✓' ;;
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
  total=$(printf '%s\n' "$rows" | grep -c .)
  clock=$(date '+%H:%M')

  printf ' HUB · %s live · %s\n' "$total" "$clock"

  # Active rows (working/waiting/dispatched/ready), context-heavy first.
  printf '%s\n' "$rows" \
    | awk -F'\t' '$4!="idle" && $4!="cold"' \
    | sort -t$'\t' -k4,4 -k2,2rn \
    | while IFS=$'\t' read -r name pct age state; do
        printf ' %s %-18s %3s%% %s\n' "$(icon "$state")" "$name" "$pct" "$(bar "$pct")"
      done

  # Idle: one summary line.
  local idle
  idle=$(printf '%s\n' "$rows" | awk -F'\t' '$4=="idle"{printf "%s · ",$1}' | sed 's/ · $//')
  [[ -n "$idle" ]] && printf ' ○ idle: %s\n' "$idle"

  # Cold: folded to a count plus names.
  local coldnames coldn
  coldnames=$(printf '%s\n' "$rows" | awk -F'\t' '$4=="cold"{printf "%s · ",$1}' | sed 's/ · $//')
  coldn=$(printf '%s\n' "$rows" | awk -F'\t' '$4=="cold"' | grep -c .)
  (( coldn > 0 )) && printf ' ◌ cold (%s): %s\n' "$coldn" "$coldnames"
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

main "$@"
