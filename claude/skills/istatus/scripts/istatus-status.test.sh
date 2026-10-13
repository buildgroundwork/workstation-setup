#!/usr/bin/env bash
# Tests for istatus-status.sh — the tmux status-right segment. It counts the
# live sessions per state from istatus-inbox.sh and prints one colored block per
# non-zero state, or nothing.
# Plain bash, no framework, no deps beyond jq, a scratch state dir per case.
#
# The segment calls the real inbox, so the cases seed status files and pane
# pointers and give the inbox its pane listing through ISTATUS_TMUX_PANES. No
# `set -e`: a missing or failing script must surface as a FAIL line from
# assert_eq, not as an abort.
#
# Run: claude/skills/istatus/scripts/istatus-status.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/istatus-status.sh"
DIR=""
PASS=0
FAIL=0

setup() {
  DIR="$(mktemp -d)"
  export CLAUDE_TMUX_ATTENTION_DIR="$DIR"
  unset ISTATUS_TMUX_PANES
}
teardown() { [[ -n "$DIR" && -d "$DIR" ]] && rm -rf "$DIR"; DIR=""; }
trap teardown EXIT

# live_session <session_id> <pane> <items json> — a status file for a session
# whose pane is live and whose pointer names it.
live_session() {
  mkdir -p "$DIR/status" "$DIR/panes"
  printf '{"summary":"","pane":"%s","items":%s}' "$2" "$3" > "$DIR/status/$1.json"
  printf '%s' "$1" > "$DIR/panes/$2.session_id"
}

BLOCKING='[{"id":"b1","kind":"blocking","text":"needs approval","source":"","state":"unread","created_at":"2026-10-06T00:00:00Z"}]'

# segment_output -> what the segment prints, stderr dropped and stdin closed.
segment_output() { "$SCRIPT" 2>/dev/null </dev/null; }

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

# ── one blocked session shows one red block ──────────────────────────────────
setup
live_session sess-1 %42 "$BLOCKING"
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(segment_output)" '#[fg=black,bg=red,bold] 󰜌 1 #[default] ' \
  "a blocked session shows a red block with its count"
teardown

# ── nothing actionable prints nothing ────────────────────────────────────────
setup
live_session sess-1 %42 '[{"id":"n1","kind":"notice","text":"pick a name","state":"read","priority":"normal","created_at":"2026-10-06T00:00:00Z"}]'
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(segment_output)" '' \
  "a session with nothing actionable shows nothing"
teardown

# ── an unread decide notice shows a magenta block after the red one ──────────
setup
live_session sess-1 %42 "$BLOCKING"
live_session sess-2 %43 '[{"id":"n1","kind":"notice","text":"pick a name","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"}]'
export ISTATUS_TMUX_PANES=$'%42\tproj\t3\n%43\tproj\t4'
assert_eq "$(segment_output)" '#[fg=black,bg=red,bold] 󰜌 1 #[default] #[fg=black,bg=magenta,bold] 󰀎 1 #[default] ' \
  "blocked and flagged sessions show two blocks in precedence order"
teardown

# ── a finished dispatch shows a yellow block ─────────────────────────────────
setup
live_session sess-1 %42 '[{"id":"r1","kind":"notice","text":"run the migration","source":"hub.ready","state":"unread","priority":"normal","created_at":"2026-10-06T00:00:00Z"}]'
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(segment_output)" '#[fg=black,bg=yellow,bold] 󰂟 1 #[default] ' \
  "a ready session shows a yellow block"
teardown

# ── a segment's colors and glyph can be overridden ───────────────────────────
setup
live_session sess-1 %42 "$BLOCKING"
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(ISTATUS_BLOCKED_FG=white ISTATUS_BLOCKED_BG=green ISTATUS_BLOCKED_GLYPH='!' segment_output)" \
  '#[fg=white,bg=green,bold] ! 1 #[default] ' \
  "a segment takes its colors and glyph from ISTATUS_<STATE> variables"
teardown

# ── a failure shows nothing and exits 0 ──────────────────────────────────────
# With jq off the PATH the status line's counting fails; a status-line script
# must never print junk or return an error.
setup
live_session sess-1 %42 "$BLOCKING"
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
mkdir "$DIR/bin"
ln -s "$(command -v dirname)" "$DIR/bin/dirname"
assert_eq "$(PATH="$DIR/bin" "$SCRIPT" 2>/dev/null </dev/null; echo "rc=$?")" "rc=0" \
  "a failure to count prints nothing and exits 0"
teardown

# ── a dispatch still working shows a blue block ──────────────────────────────
setup
live_session sess-1 %42 '[{"id":"d1","kind":"notice","text":"run the migration","source":"hub.dispatched","state":"read","priority":"low","created_at":"2026-10-06T00:00:00Z"}]'
export ISTATUS_TMUX_PANES=$'%42\tproj\t3'
assert_eq "$(segment_output)" '#[fg=black,bg=blue,bold] 󱐋 1 #[default] ' \
  "a dispatched session shows a blue block"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
