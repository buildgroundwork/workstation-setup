#!/bin/bash
# istatus-float — the istatus sidebar as a floating pane in the top-right
# corner of a Claude pane's window, so it can sit over the window without
# taking a slice of it, and without taking the keyboard unless asked.
#
# Usage (from the tmux key bindings, with the active pane as <pane>, which may
# be the status pane itself):
#   istatus-float.sh toggle <pane>
#     Shows the window's status pane, collapsed to its one-row title bar
#     (counts only), or closes it if it is showing. Closing it while it has
#     the keyboard gives the keyboard to the Claude pane.
#   istatus-float.sh expand <pane>
#     Switches it between collapsed and expanded (the full, interactive
#     list), opening it expanded if it is closed. Expanding keeps the
#     keyboard where it was; collapsing gives it to the Claude pane.
#   istatus-float.sh focus <pane>
#     Moves the keyboard into the status pane, or back to the Claude pane
#     from it, opening it expanded if it is closed.
#
# Floating panes are new in tmux 3.7, and resize-pane on one also resizes the
# tiled pane under it (verified on 3.7c), so expanding and collapsing close
# the status pane and open a new one at the other size instead. The sidebar
# keeps its view across that through its own state file.
#
# The status pane is marked with the pane option @istatus_paired (the Claude
# pane it shows) and @istatus_expanded, which is how a later call finds it and
# knows its state, from either pane.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDEBAR="$SCRIPT_DIR/istatus-sidebar.sh"
COLLAPSED_COLS=44
INSET=2

die() { printf 'istatus-float: %s\n' "$*" >&2; exit 1; }

main() {
  local subcmd="${1:-}" pane="${2:-}"
  [[ -n "$pane" ]] || die "usage: istatus-float.sh {toggle|expand|focus} <pane>"
  local paired status
  paired=$(paired_pane "$pane")
  status=$(status_pane "$paired")
  case "$subcmd" in
    toggle) cmd_toggle "$pane" "$paired" "$status" ;;
    expand) cmd_expand "$pane" "$paired" "$status" ;;
    focus)  cmd_focus "$pane" "$paired" "$status" ;;
    *)      die "usage: istatus-float.sh {toggle|expand|focus} <pane>" ;;
  esac
}

cmd_toggle() {
  local pane="$1" paired="$2" status="$3"
  if [[ -n "$status" ]]; then
    tmux kill-pane -t "$status"
    hand_back "$pane" "$status" "$paired"
  else
    open "$paired" collapsed background
  fi
}

# Expanding keeps the keyboard where it was. Collapsing gives it back to the
# Claude pane: a one-row bar shows nothing to act on.
cmd_expand() {
  local pane="$1" paired="$2" status="$3"
  if [[ -z "$status" ]]; then
    open "$paired" expanded background
    return
  fi
  local expanded
  expanded=$(tmux display-message -p -t "$status" '#{@istatus_expanded}')
  tmux kill-pane -t "$status"
  if [[ "$expanded" == 1 ]]; then
    open "$paired" collapsed background
    hand_back "$pane" "$status" "$paired"
  elif [[ "$pane" == "$status" ]]; then
    open "$paired" expanded foreground
  else
    open "$paired" expanded background
  fi
}

cmd_focus() {
  local pane="$1" paired="$2" status="$3"
  if [[ -z "$status" ]]; then
    open "$paired" expanded foreground
  elif [[ "$pane" == "$status" ]]; then
    tmux select-pane -t "$paired"
  else
    tmux select-pane -t "$status"
  fi
}

# hand_back <pane> <status> <paired> — after the status pane closed or
# collapsed, gives the keyboard to the Claude pane if the status pane had it.
# Left to itself, tmux picks whichever pane was active before, which may be
# neither.
hand_back() {
  [[ "$1" == "$2" ]] && tmux select-pane -t "$3"
  return 0
}

# open <paired> collapsed|expanded background|foreground — a floating status
# pane INSET cells in from the window's top-right corner: one for its border
# and the rest a gap, so it reads as a box rather than part of the edge. Its
# border also takes the row below it and the column left of it.
open() {
  local paired="$1" shape="$2" focus="$3" ww wh w h new
  read -r ww wh < <(tmux display-message -p -t "$paired" '#{window_width} #{window_height}')
  local room_w=$(( ww - INSET - 1 )) room_h=$(( wh - INSET - 1 ))
  if [[ "$shape" == collapsed ]]; then
    w=$(( room_w < COLLAPSED_COLS ? room_w : COLLAPSED_COLS ))
    h=1
  else
    w=$(( ww / 3 > COLLAPSED_COLS ? ww / 3 : COLLAPSED_COLS ))
    w=$(( w > room_w ? room_w : w ))
    h=$(( wh * 2 / 3 ))
    h=$(( h < 3 ? 3 : h ))
    h=$(( h > room_h ? room_h : h ))
  fi
  local args=(-P -F '#{pane_id}' -t "$paired" -x "$w" -y "$h" -X "$(( ww - w - INSET ))" -Y "$INSET")
  [[ "$focus" == foreground ]] || args=(-d "${args[@]}")
  new=$(tmux new-pane "${args[@]}" "$SIDEBAR" "$paired")
  tmux set-option -p -t "$new" @istatus_paired "$paired"
  tmux set-option -p -t "$new" @istatus_expanded "$([[ "$shape" == expanded ]] && echo 1 || echo 0)"
}

# The Claude pane a key was pressed for: the pane itself, or, when it is the
# status pane, the pane that status pane shows.
paired_pane() {
  local paired
  paired=$(tmux display-message -p -t "$1" '#{@istatus_paired}')
  printf '%s' "${paired:-$1}"
}

# The window's status pane for <paired>, or nothing.
status_pane() {
  tmux list-panes -t "$1" -F '#{pane_id} #{@istatus_paired}' \
    | awk -v p="$1" '$2 == p { print $1; exit }'
}

main "$@"
