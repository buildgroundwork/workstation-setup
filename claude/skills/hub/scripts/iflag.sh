#!/bin/bash
# iflag — flag THIS Claude session on the attention bar, from inside the session.
#
# Why this exists: in the peer-messaging graph (inter-session), an agent that
# receives a peer message it judges genuinely needs the human should surface
# that on the same status-bar/popup attention signal the human already watches —
# rather than the conversation staying invisible on the bus. The
# claude-tmux-attention plugin's `request-human` producer does exactly this: it
# sets `human.requested` on the running pane's row, which the bar and popup
# render. Crucially, human.requested clears on VIEW (mark-viewed when the human
# jumps to the pane), NOT on the next PostToolUse — so unlike attention.needed,
# the flag SURVIVES the flagging agent's subsequent tool calls. The agent can
# flag itself and keep working; the flag persists until the human looks. Calling
# the producer by hand is fiddly (it reads a hook-shaped JSON payload from stdin,
# session_id load-bearing; the script path is version-stamped), so this wraps it:
# a stable name an allowlist matches (Bash(iflag:*)), session_id pulled from
# $CLAUDE_CODE_SESSION_ID, producer resolved by version glob.
#
# Usage (run BY the agent, inside its own session/pane; reason on STDIN):
#   iflag <<'EOF'
#   <short reason the human is needed>
#   EOF
# Keep the reason a SHORT pointer ("need your call on X"), not the full question
# — the question belongs in the chat response; the flag just says "come look."
#
# The reason becomes the row's message (what the popup shows). The row is
# attributed to THIS pane (the producer reads $TMUX_PANE), so the agent can only
# flag itself — the right semantics: the session that received the message is the
# one that lights up. It clears when the human VIEWS the pane (the plugin's
# mark-viewed, e.g. via the attention popup's jump), or the prefix+A C chord.
#
# Note: the producer SUPPRESSES the flag if the human is currently focused on
# this pane (you're already looking — no need to flag). That's intended: iflag
# only surfaces when you're elsewhere, which is exactly when you'd want it.
#
# Exit: 0 on a recorded flag; non-zero with a message on stderr if the plugin or
# session id is missing — never silent on failure.

set -euo pipefail

PLUGIN_CACHE="$HOME/.claude/plugins/cache/gusto-claude-code/claude-tmux-attention"

die() { printf 'iflag: %s\n' "$*" >&2; exit 1; }

# The reason is read from STDIN, never an argument — same reason as isend: a
# reason on the command line gets glob-scanned, so metachars in it (parens, a
# question mark, `<->`/`<N-M>`, braces-with-quotes) trip a permission prompt even
# with Bash(iflag:*) allowlisted. Ironically that's most likely to bite exactly
# when flagging — the prompt then does the notifier's job by accident. Reading
# from stdin keeps the reason off the command line. Reject a stray arg (the old
# `iflag "reason"` form) with a pointer rather than silently glob-scanning it.
[[ $# -eq 0 ]] \
  || die "reason goes on STDIN, not as an argument. Use: iflag <<'EOF' … EOF   (or: echo reason | iflag)"
[[ -t 0 ]] && die "no reason on stdin. Use a heredoc: iflag <<'EOF' … EOF"
reason=$(cat)
[[ -n "$reason" ]] || die "empty reason on stdin; nothing to flag"

sid="${CLAUDE_CODE_SESSION_ID:-}"
[[ -n "$sid" ]] \
  || die "CLAUDE_CODE_SESSION_ID not set (not inside a Claude session?) — cannot flag"

# Newest installed plugin version wins (sort -V), so the wrapper follows plugin
# bumps without a hardcoded version.
state_sh=$(ls -d "$PLUGIN_CACHE"/*/scripts/attention-state.sh 2>/dev/null \
  | sort -V | tail -1) || true
[[ -n "${state_sh:-}" && -x "$state_sh" ]] \
  || die "attention-state.sh not found under $PLUGIN_CACHE (plugin installed?)"

# Hand the producer the hook-shaped payload it reads from stdin. session_id is
# the clearable key; message is what the popup shows; cwd is best-effort context.
payload=$(jq -nc --arg sid "$sid" --arg msg "$reason" --arg cwd "$PWD" \
  '{session_id: $sid, message: $msg, cwd: $cwd}') \
  || die "failed to build payload"

printf '%s' "$payload" | "$state_sh" request-human || die "attention-state.sh request-human failed"
printf 'iflag: flagged this session — "%s"\n' "$reason"
