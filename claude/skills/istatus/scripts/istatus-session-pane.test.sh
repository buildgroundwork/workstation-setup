#!/usr/bin/env bash
# Tests for istatus-session-pane.sh — which tmux pane shows a session that runs
# in the background (`claude --bg`), found from the `claude attach` process.
# Plain bash, no framework, no deps beyond awk. No `set -e`: a missing or
# failing script must surface as a FAIL line from assert_eq, not as an abort.
#
# A stub tmux and a stub ps sit ahead of the real ones on PATH; each prints the
# file named by STUB_TMUX or STUB_PS.
#
# Run: claude/skills/istatus/scripts/istatus-session-pane.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/istatus-session-pane.sh"
DIR=""
ORIG_PATH="$PATH"
PASS=0
FAIL=0

SID=ba41dc57-dca5-436c-8a18-f0edac269d73

setup() {
  DIR="$(mktemp -d)"
  mkdir -p "$DIR/bin"
  printf '#!/bin/sh\ncat "$STUB_TMUX"\n' > "$DIR/bin/tmux"
  printf '#!/bin/sh\ncat "$STUB_PS"\n' > "$DIR/bin/ps"
  chmod +x "$DIR/bin/tmux" "$DIR/bin/ps"
  export STUB_TMUX="$DIR/tmux.out" STUB_PS="$DIR/ps.out"
  : > "$STUB_TMUX"
  : > "$STUB_PS"
  PATH="$DIR/bin:$ORIG_PATH"
}
teardown() {
  PATH="$ORIG_PATH"
  [[ -n "$DIR" && -d "$DIR" ]] && rm -rf "$DIR"
  DIR=""
}
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

# pane_pids <pane pid>... — what the stub tmux prints for list-panes.
pane_pids() {
  : > "$STUB_TMUX"
  while [[ $# -ge 2 ]]; do
    printf '%s\t%s\n' "$1" "$2" >> "$STUB_TMUX"
    shift 2
  done
}

# procs <pid ppid args>... — what the stub ps prints, a line per process.
procs() {
  : > "$STUB_PS"
  while [[ $# -ge 3 ]]; do
    printf '%5s %5s %s\n' "$1" "$2" "$3" >> "$STUB_PS"
    shift 3
  done
}

# pane_of <session id> -> "<pane>|rc=N"
pane_of() { local out; out=$("$SCRIPT" "$1" 2>/dev/null); echo "$out|rc=$?"; }

# ── a session attached in a pane's shell ─────────────────────────────────────
setup
pane_pids %381 32896 %382 33339
procs 32896 4836 -zsh 2662 32896 "claude attach ba41dc57" 20359 33339 "claude attach a5702e62"
assert_eq "$(pane_of "$SID")" "%381|rc=0" "finds the pane whose shell runs the session's claude attach"
assert_eq "$(pane_of a5702e62-0000-0000-0000-000000000000)" "%382|rc=0" "tells two attached sessions apart"
teardown

# ── attach is the pane's own process, or deeper than its child ───────────────
setup
pane_pids %7 500
procs 500 4836 "claude attach ba41dc57"
assert_eq "$(pane_of "$SID")" "%7|rc=0" "finds a claude attach that is the pane's own process"
teardown

setup
pane_pids %7 500
procs 500 4836 -zsh 600 500 "sh -c wrapper" 700 600 "/opt/bin/claude attach ba41dc57"
assert_eq "$(pane_of "$SID")" "%7|rc=0" "climbs from a claude attach below the pane's shell, by path"
teardown

# ── no pane ──────────────────────────────────────────────────────────────────
setup
pane_pids %381 32896
procs 32896 4836 -zsh 2662 32896 "claude attach 5a4ca2f6"
assert_eq "$(pane_of "$SID")" "|rc=1" "finds nothing for a session no claude attach shows"
teardown

setup
pane_pids %381 32896
procs 32896 4836 -zsh 2662 1 "claude attach ba41dc57"
assert_eq "$(pane_of "$SID")" "|rc=1" "finds nothing for a claude attach outside every pane"
teardown

setup
pane_pids %381 32896
procs 32896 4836 -zsh 2662 32896 "claude attach ba41dc57x"
assert_eq "$(pane_of "$SID")" "|rc=1" "does not take an id that only starts like the session's"
teardown

setup
printf '#!/bin/sh\nexit 1\n' > "$DIR/bin/tmux"
procs 2662 32896 "claude attach ba41dc57"
assert_eq "$(pane_of "$SID")" "|rc=1" "finds nothing when tmux fails"
teardown

# ── usage ────────────────────────────────────────────────────────────────────
setup
assert_eq "$("$SCRIPT" >/dev/null 2>&1; echo "rc=$?")" "rc=2" "no session id exits 2"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
