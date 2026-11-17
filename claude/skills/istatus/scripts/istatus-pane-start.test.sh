#!/usr/bin/env bash
# Tests for istatus-pane-start.sh — when each tmux pane's process started, and
# whether a pane's occupancy pointer predates it (tmux reuses pane ids).
# Plain bash, no framework, no deps beyond awk and stat, a scratch state dir per
# case.
#
# The real script reads pane pids from tmux and their elapsed times from `ps`,
# so most cases put a stub tmux and a stub ps ahead of the real ones on PATH;
# each prints the file named by STUB_TMUX or STUB_PS. A few cases use
# ISTATUS_TMUX_PANES, which replaces both. No `set -e`: a missing or failing
# script must surface as a FAIL line from assert_eq, not as an abort.
#
# Run: claude/skills/istatus/scripts/istatus-pane-start.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/istatus-pane-start.sh"
DIR=""
ORIG_PATH="$PATH"
PASS=0
FAIL=0

setup() {
  DIR="$(mktemp -d)"
  export CLAUDE_TMUX_ATTENTION_DIR="$DIR"
  unset ISTATUS_TMUX_PANES
  mkdir -p "$DIR/bin" "$DIR/panes"
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
  local pane pid
  : > "$STUB_TMUX"
  while [[ $# -ge 2 ]]; do
    pane="$1" pid="$2"
    shift 2
    printf '%s\t%s\n' "$pane" "$pid" >> "$STUB_TMUX"
  done
}

# ps_etimes <pid etime>... — what the stub ps prints, a pid per line as ps does.
ps_etimes() {
  local pid etime
  : > "$STUB_PS"
  while [[ $# -ge 2 ]]; do
    pid="$1" etime="$2"
    shift 2
    printf '%5s %s\n' "$pid" "$etime" >> "$STUB_PS"
  done
}

# age_of <pane> -> seconds since the pane's process started, per `starts`; the
# empty string when there is no start time for it.
age_of() {
  local epoch
  epoch=$("$SCRIPT" starts "$1" | awk -F'\t' '{ print $2 }')
  [[ -n "$epoch" ]] && echo $(( $(date +%s) - epoch ))
}

# within <got> <want> -> "ok" when got is want, up to two seconds late (the
# script reads the clock after the test computed want).
within() {
  if [[ -n "$1" ]] && (( $1 >= $2 && $1 <= $2 + 2 )); then echo ok; else echo "[$1] not within 2s of [$2]"; fi
}

# pointer_at <pane> <epoch> — a pointer for <pane> last written at <epoch>.
pointer_at() {
  printf 'sess-1' > "$DIR/panes/$1.session_id"
  touch -t "$(date -r "$2" +%Y%m%d%H%M.%S)" "$DIR/panes/$1.session_id"
}

# stale_rc <pane> -> the exit status of `stale`, as "rc=N".
stale_rc() { "$SCRIPT" stale "$1" >/dev/null 2>&1; echo "rc=$?"; }

NOW=$(date +%s)

# ── starts reads each form of ps's elapsed time ──────────────────────────────
setup
pane_pids %1 101 %2 102 %3 103
ps_etimes 101 05:30 102 02:03:04 103 3-04:05:06
assert_eq "$(within "$(age_of %1)" 330)" ok "starts reads mm:ss"
assert_eq "$(within "$(age_of %2)" 7384)" ok "starts reads hh:mm:ss"
assert_eq "$(within "$(age_of %3)" 273906)" ok "starts reads dd-hh:mm:ss"
teardown

# ── starts lists every live pane, or just the ones named ─────────────────────
setup
pane_pids %1 101 %2 102 %3 103
ps_etimes 101 00:10 102 00:20 103 00:30
assert_eq "$("$SCRIPT" starts | awk -F'\t' '{ print $1 }' | tr '\n' ' ')" '%1 %2 %3 ' \
  "starts with no pane lists every live pane"
assert_eq "$("$SCRIPT" starts %3 %1 | awk -F'\t' '{ print $1 }' | tr '\n' ' ')" '%1 %3 ' \
  "starts with panes lists only those"
assert_eq "$("$SCRIPT" starts %33 | wc -c | tr -d ' ')" 0 \
  "starts leaves out a pane that is not live (%33 is not %3)"
teardown

# ── a pane whose process ps cannot read has no start time ────────────────────
setup
pane_pids %1 101 %2 102
ps_etimes 101 05:30
assert_eq "$("$SCRIPT" starts | awk -F'\t' '{ print $1 }' | tr '\n' ' ')" '%1 ' \
  "starts leaves out a pane whose pid ps does not report"
teardown

# ── no tmux server means no start times ──────────────────────────────────────
setup
printf '#!/bin/sh\nexit 1\n' > "$DIR/bin/tmux"
assert_eq "$("$SCRIPT" starts 2>/dev/null; echo "rc=$?")" "rc=0" \
  "starts prints nothing and exits 0 when tmux fails"
teardown

# ── ISTATUS_TMUX_PANES stands in for tmux and ps ─────────────────────────────
setup
export ISTATUS_TMUX_PANES=$'%1\tproj\t1\t1000\n%2\tproj\t2\t\n%3\tproj\t3'
assert_eq "$("$SCRIPT" starts)" $'%1\t1000' \
  "starts takes the fourth field of ISTATUS_TMUX_PANES, and skips lines without one"
export ISTATUS_TMUX_PANES=""
assert_eq "$("$SCRIPT" starts | wc -c | tr -d ' ')" 0 \
  "starts finds no panes when ISTATUS_TMUX_PANES is set but empty"
teardown

# ── stale: a pointer older than its pane ─────────────────────────────────────
setup
export ISTATUS_TMUX_PANES=$'%1\tproj\t1\t'"$((NOW - 10))"
pointer_at %1 $((NOW - 1000))
assert_eq "$(stale_rc %1)" "rc=0" "stale exits 0 for a pointer older than its pane"
teardown

setup
export ISTATUS_TMUX_PANES=$'%1\tproj\t1\t'"$((NOW - 1000))"
pointer_at %1 $((NOW - 10))
assert_eq "$(stale_rc %1)" "rc=1" "stale exits 1 for a pointer written after its pane started"
teardown

# ps's elapsed time has one-second resolution, and a pointer is written a
# moment after its pane starts, so a pointer a second or two early is current.
setup
export ISTATUS_TMUX_PANES=$'%1\tproj\t1\t'"$((NOW - 10))"
pointer_at %1 $((NOW - 11))
assert_eq "$(stale_rc %1)" "rc=1" "stale exits 1 for a pointer one second older than its pane"
teardown

setup
export ISTATUS_TMUX_PANES=$'%1\tproj\t1\t'"$((NOW - 10))"
assert_eq "$(stale_rc %1)" "rc=1" "stale exits 1 when the pane has no pointer"
teardown

setup
export ISTATUS_TMUX_PANES=$'%1\tproj\t1\t'
pointer_at %1 $((NOW - 1000))
assert_eq "$(stale_rc %1)" "rc=1" "stale exits 1 when the pane's start time is unknown"
teardown

setup
export ISTATUS_TMUX_PANES=$'%2\tproj\t1\t'"$((NOW - 10))"
pointer_at %1 $((NOW - 1000))
assert_eq "$(stale_rc %1)" "rc=1" "stale exits 1 for a pane that is not live"
teardown

# ── stale through the real tmux and ps path ──────────────────────────────────
setup
pane_pids %1 101
ps_etimes 101 01:40
pointer_at %1 $((NOW - 1000))
assert_eq "$(stale_rc %1)" "rc=0" "stale judges a pointer against the start time ps reports"
teardown

# ── usage ────────────────────────────────────────────────────────────────────
setup
assert_eq "$("$SCRIPT" bogus >/dev/null 2>&1; echo "rc=$?")" "rc=2" "an unknown command exits 2"
assert_eq "$("$SCRIPT" stale >/dev/null 2>&1; echo "rc=$?")" "rc=1" "stale without a pane exits non-zero"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
