#!/bin/bash
# istatus-status — the tmux status-right segment: one colored block per state
# that at least one live session is in, or nothing at all.
#
# Embed it in the status line, e.g.:
#   set -g status-right '#(/path/to/istatus-status.sh) | %H:%M'
#
# It counts SESSIONS per state, each at its highest state, from
# istatus-inbox.sh list (found next to this script).

set -euo pipefail

# Quiet on any error: a status-line script must never print junk or fail, so
# errors go nowhere and the exit status is always 0. A failure costs a missing
# indicator until the next refresh.
exec 2>/dev/null
trap 'exit 0' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INBOX="$SCRIPT_DIR/istatus-inbox.sh"

# Emit one colored block: fg, bg, glyph, count. Self-padded, self-reset.
segment() {
  printf '#[fg=%s,bg=%s,bold] %s %d #[default] ' "$1" "$2" "$3" "$4"
}

# emit <state> <default fg> <default bg> <default glyph> <count> — the block
# for a state. ISTATUS_<STATE>_FG, _BG and _GLYPH override its look, e.g. a
# plain-ASCII glyph for a terminal with no Nerd Font.
emit() {
  local prefix="ISTATUS_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  local fg_var="${prefix}_FG" bg_var="${prefix}_BG" glyph_var="${prefix}_GLYPH"
  segment "${!fg_var:-$2}" "${!bg_var:-$3}" "${!glyph_var:-$4}" "$5"
}

# One jq fork for every count, emitted as one line each and read together: the
# status line runs this every few seconds for every client.
{
  IFS= read -r n_blocked
  IFS= read -r n_flagged
  IFS= read -r n_ready
  IFS= read -r n_dispatched
} < <("$INBOX" list | jq -r '
  [.[].state] as $states
  | ("blocked", "flagged", "ready", "dispatched") as $state
  | [$states[] | select(. == $state)] | length')

[[ "$n_blocked" -gt 0 ]] && emit blocked black red 󰜌 "$n_blocked"
[[ "$n_flagged" -gt 0 ]] && emit flagged black magenta 󰀎 "$n_flagged"
[[ "$n_ready" -gt 0 ]] && emit ready black yellow 󰂟 "$n_ready"
[[ "$n_dispatched" -gt 0 ]] && emit dispatched black blue 󱐋 "$n_dispatched"

exit 0
