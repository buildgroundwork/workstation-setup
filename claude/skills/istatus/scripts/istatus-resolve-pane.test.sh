#!/usr/bin/env bash
# Tests for istatus-resolve-pane.sh — the session that occupies a tmux pane,
# read from the pane's occupancy pointer unless the pointer predates the pane
# (tmux reuses pane ids).
# Plain bash, no framework, no deps, a scratch state dir per case.
#
# ISTATUS_TMUX_PANES (a fourth field being the pane's start epoch) stands in
# for tmux and ps. No `set -e`: a missing or failing script must surface as a
# FAIL line from assert_eq, not as an abort.
#
# Run: claude/skills/istatus/scripts/istatus-resolve-pane.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/istatus-resolve-pane.sh"
DIR=""
PASS=0
FAIL=0

setup() {
  DIR="$(mktemp -d)"
  export CLAUDE_TMUX_ATTENTION_DIR="$DIR"
  mkdir -p "$DIR/panes"
  unset ISTATUS_TMUX_PANES
}
teardown() { [[ -n "$DIR" && -d "$DIR" ]] && rm -rf "$DIR"; DIR=""; }
trap teardown EXIT

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label (got [$got], want [$want])"
    FAIL=$((FAIL + 1))
  fi
}

# pointer_at <pane> <session_id> <epoch> — a pointer last written at <epoch>.
pointer_at() {
  printf '%s' "$2" > "$DIR/panes/$1.session_id"
  touch -t "$(date -r "$3" +%Y%m%d%H%M.%S)" "$DIR/panes/$1.session_id"
}

# resolve <pane> -> "<stdout>|rc=<status>", stderr dropped.
resolve() { local out; out=$("$SCRIPT" "$1" 2>/dev/null); echo "$out|rc=$?"; }

NOW=$(date +%s)

# ── a current pointer names the occupant ─────────────────────────────────────
setup
export ISTATUS_TMUX_PANES=$'%7\tproj\t1\t'"$((NOW - 1000))"
pointer_at %7 sess-1 $((NOW - 10))
assert_eq "$(resolve %7)" "sess-1|rc=0" "a pointer written after its pane started resolves"
teardown

# ── a pane with no start time keeps its pointer ──────────────────────────────
setup
export ISTATUS_TMUX_PANES=$'%7\tproj\t1\t'
pointer_at %7 sess-1 $((NOW - 1000))
assert_eq "$(resolve %7)" "sess-1|rc=0" "a pointer resolves when the pane's start time is unknown"
teardown

# ── a pointer left by an earlier pane with the same id names nobody ──────────
setup
export ISTATUS_TMUX_PANES=$'%7\toms-stack\t1\t'"$((NOW - 10))"
pointer_at %7 sess-old $((NOW - 1000))
assert_eq "$(resolve %7)" "|rc=1" "a pointer older than the pane that reused its id is unresolved"
teardown

# ── no pointer ───────────────────────────────────────────────────────────────
setup
export ISTATUS_TMUX_PANES=$'%7\tproj\t1\t'"$((NOW - 10))"
assert_eq "$(resolve %7)" "|rc=1" "a pane with no pointer is unresolved"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
