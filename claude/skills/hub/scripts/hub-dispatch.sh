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
#   ready
#       List dispatched panes by state — which have FINISHED (task.ready, the
#       Stop hook flipped them) vs. still in-flight (task.dispatched). The
#       read-side payoff of `send` arming the pane. One line per pane:
#       "<kind>\t<session>:<window>\t<prompt>".
#
# A "target" is "<session>:<window>"; send/capture operate on that window's
# active pane. Pure-navigation, capture, and ready are read-ish; only `send`
# types.

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

  # Resolve the concrete pane id once — every check below keys on it, and a
  # window target's active pane could otherwise drift between checks.
  local pane
  pane=$(tmux display-message -t "$target" -p '#{pane_id}' 2>/dev/null) \
    || err "could not resolve pane for: $target"
  [[ -n "$pane" ]] || err "could not resolve pane for: $target"

  # GATE: refuse if the pane is in copy/scroll mode. The user co-uses these
  # panes; copy-mode means they're actively reading scrollback, and send-keys
  # into a pane in copy-mode is *swallowed by copy-mode* (the keys are
  # interpreted as copy-mode commands, not delivered to Claude) — so it both
  # fails AND disrupts. `#{pane_in_mode}` is a reliable first-class tmux signal
  # (1 = in any mode). Do NOT force-exit the mode; that would yank the user out
  # of what they're reading. Refuse, report, exit non-zero — the caller retries
  # when the pane is free. (Mid-generation is deliberately NOT gated: Claude's
  # TUI queues typed input until the current turn ends, so a send into a busy-
  # but-not-in-mode pane is safe; copy-mode is the only real hazard.)
  if [[ "$(tmux display-message -t "$pane" -p '#{pane_in_mode}' 2>/dev/null)" == "1" ]]; then
    printf 'pane %s (%s) is in copy/scroll mode — not sending (you are looking at it). Retry when it is at the prompt.\n' \
      "$pane" "$target" >&2
    return 3
  fi

  # DELIVER via bracketed paste (load-buffer + paste-buffer -p), not send-keys
  # -l. A long multi-line prompt injected as raw keystrokes can interleave with
  # a TUI redraw and land malformed; a bracketed paste is delivered as one
  # atomic unit the terminal won't tear. Enter follows as its own key event,
  # after a settle, so it submits rather than landing inside the paste buffer.
  local buf="hub-dispatch-$$"
  printf '%s' "$prompt" | tmux load-buffer -b "$buf" - 2>/dev/null \
    || err "failed to stage prompt buffer for: $target"
  tmux paste-buffer -t "$pane" -b "$buf" -p -d 2>/dev/null   # -d deletes the buffer after paste
  sleep 0.3
  tmux send-keys -t "$pane" Enter

  # CONFIRM before arming. The send above can still silently fail to land (a
  # transient mode flip, a dead pane). Arming a pane we didn't actually deliver
  # to is the bug behind phantom "dispatched" rows and the resend race (operator
  # can't tell a dropped send from a submitted one, resends, double-dispatches).
  # So verify the input line is now empty (the prompt submitted) before writing
  # the task.dispatched row. A non-empty input line after Enter means the prompt
  # is sitting unsent (e.g. it arrived mid-redraw) — report and DON'T arm.
  sleep 0.4
  if _pane_input_pending "$pane"; then
    printf 'WARNING: prompt may not have submitted on %s (%s) — input line not clear. NOT arming; verify the pane.\n' \
      "$pane" "$target" >&2
    return 4
  fi

  # Mark the dispatched pane as awaiting a result (state: task.dispatched), so
  # the dashboard and popup show it in-flight and the finish-detection Stop hook
  # can later flip it to task.ready. Best-effort: arming must never break a
  # dispatch, so a missing plugin or a resolve failure is silently ignored.
  _arm_target "$pane" "$prompt" || true
}

# Heuristic: does the pane's input line still hold unsent text? After a
# successful submit the Claude TUI input shows an empty prompt (a bare "❯" with
# nothing after it). If the last non-blank line is a prompt glyph followed by
# visible text, the prompt didn't submit. Best-effort and conservative: on any
# uncertainty it returns false (not-pending) so a real send is never reported as
# failed — the cost of a false "ok" is a stale dispatched row (self-heals when
# the pane finishes), whereas a false "pending" would spuriously refuse a good
# send. Returns 0 (true) only when it is fairly sure text is sitting unsent.
_pane_input_pending() {
  local pane="$1" lastline
  lastline=$(tmux capture-pane -t "$pane" -p 2>/dev/null | grep -vE '^\s*$' | tail -1)
  # A prompt glyph (❯ or >) immediately followed by non-space text == unsent.
  [[ "$lastline" =~ ^[[:space:]]*[❯\>][[:space:]]+[^[:space:]] ]]
}

