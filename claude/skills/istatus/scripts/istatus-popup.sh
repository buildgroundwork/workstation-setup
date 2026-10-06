#!/bin/bash
# istatus-popup — the tmux popup that lists the sessions that need attention
# and jumps to the one you pick.
#
# Usage:
#   istatus-popup.sh rows
#     Prints one tab-separated line per live session with something to act on
#     or watch: label, session:window, reason, summary, pane.
#   istatus-popup.sh
#     Shows those rows in fzf inside a tmux popup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INBOX="$SCRIPT_DIR/istatus-inbox.sh"

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

# Pick a session in fzf, inside a tmux popup, and jump to it. Not unit-tested:
# it needs a live tmux and a terminal, so it is exercised end to end.
cmd_popup() {
  local rows input output selected pane
  rows=$(cmd_rows)
  if [[ -z "$rows" ]]; then
    tmux display-message "No sessions need attention"
    return 0
  fi

  # `tmux display-popup -E` opens a fresh pty for the inner command, so an
  # outer pipe does not reach fzf's stdin. The list goes in through a temp file
  # and the selection comes back through another.
  input=$(mktemp -t istatus-popup.XXXXXX)
  output=$(mktemp -t istatus-popup.XXXXXX)
  trap 'rm -f "$input" "$output"' EXIT
  printf '%s\n' "$rows" > "$input"

  tmux display-popup -E -w 80% -h 60% -T " Claude sessions " \
    -e "ISTATUS_INPUT=$input" -e "ISTATUS_OUTPUT=$output" -- \
    bash -c '
      fzf \
        --no-sort \
        --reverse \
        --header "enter: jump   esc: close" \
        --delimiter "\t" \
        --with-nth "1,2,3,4" \
        --preview-window down:3 \
        --preview "echo State:   {1}; echo Reason:  {3}; echo Summary: {4}" \
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
  rows) cmd_rows ;;
  "")   cmd_popup ;;
  *)    echo "usage: istatus-popup.sh [rows]" >&2; exit 1 ;;
esac
