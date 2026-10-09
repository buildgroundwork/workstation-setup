#!/usr/bin/env bash
# Tests for istatus-float.sh, the istatus sidebar as a floating pane: toggle
# shows it collapsed or closes it, expand switches it between collapsed and
# expanded, and focus moves the keyboard into it and back.
#
# Each case runs against a real, private tmux server (its own socket, started
# with -f /dev/null so no tmux.conf or hooks load), because floating panes are
# new and a stub would hide exactly the behavior that matters, such as how a
# resize treats the tiled panes. Needs tmux 3.8 or later. TMUX points the
# script's plain `tmux` calls at that server. The sidebar really
# runs in the floating pane, against an empty scratch state dir.
# No `set -e`: a failing script must surface as a FAIL line from assert_eq.
#
# Run: claude/skills/istatus/scripts/istatus-float.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/istatus-float.sh"
DIR=""
MAIN=""
PASS=0
FAIL=0

setup() {
  DIR="$(mktemp -d)"
  export CLAUDE_TMUX_ATTENTION_DIR="$DIR/state"
  mkdir -p "$CLAUDE_TMUX_ATTENTION_DIR"
  tmux -S "$DIR/sock" -f /dev/null new-session -d -x 120 -y 40 'sleep 300'
  export TMUX="$DIR/sock,0,0"
  MAIN=$(tmux display-message -p '#{pane_id}')
}
teardown() {
  [[ -n "$DIR" ]] && tmux kill-server 2>/dev/null
  unset TMUX
  [[ -n "$DIR" && -d "$DIR" ]] && rm -rf "$DIR"
  DIR=""
}
trap teardown EXIT

# float <subcommand> <pane> — run istatus-float.sh as the key binding does,
# with the active pane as its argument.
float() { "$SCRIPT" "$1" "$2" >/dev/null 2>&1 </dev/null; }

# status_pane -> the id of the window's status pane, or nothing.
status_pane() {
  tmux list-panes -F '#{pane_id} #{@istatus_paired}' | awk '$2 != "" { print $1 }'
}

# geometry <pane> -> floating:paired:top:right-edge:height
geometry() {
  tmux display-message -p -t "$1" \
    '#{pane_floating_flag}:#{@istatus_paired}:#{pane_top}:#{e|+:#{pane_left},#{pane_width}}:#{pane_height}'
}

active() { tmux display-message -p '#{pane_id}'; }

# shape <pane> -> "collapsed" or "expanded" for a floating status pane, and
# "none" for no pane, so a missing pane cannot pass as the tiled pane.
shape() {
  [[ -n "$1" ]] || { echo none; return; }
  tmux display-message -p -t "$1" \
    '#{?#{@istatus_paired},#{?#{==:#{pane_height},1},collapsed,expanded},none}'
}

# count -> how many status panes the window has.
count() { status_pane | grep -c .; }

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

# ── toggle opens a collapsed status pane near the top-right corner ───────────
# Two cells in from the top and the right: one for its border, one for a gap.
setup
float toggle "$MAIN"
assert_eq "$(geometry "$(status_pane)")" "1:$MAIN:2:118:1" \
  "toggle opens a one-row floating pane, paired with the pane, inset from the top right"
teardown

# ── toggle leaves the keyboard with the Claude pane ──────────────────────────
setup
float toggle "$MAIN"
assert_eq "$(count):$(active)" "1:$MAIN" \
  "toggle opens the status pane without taking focus"
teardown

# ── toggle again closes it ───────────────────────────────────────────────────
setup
float toggle "$MAIN"
opened=$(count)
float toggle "$MAIN"
assert_eq "$opened:$(count)" "1:0" \
  "a second toggle closes the status pane"
teardown

# ── toggle from inside the status pane closes it ─────────────────────────────
setup
float toggle "$MAIN"
opened=$(count)
float toggle "$(status_pane)"
assert_eq "$opened:$(count)" "1:0" \
  "toggle closes the status pane when it is the active pane"