# Resolve the claude-tmux-attention state script. Its install path is
# version-stamped, so find it rather than hardcode; prints the path, or empty
# (return 1) if the plugin isn't installed.
_state_script() {
  local s
  s=$(find "$HOME/.claude/plugins/cache" -name attention-state.sh -path '*claude-tmux-attention*' 2>/dev/null | sort | tail -1)
  [[ -n "$s" && -x "$s" ]] || return 1
  printf '%s' "$s"
}

# Arm the pane (state: task.dispatched). Takes an already-resolved pane id (the
# caller resolves it once, up front). Returns non-zero (caller ignores) if the
# plugin isn't installed.
_arm_target() {
  local pane="$1" prompt="$2" state_script
  state_script=$(_state_script) || return 1
  [[ -n "$pane" ]] || return 1
  "$state_script" arm "$pane" "$prompt" >/dev/null 2>&1
}

# List dispatched panes that have FINISHED (kind: task.ready) — the read-side
# payoff of arm: the finish-detection Stop hook flips a pane task.dispatched ->
# task.ready when its session stops, and this surfaces those. Prints one line
# per ready pane: "<session>:<window>\t<prompt>". Also (with a header) shows
# still-in-flight (task.dispatched) panes so the hub can report "N ready, M
# still working". Reads through attention-state.sh list (the supported consumer
# API), which already filters dead panes.
cmd_ready_list() {
  local state_script json
  state_script=$(_state_script) || { echo "claude-tmux-attention not installed; no dispatch state" >&2; return 1; }
  json=$("$state_script" list 2>/dev/null) || return 1
  # tmux_session:tmux_window<TAB>kind<TAB>prompt, for task.* rows only.
  # NOTE: reads the scalar `kind` (current plugin contract). When the
  # claude-tmux-attention redesign merges, `kind` becomes a derived shim and
  # `states` is canonical — migrate this to read `.states` then, in one commit.
  printf '%s' "$json" | jq -r '
    .[]
    | select(.kind == "task.ready" or .kind == "task.dispatched")
    | "\(.kind)\t\(.tmux_session):\(.tmux_window)\t\(.prompt)"
  '
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
  # Reading the pane back is the consume step that closes the dispatch
  # lifecycle: dispatched -> ready -> (read) -> cleared. Without this, a
  # finished dispatch's task.ready row lingers in the shared state file and the
  # plugin's attention popup/status-line surface it as a phantom "needs
  # attention". Clear ONLY a task.ready row for this pane — never a live
  # attention.needed (a genuinely-blocked pane Adam is just looking at must
  # keep its real attention signal). Best-effort; never fails the capture.
  _clear_ready "$target" || true
}

# Remove this target's task.ready row (consumed-dispatch cleanup), but only if
# that's what the pane has — leave attention.needed and task.dispatched alone.
# NOTE: uses remove-by-pane + a manual "don't clobber attention" guard (current
# plugin contract). When the redesign merges, this becomes a single
# `mark-viewed <pane>` call (which clears only task.ready by contract, making
# the guard unnecessary) — migrate then, in the same commit as cmd_ready_list.
_clear_ready() {
  local target="$1" state_script pane kinds
  state_script=$(_state_script) || return 0
  pane=$(tmux display-message -t "$target" -p '#{pane_id}' 2>/dev/null) || return 0
  [[ -n "$pane" ]] || return 0
  kinds=$("$state_script" list 2>/dev/null | jq -r --arg p "$pane" \
    '[ .[] | select(.tmux_pane == $p) | .kind ] | join(" ")' 2>/dev/null)
  case " $kinds " in
    *" attention.needed "*) return 0 ;;                 # real attention — keep it
    *" task.ready "*) "$state_script" remove-by-pane "$pane" >/dev/null 2>&1 ;;
  esac
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    target)  cmd_target "$@" ;;
    send)    cmd_send "$@" ;;
    go)      cmd_go "$@" ;;
    capture) cmd_capture "$@" ;;
    ready)   cmd_ready_list "$@" ;;
    *) err "usage: $0 {target <project>|send <target>|go <target>|capture <target>|ready}" ;;
  esac
}

main "$@"
