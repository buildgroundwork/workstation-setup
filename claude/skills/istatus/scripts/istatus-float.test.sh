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
  # The sidebar fits its pane to its content on its own, which would race the
  # cases that check sizes; the cases about fitting turn it back on.
  export ISTATUS_SIDEBAR_FIT=0
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

# float <subcommand> <pane> [arg] — run istatus-float.sh as the key binding
# does, with the active pane as its argument.
float() { "$SCRIPT" "$@" >/dev/null 2>&1 </dev/null; }

# wait_height <pane> <rows> — waits up to four seconds for the pane to reach
# that height, for the sidebar's own refresh, which polls once a second.
wait_height() {
  local i
  for i in $(seq 1 40); do
    [[ "$(tmux display-message -p -t "$1" '#{pane_height}')" == "$2" ]] && return 0
    sleep 0.1
  done
  return 0
}

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

# ── side by side, each pane's status pane sits in that pane's corner ─────────
# Placed by the window's corner, both would land on top of each other.
setup
right=$(tmux split-window -h -d -P -F '#{pane_id}' -t "$MAIN" 'sleep 300')
float toggle "$MAIN"
float toggle "$right"
left_edge=$(tmux display-message -p -t "$MAIN" '#{e|-:#{e|+:#{pane_left},#{pane_width}},2}')
assert_eq "$(tmux list-panes -F '#{@istatus_paired}:#{pane_top}:#{e|+:#{pane_left},#{pane_width}}' | grep -v '^:' | sort)" \
  "$(printf '%s\n' "$MAIN:2:$left_edge" "$right:2:118" | sort)" \
  "toggle in each of two side-by-side panes opens a status pane in that pane's top-right corner"
teardown

# ── stacked, the lower pane's status pane sits below the top of its pane ─────
setup
lower=$(tmux split-window -v -d -P -F '#{pane_id}' -t "$MAIN" 'sleep 300')
float expand "$lower"
lower_top=$(tmux display-message -p -t "$lower" '#{e|+:#{pane_top},2}')
lower_bottom=$(tmux display-message -p -t "$lower" '#{e|+:#{pane_top},#{pane_height}}')
fp_top=$(tmux display-message -p -t "$(status_pane)" '#{pane_top}')
fp_bottom=$(tmux display-message -p -t "$(status_pane)" '#{e|+:#{pane_top},#{pane_height}}')
assert_eq "$fp_top:$(( fp_bottom < lower_bottom ))" "$lower_top:1" \
  "expand in the lower of two stacked panes keeps the status pane inside that pane"
teardown

# ── relayout puts it back in its corner after the window shrinks and regrows ─
# The window-resized and window-layout-changed hooks run relayout for the
# window; these cases call it directly, as the hooks do.
setup
float toggle "$MAIN"
tmux resize-window -x 60 -y 20
tmux resize-window -x 120 -y 40
float relayout "$(tmux display-message -p -t "$MAIN" '#{window_id}')"
assert_eq "$(geometry "$(status_pane)")" "1:$MAIN:2:118:1" \
  "relayout moves the status pane back to its pane's corner after a resize"
teardown

# ── relayout follows the pane when a split makes it narrower ─────────────────
setup
float toggle "$MAIN"
tmux split-window -h -d -t "$MAIN" 'sleep 300'
float relayout "$(tmux display-message -p -t "$MAIN" '#{window_id}')"
want_edge=$(tmux display-message -p -t "$MAIN" '#{e|-:#{e|+:#{pane_left},#{pane_width}},2}')
assert_eq "$(geometry "$(status_pane)")" "1:$MAIN:2:$want_edge:1" \
  "relayout moves the status pane into its pane's new corner after a split"
teardown

# ── relayout follows the pane when it swaps places ───────────────────────────
setup
right=$(tmux split-window -h -d -P -F '#{pane_id}' -t "$MAIN" 'sleep 300')
float toggle "$MAIN"
tmux swap-pane -d -s "$MAIN" -t "$right"
float relayout "$(tmux display-message -p -t "$MAIN" '#{window_id}')"
assert_eq "$(geometry "$(status_pane)")" "1:$MAIN:2:118:1" \
  "relayout moves the status pane with its pane after a swap"
teardown

