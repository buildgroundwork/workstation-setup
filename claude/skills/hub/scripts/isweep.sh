#!/bin/bash
# isweep — remove stale inter-session client registrations left by crashed /
# uncleanly-exited Claude sessions. Run at boot (mux startup) or by hand.
#
# Why this exists: inter-session registers each connected session as a
# clients/<pid>.session file. On a GRACEFUL exit the client unlinks its own file
# (client.py atexit). But a machine crash / SIGKILL / iTerm dying bypasses atexit,
# so the file survives as an orphan pointing at a dead pid. inter-session's own
# pruning is LAZY — it only cleans a stale entry when something (list/send)
# happens to touch that specific entry — so crash-orphans accumulate: they show
# up in ilist, and a restarted session for the same cwd registers a NEW pid-file
# beside the dead one (duplicates). This sweeps them all in one proactive pass.
#
# Safety: a .session file whose listener_pid is not alive (`kill -0` fails) is
# provably an orphan — the process that owned it is gone. We remove ONLY those.
# Live sessions are never touched. We re-check liveness immediately before each
# unlink to avoid a race with a pid that just came up. The .lock files are left
# alone deliberately (per inter-session's own design: flock is fd-scoped and the
# kernel releases it on death; unlinking a .lock opens a TOCTOU window).
#
# Usage:
#   isweep            remove dead-pid client files; print what was removed
#   isweep --dry-run  list what WOULD be removed, remove nothing
#
# Exit: 0 always (a clean bus is success). Prints a one-line summary.

set -euo pipefail

CLIENTS_DIR="$HOME/.claude/data/inter-session/clients"
dry=0
[[ "${1:-}" == "--dry-run" ]] && dry=1

# Fail LOUD: any unexpected error prints where it died before the non-zero exit,
# so a caller that halts on it (mux, under set -e) shows a diagnosable reason
# rather than a bare abort. This is the deliberate contract — isweep failing
# should stop the boot with an explanation, not be swallowed.
trap 'printf "isweep: FAILED at line %s (exit %s) — stale inter-session clients NOT swept\n" "$LINENO" "$?" >&2' ERR

# Nothing to do if the dir isn't there (inter-session not installed / never run).
# This is a genuine no-op, not a failure — exit 0.
[[ -d "$CLIENTS_DIR" ]] || { printf 'isweep: no inter-session clients dir; nothing to sweep\n'; exit 0; }
# jq is REQUIRED to parse the client files. If it's missing the sweep cannot do
# its job — that's a broken state, not a no-op, so fail hard (exit 1) rather than
# pretend the bus is clean.
command -v jq >/dev/null 2>&1 || { printf 'isweep: jq not found; cannot parse client files — cannot sweep\n' >&2; exit 1; }

removed=0 kept=0
for f in "$CLIENTS_DIR"/*.session; do
  [[ -e "$f" ]] || continue          # no matches → glob stays literal; skip
  pid=$(jq -r '.listener_pid // empty' "$f" 2>/dev/null)
  name=$(jq -r '.name // "?"' "$f" 2>/dev/null)
  # No pid, or pid not alive → orphan.
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    if (( dry )); then
      printf 'isweep: WOULD remove %s (name=%s, dead pid=%s)\n' "$(basename "$f")" "$name" "${pid:-none}"
    else
      # Re-check liveness right before unlink (race guard), then remove.
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kept=$((kept + 1))           # came alive between check and now; keep
      else
        rm -f "$f" && removed=$((removed + 1))
      fi
    fi
  else
    kept=$((kept + 1))
  fi
done

if (( dry )); then
  printf 'isweep: dry run complete (%s live kept)\n' "$kept"
else
  printf 'isweep: removed %s stale client(s), kept %s live\n' "$removed" "$kept"
fi
