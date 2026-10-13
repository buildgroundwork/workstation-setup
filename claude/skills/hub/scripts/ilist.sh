#!/bin/bash
# ilist — list the Claude sessions currently connected to the inter-session bus.
#
# Why this exists: isend/iflag SEND but can't DISCOVER. An agent told to message
# a peer it doesn't already have a name for has no frictionless way to find the
# name — so it reaches for the inter-session SKILL's `list` (prompts) or pokes
# the filesystem (prompts), purely as a discovery workaround. ilist closes that
# gap: a stable, allowlisted name (Bash(ilist:*)) that reads the bus's own client
# registry and prints the connected peer names. With ilist + isend, the whole
# path is "ilist to find the name, isend <name> < file to send" — no skill, no
# filesystem poking.
#
# Source: inter-session writes one clients/<pid>.session file per connected
# session; .name is the bus identity. Pure read — never touches the bus or sends
# anything. This is the same registry the hub dashboard reads for its ⇄ marker.
#
# Usage:
#   ilist            one connected peer name per line, sorted
#   ilist --self     also mark which one is THIS session (by CLAUDE_CODE_SESSION_ID)
#
# Exit: 0 always (an empty bus is a valid answer: prints nothing). Degrades
# silently if inter-session isn't installed / nothing is connected.

set -euo pipefail

CLIENTS_DIR="$HOME/.claude/data/inter-session/clients"

[[ -d "$CLIENTS_DIR" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

self_sid="${CLAUDE_CODE_SESSION_ID:-}"
mark_self=0
[[ "${1:-}" == "--self" ]] && mark_self=1

# Emit "name" (or "name (this session)" with --self), one per line, sorted by
# name. Reads name + session_id from each client file; a malformed/partial file
# is skipped by jq's // empty.
for f in "$CLIENTS_DIR"/*.session; do
  [[ -f "$f" ]] || continue
  jq -r --arg self "$self_sid" --argjson mark "$mark_self" '
    select(.name != null and .name != "")
    | if ($mark == 1 and $self != "" and .session_id == $self)
      then "\(.name) (this session)"
      else .name end
  ' "$f" 2>/dev/null || true
done | sort
