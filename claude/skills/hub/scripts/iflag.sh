#!/bin/bash
# iflag — thin alias for `istatus decide`. Kept as a separate name because
# "flag me" is the natural verb when a session is purely blocked with no
# other open decisions to track; it forwards verbatim to istatus so there is
# exactly one flagging mechanism underneath (istatus also records the reason
# in the session's open-decisions queue, visible to a sidebar/status reader,
# not just the attention popup).
#
# Usage (reason on STDIN, same as always):
#   iflag <<'EOF'
#   <short reason the human is needed>
#   EOF
#
# Resolving the underlying decision (once the human has answered) goes
# through `istatus resolve <id>` — this wrapper only adds, it doesn't track.

set -euo pipefail

die() { printf 'iflag: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 0 ]] \
  || die "reason goes on STDIN, not as an argument. Use: iflag <<'EOF' … EOF   (or: echo reason | iflag)"
[[ -t 0 ]] && die "no reason on stdin. Use a heredoc: iflag <<'EOF' … EOF"
reason=$(cat)
[[ -n "$reason" ]] || die "empty reason on stdin; nothing to flag"

command -v istatus >/dev/null 2>&1 || die "istatus not found on PATH"

printf '%s' "$reason" | istatus decide
