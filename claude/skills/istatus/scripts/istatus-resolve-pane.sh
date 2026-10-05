#!/bin/bash
# istatus-resolve-pane — given a tmux pane id, print the session_id of the
# Claude Code session currently occupying it.
#
# Why this exists: a sidebar pane is paired with a specific tmux pane, not a
# specific Claude session — a `/resume` of a different session UUID into the
# same pane keeps the same inter-session bus name but swaps the actual
# session_id, so the sidebar must re-resolve "who's in this pane right now"
# on every render rather than caching it once.
#
# Method: istatus.sh writes ~/.claude-tmux-attention/panes/<pane>.session_id
# on every call (decide/resolve/summary/show), unconditionally. Just read it.
#
# This used to scan claude-tmux-attention's debug.log instead, but that log
# only exists when CLAUDE_TMUX_ATTENTION_DEBUG=1 is set in the session's own
# env — an opt-in debug flag, not a guarantee. A session started before that
# var landed in settings.json never got it (settings.json changes don't
# apply mid-session), so resolution silently failed for any such session
# even though istatus itself was working fine. The pointer file has no such
# dependency: it's written by istatus.sh itself, unconditionally, using data
# every call already has.
#
# Consequence of the new method: a pane whose session has never called
# istatus (decide/resolve/summary/show) has no pointer yet. That's an honest
# "no istatus activity yet," not a resolution failure — it self-corrects the
# moment the session calls istatus.
#
# Usage: istatus-resolve-pane.sh <tmux-pane-id>   (e.g. %83)
# Prints the session_id to stdout, or nothing + exit 1 if unresolved.

set -euo pipefail

PANES_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/panes"
TARGET_PANE="${1:?usage: istatus-resolve-pane.sh <tmux-pane-id>}"

POINTER_FILE="$PANES_DIR/${TARGET_PANE}.session_id"
[[ -f "$POINTER_FILE" ]] || exit 1

cat "$POINTER_FILE"
