#!/bin/bash
# istatus-popup — the tmux popup that lists the sessions that need attention
# and jumps to the one you pick.
#
# Usage:
#   istatus-popup.sh rows
#     Prints one tab-separated line per live session with something to act on
#     or watch: label, session:window, reason, summary, pane.
#   istatus-popup.sh dismiss <pane>
#     Marks every notice of the session in <pane> read, which is what the
#     popup's dismiss key runs on a row. A blocking item stays; only answering
#     the prompt clears it.
#   istatus-popup.sh
#     Shows those rows in fzf inside a tmux popup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INBOX="$SCRIPT_DIR/istatus-inbox.sh"
ISTATUS="$SCRIPT_DIR/istatus.sh"

cmd_rows() {
  "$INBOX" list | jq -r '
    def state_label:
      { blocked: "needs you", flagged: "wants you", ready: "ready", dispatched: "working" }[.state];
    # A tab or newline inside a text would split the row for fzf.
    def one_line: (. // "") | tostring | gsub("[\t\n\r]"; " ");
    def urgency: { blocked: 0, flagged: 1, ready: 2, dispatched: 3 }[.state];
    [ .[] | select(.state != "") ]
    | sort_by([urgency, .tmux_session, (.tmux_window | tonumber? // 0)])
    | .[]
    | [ state_label,
        "\(.tmux_session):\(.tmux_window)",
        (.reason | one_line),
        (.summary | one_line),
        .pane ]
    | @tsv'
}

cmd_dismiss() {
  local pane="${1:?usage: istatus-popup.sh dismiss <pane>}"
  "$ISTATUS" --pane "$pane" defer --all
}

# Pick a session in fzf, inside a tmux popup, and jump to it. Tested with a
# stub tmux for its exit status, its cleanup and the switch it makes; the real
# fzf and popup rendering need a live tmux and a terminal, so they are
# exercised end to end.
cmd_popup() {
  local rows input output
  rows=$(cmd_rows)
  if [[ -z "$rows" ]]; then
    tmux display-message "No sessions need attention"
    return 0
  fi

  # `tmux display-popup -E` opens a fresh pty for the inner command, so an
  # outer pipe does not reach fzf's stdin. The list goes in through a temp file
  # and the selection comes back through another. They are removed explicitly
  # when the pick is done, not by an EXIT trap: a trap runs after this function
  # has returned, when its locals are gone, and under `set -u` it dies, which
  # made every jump exit 1 (tmux shows that over the pane) and leak both files.
  # The template names $TMPDIR itself: `mktemp -t` uses the user's temp dir
  # whatever $TMPDIR says.
  input=$(mktemp "${TMPDIR:-/tmp}/istatus-popup.XXXXXX")
  output=$(mktemp "${TMPDIR:-/tmp}/istatus-popup.XXXXXX")
  printf '%s\n' "$rows" > "$input"
  # The `|| true` also turns off `set -e` inside pick_and_jump. That is
  # deliberate: every step in it is best-effort, and a failure falls through
  # harmlessly to the cleanup below.
  pick_and_jump "$input" "$output" || true
  rm -f "$input" "$output"
}

# pick_and_jump <input file> <output file> — show the rows in fzf in a popup
# and, if one is picked, mark its pane viewed and switch to it.
pick_and_jump() {
  local input="$1" output="$2" selected pane

  # ctrl-x dismisses the row's notices and reloads the list in place, so a
  # flag the session itself will never resolve can be cleared without
  # leaving the popup. A ctrl key, since plain letters go to fzf's query.
  tmux display-popup -E -w 80% -h 60% -T " Claude sessions " \
    -e "ISTATUS_INPUT=$input" -e "ISTATUS_OUTPUT=$output" \
    -e "ISTATUS_POPUP=$SCRIPT_DIR/istatus-popup.sh" -- \
    bash -c '
      fzf \
        --no-sort \
        --reverse \
        --header "enter: jump   ctrl-x: dismiss notices   esc: close" \
        --delimiter "\t" \
        --with-nth "1,2,3,4" \
        --preview-window down:3 \
        --preview "echo State:   {1}; echo Reason:  {3}; echo Summary: {4}" \
        --bind "ctrl-x:execute-silent(\"\$ISTATUS_POPUP\" dismiss {5} 2>/dev/null)+reload(\"\$ISTATUS_POPUP\" rows)" \
        < "$ISTATUS_INPUT" > "$ISTATUS_OUTPUT"
    ' 2>/dev/null || true

  selected=$(<"$output")
  [[ -n "$selected" ]] || return 0
  pane=$(cut -f5 <<<"$selected")
  if [[ -z "$pane" ]]; then
    tmux display-message "Selected entry has no tmux pane recorded"
    return 0
  fi

  # Jumping to the pane is the "viewed" transition: the finished-dispatch
  # notice stops counting. Best-effort; the jump matters more than the
  # bookkeeping.
  "$SCRIPT_DIR/istatus-hook.sh" viewed "$pane" || true

  # A pane-targeted switch-client lands on the right session, window and pane
  # in one step; the three-step sequence races.
  tmux switch-client -t "$pane" 2>/dev/null \
    || tmux display-message "istatus: pane $pane no longer exists"
}

case "${1:-}" in
  rows)    cmd_rows ;;
  dismiss) shift; cmd_dismiss "$@" ;;
  "")      cmd_popup ;;
  *)       echo "usage: istatus-popup.sh [rows | dismiss <pane>]" >&2; exit 1 ;;
esac
