#!/usr/bin/env bash
# Tests for attention-doctor.sh's core decision: are a session's hooks still
# firing? Every istatus hook event touches heartbeat/<session_id>, and istatus.sh
# never does, so a session whose transcript has moved on well past its last
# heartbeat, or that has no heartbeat at all, has hooks that are not firing. The
# per-project loop (tmuxinator configs, transcripts, tmux) needs a live machine
# and is checked by hand.
#
# The script is sourced in a subshell, because it turns on strict options. No
# `set -e` here: a failing lookup must show as a FAIL line from assert_eq.
#
# Run: claude/skills/hub/scripts/attention-doctor.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/attention-doctor.sh"
DIR=""
PASS=0
FAIL=0
NOW=$(date +%s)

setup() {
  DIR="$(mktemp -d)"
  export CLAUDE_TMUX_ATTENTION_DIR="$DIR"
  mkdir -p "$DIR/heartbeat"
}
teardown() { [[ -n "$DIR" && -d "$DIR" ]] && rm -rf "$DIR"; DIR=""; }
trap teardown EXIT

# heartbeat <session_id> <seconds before NOW> — a heartbeat last touched then.
heartbeat() {
  : > "$DIR/heartbeat/$1"
  touch -t "$(date -r $((NOW - $2)) +%Y%m%d%H%M.%S)" "$DIR/heartbeat/$1"
}

# verdict <session_id> <seconds before NOW the transcript was last written>
# -> alive or dead, per hooks_alive.
verdict() {
  if ( source "$SCRIPT"; hooks_alive "$1" $((NOW - $2)) ) 2>/dev/null </dev/null; then
    echo alive
  else
    echo dead
  fi
}

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

# ── a heartbeat close to the transcript's last write is alive ────────────────
setup
heartbeat sess-1 70
assert_eq "$(verdict sess-1 60)" "alive" \
  "a heartbeat within the allowed lag of the transcript is alive"
teardown

# ── a heartbeat far behind the transcript is dead ────────────────────────────
# The mid-session drop: the transcript keeps moving, the hooks stopped.
setup
heartbeat sess-1 2000
assert_eq "$(verdict sess-1 60)" "dead" \
  "a heartbeat long before the transcript's last write is dead"
teardown

# ── no heartbeat at all is dead ──────────────────────────────────────────────
setup
assert_eq "$(verdict sess-1 60)" "dead" \
  "a session with no heartbeat is dead"
teardown

# ── a heartbeat after the transcript's last write is alive ───────────────────
setup
heartbeat sess-1 10
assert_eq "$(verdict sess-1 60)" "alive" \
  "a heartbeat newer than the transcript is alive"
teardown

# ── only the session's own heartbeat counts ──────────────────────────────────
setup
heartbeat sess-other 10
assert_eq "$(verdict sess-1 60)" "dead" \
  "another session's heartbeat does not count"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