# ── relayout keeps an expanded status pane expanded ──────────────────────────
setup
float expand "$MAIN"
tmux split-window -h -d -t "$MAIN" 'sleep 300'
float relayout "$(tmux display-message -p -t "$MAIN" '#{window_id}')"
want_edge=$(tmux display-message -p -t "$MAIN" '#{e|-:#{e|+:#{pane_left},#{pane_width}},2}')
assert_eq "$(shape "$(status_pane)"):$(geometry "$(status_pane)" | cut -d: -f4)" "expanded:$want_edge" \
  "relayout keeps the status pane's shape as it moves it"
teardown

# ── relayout leaves a status pane that is already in place alone ─────────────
# Moving a floating pane fires window-layout-changed, so the hook runs relayout
# again after every move it makes. That run must change nothing, or it loops.
setup
float toggle "$MAIN"
fp=$(status_pane)
: > "$DIR/layout"
tmux set-hook -g window-layout-changed "run-shell 'echo x >> $DIR/layout'"
float relayout "$(tmux display-message -p -t "$MAIN" '#{window_id}')"
sleep 0.3
assert_eq "$(status_pane):$(wc -c < "$DIR/layout" | tr -d ' ')" "$fp:0" \
  "relayout does not touch a status pane that is already where it belongs"
teardown

# ── relayout moves the status pane to the window its pane moved to ───────────
setup
float expand "$MAIN"
old_window=$(tmux display-message -p -t "$MAIN" '#{window_id}')
new_window=$(tmux new-window -d -P -F '#{window_id}' 'sleep 300')
tmux move-pane -d -s "$MAIN" -t "$new_window"
float relayout "$old_window"
fp=$(tmux list-panes -a -F '#{pane_id} #{@istatus_paired}' | awk -v p="$MAIN" '$2 == p { print $1 }')
want_edge=$(tmux display-message -p -t "$MAIN" '#{e|-:#{e|+:#{pane_left},#{pane_width}},2}')
assert_eq "$(tmux display-message -p -t "$fp" '#{window_id}'):$(shape "$fp"):$(geometry "$fp" | cut -d: -f1-2,4)" \
  "$new_window:expanded:1:$MAIN:$want_edge" \
  "relayout moves the status pane, still expanded, into its pane's new window"
teardown

# ── relayout closes a status pane whose Claude pane is gone ──────────────────
setup
other=$(tmux split-window -h -d -P -F '#{pane_id}' -t "$MAIN" 'sleep 300')
float toggle "$MAIN"
window=$(tmux display-message -p -t "$MAIN" '#{window_id}')
tmux kill-pane -t "$MAIN"
float relayout "$window"
assert_eq "$(tmux list-panes -t "$window" -F '#{pane_id}' | tr '\n' ' ')" "$other " \
  "relayout closes the status pane when its Claude pane has closed"
teardown

# ── fit sizes an expanded status pane to its content ─────────────────────────
# The sidebar asks for the rows its content needs; the pane keeps its top and
# right edge, so it grows and shrinks downward from its corner.
setup
float expand "$MAIN"
fp=$(status_pane)
float fit "$fp" 10
assert_eq "$(geometry "$fp")" "1:$MAIN:2:118:10" \
  "fit resizes an expanded status pane to the rows asked for, in place"
teardown

# ── fit never goes below three rows ──────────────────────────────────────────
# Two rows or fewer is what the sidebar takes for a collapsed pane.
setup
float expand "$MAIN"
fp=$(status_pane)
float fit "$fp" 1
assert_eq "$(tmux display-message -p -t "$fp" '#{pane_height}')" "3" \
  "fit keeps an expanded status pane at three rows or more"
teardown

# ── fit never goes past two thirds of the Claude pane ────────────────────────
# Beyond that the list scrolls. Two thirds of 40 rows is 26.
setup
float expand "$MAIN"
fp=$(status_pane)
float fit "$fp" 99
assert_eq "$(tmux display-message -p -t "$fp" '#{pane_height}')" "26" \
  "fit stops an expanded status pane at two thirds of its Claude pane"
teardown

# ── fit on a collapsed pane waits for the next expand ────────────────────────
setup
float toggle "$MAIN"
fp=$(status_pane)
float fit "$fp" 10
collapsed=$(tmux display-message -p -t "$fp" '#{pane_height}')
float expand "$MAIN"
assert_eq "$collapsed:$(tmux display-message -p -t "$fp" '#{pane_height}')" "1:10" \
  "fit leaves a collapsed status pane collapsed and the next expand uses the rows"
