#!/bin/bash
# iflag — flag THIS Claude session on the attention bar, from inside the session.
#
# Why this exists: in the peer-messaging graph (inter-session), an agent that
# receives a peer message it judges genuinely needs the human should surface
# that on the same status-bar/popup attention signal the human already watches —
# rather than the conversation staying invisible on the bus. The
# claude-tmux-attention plugin's producer (`attention-state.sh add`) already does
# exactly this: it sets attention.needed on the running pane's row, which the bar
# and popup render. But calling it by hand is fiddly — the producer reads a hook-
# shaped JSON payload from stdin (session_id is load-bearing: a row with no
# session_id can never be cleared and leaks forever), and the script path is
# version-stamped. This wraps both: a stable name an allowlist matches
# (Bash(iflag:*)), the session_id pulled from $CLAUDE_CODE_SESSION_ID, and the
# producer resolved by version glob.
#
# Usage (run BY the agent, inside its own session/pane):
#   iflag "<reason the human is needed>"
#
# The reason becomes the attention row's message (what the popup shows). The row
# is attributed to THIS pane (the producer reads $TMUX_PANE), so the agent can
# only flag itself — which is the right semantics: the session that received the
# message is the one that lights up. It clears the usual way (the plugin's
# resolution hooks clear attention.needed by session_id when the human acts in
# the pane), or via the prefix+A C manual chord.
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

reason="${*:-}"
[[ -n "$reason" ]] || die "usage: iflag \"<reason the human is needed>\""

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

printf '%s' "$payload" | "$state_sh" add || die "attention-state.sh add failed"
printf 'iflag: flagged this session — "%s"\n' "$reason"
