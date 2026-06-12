#!/bin/bash
# hub-dispatch.sh — send a prompt into a repo's live claude pane, or navigate
# to it. Used by the hub skill AFTER it has confirmed the action with Adam.
#
# Subcommands:
#   target <project>
#       Resolve <project> (a tmuxinator config basename) to its claude window
#       target "<session>:<window>". Starts the session via tmuxinator if it
#       isn't running. Prints the target on stdout. Exit 1 if unresolvable.
#
#   send <target> <<<"prompt text"
#       Type the prompt (read from stdin) into <target> and press Enter.
#       Refuses if the target pane doesn't exist. Does NOT confirm — the
#       skill is responsible for showing Adam the prompt + target and getting
#       an OK before calling this.
#
#   go <target>
#       Switch the active tmux client to <target> (navigate / hand off).
#
#   capture <target>
#       Print the visible contents of <target>'s pane (for read-back).
#
# A "target" is "<session>:<window>"; send/capture operate on that window's
# active pane. Pure-navigation and capture are read-ish; only `send` types.

set -euo pipefail

err() { printf '%s\n' "$*" >&2; exit 1; }

session_running() {
  local name="$1"
  tmux has-session -t "=$name" 2>/dev/null
}

# basename of a tmuxinator config -> its `name:` display value
project_display_name() {
  local project="$1"
  local cfg="${TMUXINATOR_DIR:-$HOME/.workstation/tmuxinator}/${project}.yml"
  [[ -f "$cfg" ]] || err "no tmuxinator config: $cfg"
  local name
  name=$(sed -n 's/^name:[[:space:]]*//p' "$cfg" | head -1)
  printf '%s' "${name:-$project}"
}

cmd_target() {
  local project="${1:?usage: target <project>}"
  local name
  name=$(project_display_name "$project")

  if ! session_running "$name"; then
    command -v tmuxinator >/dev/null 2>&1 || err "tmuxinator not found; cannot start '$project'"
    tmuxinator start "$project" >/dev/null 2>&1 || err "failed to start tmuxinator project '$project'"
    # tmuxinator with attach:false returns promptly, but give the session a
    # moment to register before we look for its windows.
    local tries=20
    while ! session_running "$name"; do
      tries=$((tries - 1)); [[ $tries -le 0 ]] && err "session '$name' did not come up"
      sleep 0.25
    done
  fi

  # Find the claude window in that session.
  local cwin
  cwin=$(tmux list-windows -t "=$name" -F '#{window_index} #{window_name}' 2>/dev/null \
    | awk '$2=="claude"{print $1; exit}')
  [[ -n "$cwin" ]] || err "session '$name' has no 'claude' window"
  printf '%s:%s' "$name" "$cwin"
}

cmd_send() {
  local target="${1:?usage: send <target>  (prompt on stdin)}"
  tmux list-panes -t "$target" >/dev/null 2>&1 || err "target pane not found: $target"
  local prompt
  prompt=$(cat)
  [[ -n "$prompt" ]] || err "empty prompt; nothing to send"
  # Send the text literally, then Enter as a separate key event so it submits.
  # A long prompt arrives as a bracketed paste; if the Enter follows too
  # quickly it lands *inside* the paste buffer instead of submitting. Pause so
  # the paste settles, then send Enter as its own keystroke.
  tmux send-keys -t "$target" -l "$prompt"
  sleep 0.3
  tmux send-keys -t "$target" Enter
}

cmd_go() {
  local target="${1:?usage: go <target>}"
  tmux list-panes -t "$target" >/dev/null 2>&1 || err "target not found: $target"
  # switch-client works whether or not we're inside the same session.
  local sess="${target%%:*}"
  tmux switch-client -t "=$sess" 2>/dev/null || tmux attach -t "=$sess"
  tmux select-window -t "$target"
}

cmd_capture() {
  local target="${1:?usage: capture <target>}"
  tmux list-panes -t "$target" >/dev/null 2>&1 || err "target not found: $target"
  tmux capture-pane -t "$target" -p
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    target)  cmd_target "$@" ;;
    send)    cmd_send "$@" ;;
    go)      cmd_go "$@" ;;
    capture) cmd_capture "$@" ;;
    *) err "usage: $0 {target <project>|send <target>|go <target>|capture <target>}" ;;
  esac
}

main "$@"