teardown

# ── expand makes it taller and leaves the Claude pane alone ──────────────────
setup
float toggle "$MAIN"
float expand "$MAIN"
fp=$(status_pane)
assert_eq "$(shape "$fp"):$(geometry "$fp" | cut -d: -f1-4):$(tmux display-message -p -t "$MAIN" '#{pane_width}x#{pane_height}')" \
  "expanded:1:$MAIN:2:118:120x40" \
  "expand grows the floating pane in place and does not resize the Claude pane"
teardown

# ── expand and collapse keep the same pane ───────────────────────────────────
# Resized in place, so the sidebar keeps running, and its view with it.
setup
float toggle "$MAIN"
before=$(status_pane)
float expand "$MAIN"
expanded=$(status_pane)
expanded_shape=$(shape "$expanded")
float expand "$MAIN"
assert_eq "$expanded_shape:$(shape "$(status_pane)"):$([[ "$expanded" == "$before" && "$(status_pane)" == "$before" ]] && echo same)" \
  "expanded:collapsed:same" \
  "expand and collapse resize the status pane in place instead of replacing it"
teardown

# ── expand again collapses it ────────────────────────────────────────────────
setup
float toggle "$MAIN"
float expand "$MAIN"
float expand "$MAIN"
assert_eq "$(count):$(shape "$(status_pane)")" "1:collapsed" \
  "a second expand collapses the status pane to one row"
teardown

# ── expand when closed opens it expanded ─────────────────────────────────────
setup
float expand "$MAIN"
assert_eq "$(shape "$(status_pane)"):$(active)" "expanded:$MAIN" \
  "expand with no status pane opens one expanded, without taking focus"
teardown

# ── focus moves into the status pane and back ────────────────────────────────
setup
float toggle "$MAIN"
fp=$(status_pane)
float focus "$MAIN"
into=$(active)
float focus "$fp"
assert_eq "$(shape "$fp"):$([[ "$into" == "$fp" ]] && echo into):$(active)" "collapsed:into:$MAIN" \
  "focus moves the keyboard into the status pane, then back to the Claude pane"
teardown

# ── focus when closed opens it expanded and focused ──────────────────────────
setup
float focus "$MAIN"
fp=$(status_pane)
assert_eq "$(shape "$fp"):$([[ "$(active)" == "$fp" ]] && echo focused)" "expanded:focused" \
  "focus with no status pane opens one expanded and moves into it"
teardown

# ── expanding a focused status pane keeps the focus in it ────────────────────
setup
float toggle "$MAIN"
float focus "$MAIN"
float expand "$(status_pane)"
fp=$(status_pane)
assert_eq "$(count):$(shape "$fp"):$([[ "$(active)" == "$fp" ]] && echo focused)" "1:expanded:focused" \
  "expand keeps the keyboard in the status pane when it had it"
teardown

# ── collapsing a focused status pane hands the keyboard to its Claude pane ───
# A third pane was active last, so a plain last-pane would land there.
setup
other=$(tmux split-window -d -P -F '#{pane_id}' -t "$MAIN" 'sleep 300')
float expand "$MAIN"
fp=$(status_pane)
tmux select-pane -t "$other"
tmux select-pane -t "$fp"
float expand "$fp"
assert_eq "$(shape "$(status_pane)"):$(active)" "collapsed:$MAIN" \
  "collapsing the status pane while it has the keyboard moves it to the Claude pane"
teardown

# ── closing a focused status pane hands the keyboard to its Claude pane ──────
setup
other=$(tmux split-window -d -P -F '#{pane_id}' -t "$MAIN" 'sleep 300')
float toggle "$MAIN"
fp=$(status_pane)
tmux select-pane -t "$other"
tmux select-pane -t "$fp"
float toggle "$fp"
assert_eq "$(count):$(active)" "0:$MAIN" \
  "closing the status pane while it has the keyboard moves it to the Claude pane"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
