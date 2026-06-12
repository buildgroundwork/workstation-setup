#!/bin/bash
# hub-stop-hook.sh — personal Stop-hook finish-detection for hub dispatch.
#
# Wired via the global ~/.claude/settings.json Stop hook (NOT the shipped
# claude-tmux-attention plugin — Stop is per-turn-frequent and the plan keeps
# this in the personal layer so it costs marketplace users nothing). When a
# Claude session stops, this checks whether THIS pane was armed by a hub
# dispatch (has a kind:task.dispatched row); if so, flips it to task.ready so
# the hub/dashboard/popup show the result is waiting. If not armed, it does
# nothing — the overwhelmingly common case.
#
# Hook discipline (per the plugin's scripts/CLAUDE.md): fast, silent, must
# never break the session. Cheap negative check first; always exit 0.

# Pane the stopping session runs in. No pane → nothing to flip.
[[ -n "${TMUX_PANE:-}" ]] || exit 0

STATE_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}"
STATE_FILE="$STATE_DIR/pending.json"

# Cheap negative check BEFORE resolving the plugin or taking any lock: if this
# pane id isn't in the state file at all, there's nothing armed to flip. An
# unlocked grep is safe — writers replace the file via atomic mv, so grep never
# sees a torn file, and "absent" is a guaranteed no-op (same reasoning as the
# plugin's cmd_remove fast-path).
[[ -f "$STATE_FILE" ]] || exit 0
grep -qF "$TMUX_PANE" "$STATE_FILE" 2>/dev/null || exit 0

# Resolve the installed plugin's attention-state.sh from the marketplace cache
# (version-stamped path; pick the highest version). This is what shipped
# sessions run and survives version bumps. No dev-checkout fallback.
state_script=$(find "$HOME/.claude/plugins/cache" -name attention-state.sh -path '*claude-tmux-attention*' 2>/dev/null | sort | tail -1)
[[ -n "$state_script" && -x "$state_script" ]] || exit 0

# Flip this pane's dispatched row to ready. `ready` is idempotent and a no-op
# if the pane has only a notification (attention.needed) row, so a stray Stop
# on a non-dispatched pane that merely shares the grep match is harmless.
"$state_script" ready "$TMUX_PANE" >/dev/null 2>&1

exit 0