teardown

# ── relayout keeps a fitted status pane at its fitted height ─────────────────
# Otherwise relayout would snap it back to two thirds, and the sidebar would
# fit it again, on every layout change.
setup
float expand "$MAIN"
fp=$(status_pane)
float fit "$fp" 10
float relayout "$(tmux display-message -p -t "$MAIN" '#{window_id}')"
assert_eq "$(tmux display-message -p -t "$fp" '#{pane_height}')" "10" \
  "relayout leaves a fitted status pane at its height"
teardown

# ── relayout fits the height again to a new Claude pane size ─────────────────
setup
float expand "$MAIN"
fp=$(status_pane)
float fit "$fp" 20
tmux resize-window -x 120 -y 15
float relayout "$(tmux display-message -p -t "$MAIN" '#{window_id}')"
assert_eq "$(tmux display-message -p -t "$fp" '#{pane_height}')" "10" \
  "relayout caps a fitted status pane at two thirds of a shrunken Claude pane"
teardown

# ── fit on a pane that is not a status pane does nothing ─────────────────────
setup
float fit "$MAIN" 10
assert_eq "$(tmux display-message -p -t "$MAIN" '#{pane_height}'):$(count)" "40:0" \
  "fit leaves an ordinary pane alone"
teardown

# ── the sidebar fits its own pane to its content ─────────────────────────────
# End to end, with the real sidebar and a session seeded in its state dir.
setup
tmux set-environment -g ISTATUS_SIDEBAR_FIT 1
mkdir -p "$CLAUDE_TMUX_ATTENTION_DIR/panes" "$CLAUDE_TMUX_ATTENTION_DIR/status"
printf '%s' s1 > "$CLAUDE_TMUX_ATTENTION_DIR/panes/$MAIN.session_id"
notices() {
  jq -nc --argjson n "$1" '{summary: "short", items: [range($n) | {id: "n\(.)", kind: "notice", text: "item \(.)", state: "unread", priority: "normal", created_at: "2026-10-16T00:00:00Z"}]}' \
    > "$CLAUDE_TMUX_ATTENTION_DIR/status/s1.json"
}
notices 1
float expand "$MAIN"
fp=$(status_pane)
wait_height "$fp" 9
small=$(tmux display-message -p -t "$fp" '#{pane_height}')
notices 6
wait_height "$fp" $(( small + 5 ))
assert_eq "$(( $(tmux display-message -p -t "$fp" '#{pane_height}') - small ))" "5" \
  "the sidebar grows its pane by a row for each line of content that arrives"
assert_eq "$(( small < 26 ))" "1" \
  "the sidebar sizes a short list well under the two-thirds cap"
teardown

# ── show opens the status pane, expanded, when there is none ─────────────────
# For a jump from the attention popup: the jump is about what the session
# wants, so the list is open, and it does not take the keyboard.
setup
float show "$MAIN"
fp=$(status_pane)
assert_eq "$(count):$(shape "$fp"):$(geometry "$fp" | cut -d: -f1-2):$(active)" "1:expanded:1:$MAIN:$MAIN" \
  "show opens an expanded floating status pane for the pane, without taking focus"
teardown

# ── show leaves a status pane that is already open as it is ──────────────────
# Unlike toggle, which would close it.
setup
float toggle "$MAIN"
float show "$MAIN"
assert_eq "$(count):$(shape "$(status_pane)")" "1:collapsed" \
  "show leaves a collapsed status pane collapsed"
teardown

setup
float expand "$MAIN"
fp=$(status_pane)
float show "$MAIN"
assert_eq "$(count):$(status_pane):$(shape "$fp")" "1:$fp:expanded" \
  "show leaves an expanded status pane open, the same pane"
teardown

# ── show works on a Claude pane in a window that is not showing ──────────────
setup
other=$(tmux new-window -d -P -F '#{pane_id}' 'sleep 300')
float show "$other"
assert_eq "$(tmux list-panes -t "$other" -F '#{pane_floating_flag}:#{@istatus_paired}' | grep -c "^1:$other\$"):$(active)" "1:$MAIN" \
  "show opens a status pane in another window without switching to it"
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
