#!/bin/bash
# isend — send an inter-session message to a peer Claude session, with a stable
# name an allowlist can match and a success confirmation the raw entrypoint omits.
#
# Why this exists: the inter-session plugin ships only a Python entrypoint
# (bin/send.py) at a VERSION-STAMPED cache path, invoked as
# `python3 .../0.1.x/.../send.py --to NAME --text 'PAYLOAD'`. That command shape
# is allowlist-hostile three ways: the version dir breaks the rule on every
# plugin bump, the --text payload varies every call (so no literal match), and
# allowlisting bare `python3` is far too broad. A stable wrapper resolved by a
# prefix rule (`Bash(isend:*)` / `Bash(*/isend:*)`) fixes all three: one name,
# payload-agnostic, version-independent. It also prints a `sent → NAME`
# confirmation — send.py is silent on success (exit 0, no output), so a caller
# otherwise can't distinguish a delivered send from a swallowed one.
#
# Usage:
#   isend <name> <text>     send <text> to peer session <name>
#   isend --all <text>      broadcast <text> to all connected peers
#
# Resolution: the plugin's current cache dir (version-globbed, newest wins) for
# send.py, and the plugin's isolated venv python (so `websockets` imports). Both
# are the updater-maintained current paths; no version is hardcoded.
#
# Exit: 0 on a delivered send (prints the confirmation); non-zero with a message
# on stderr if the plugin, venv, or args are missing — never silent on failure.

set -euo pipefail

PLUGIN_CACHE="$HOME/.claude/plugins/cache/inter-session/inter-session"
VENV_PY="$HOME/.claude/data/inter-session/venv/bin/python"

die() { printf 'isend: %s\n' "$*" >&2; exit 1; }

# Newest installed version dir wins (sort -V), so the wrapper follows plugin
# bumps without a hardcoded version.
send_py=$(ls -d "$PLUGIN_CACHE"/*/skills/inter-session/bin/send.py 2>/dev/null \
  | sort -V | tail -1) || true
[[ -n "${send_py:-}" && -f "$send_py" ]] \
  || die "send.py not found under $PLUGIN_CACHE (inter-session installed?)"
[[ -x "$VENV_PY" ]] \
  || die "inter-session venv python not found at $VENV_PY (run /inter-session install-deps?)"

# Parse: broadcast vs. directed. Directed needs both a name and text.
if [[ "${1:-}" == "--all" ]]; then
  shift
  [[ $# -ge 1 ]] || die "usage: isend --all <text>"
  text="$*"
  "$VENV_PY" "$send_py" --all --text "$text" || die "send.py failed (broadcast)"
  printf 'isend: sent → (broadcast)\n'
else
  name="${1:-}"
  shift || true
  [[ -n "$name" && $# -ge 1 ]] || die "usage: isend <name> <text>   |   isend --all <text>"
  text="$*"
  "$VENV_PY" "$send_py" --to "$name" --text "$text" || die "send.py failed (to $name)"
  printf 'isend: sent → %s\n' "$name"
fi
