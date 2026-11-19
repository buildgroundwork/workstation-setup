#!/usr/bin/env bash
# Tests for compact-handoff.sh, the hook pair that carries state across a
# compaction: `pre` (PreCompact) writes what a summary tends to lose to a file
# and prints instructions for the summarizer, and `inject` (SessionStart,
# matcher "compact") returns that file as context for the compacted session.
#
# Each case feeds the hook a payload on stdin, as Claude Code does. HANDOFF_DIR
# and CLAUDE_TMUX_ATTENTION_DIR point at a scratch directory per case. No `set
# -e`: a failing hook must surface as a FAIL line from assert_eq.
#
# Run: claude/hooks/compact-handoff.test.sh

set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/compact-handoff.sh"
PASS=0
FAIL=0
ROOT=""

setup() {
  ROOT="$(mktemp -d)"
  export HANDOFF_DIR="$ROOT/handoffs"
  export CLAUDE_TMUX_ATTENTION_DIR="$ROOT/attention"
  mkdir -p "$ROOT/attention/status"
}
teardown() { [[ -n "$ROOT" && -d "$ROOT" ]] && rm -rf "$ROOT"; ROOT=""; }
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

# assert_contains <haystack> <needle> <label>
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then
    echo "PASS: $3"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $3 (missing [$2] in [$1])"
    FAIL=$((FAIL + 1))
  fi
}

# payload <session_id> <cwd> [trigger] [custom_instructions] -> hook JSON.
payload() {
  jq -nc --arg s "$1" --arg c "$2" --arg t "${3:-manual}" --arg i "${4:-}" \
    '{session_id: $s, cwd: $c, transcript_path: "/t/transcript.jsonl", hook_event_name: "PreCompact", trigger: $t, custom_instructions: (if $i == "" then null else $i end)}'
}

# repo <dir> — a git repo on branch work, with an upstream that is one commit
# behind the local branch and a dirty file.
repo() {
  git init -q --bare "$1.git"
  git init -q -b work "$1"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name Tester
  git -C "$1" remote add origin "$1.git"
  echo one >"$1/a.txt"
  git -C "$1" add a.txt
  git -C "$1" commit -q -m "First commit"
  git -C "$1" push -q -u origin work 2>/dev/null
  echo two >>"$1/a.txt"
  git -C "$1" commit -q -am "Unpushed commit"
  echo scratch >"$1/dirty.txt"
}

# ── pre records the git state a summary tends to lose ────────────────────────
setup
repo "$ROOT/proj"
payload sess-1 "$ROOT/proj" | "$HOOK" pre >/dev/null
file="$(<"$HANDOFF_DIR/sess-1.md")"
assert_contains "$file" "work" "pre records the branch"
assert_contains "$file" "dirty.txt" "pre records an uncommitted file"
assert_contains "$file" "Unpushed commit" "pre records an unpushed commit"
assert_contains "$file" "/t/transcript.jsonl" "pre records the transcript path"
teardown

# ── pre tolerates a directory that is not a git repository ───────────────────
setup
mkdir "$ROOT/plain"
payload sess-1 "$ROOT/plain" | "$HOOK" pre >/dev/null
assert_eq "$?" "0" "pre exits 0 outside a git repository"
assert_contains "$(<"$HANDOFF_DIR/sess-1.md")" "not a git repository" \
  "pre says so outside a git repository"
teardown

# ── pre records the session's istatus summary and open items ─────────────────
setup
mkdir "$ROOT/plain"
cat >"$ROOT/attention/status/sess-1.json" <<'EOF'
{"summary":"Working on the hook","items":[
  {"id":"n1","kind":"blocking","text":"needs your go","state":"unread"},
  {"id":"n2","kind":"notice","text":"pushed main","state":"read"}]}
EOF
payload sess-1 "$ROOT/plain" | "$HOOK" pre >/dev/null
file="$(<"$HANDOFF_DIR/sess-1.md")"
assert_contains "$file" "Working on the hook" "pre records the istatus summary"
assert_contains "$file" "[blocking] needs your go" "pre records an open item"
teardown

# ── pre notes when the session has no istatus state ──────────────────────────
setup
mkdir "$ROOT/plain"
payload sess-1 "$ROOT/plain" | "$HOOK" pre >/dev/null
assert_contains "$(<"$HANDOFF_DIR/sess-1.md")" "no istatus state" \
  "pre says so when there is no istatus state"
teardown

# ── pre prints instructions for the summarizer, within the stdout cap ────────
setup
mkdir "$ROOT/plain"
out="$(payload sess-1 "$ROOT/plain" auto | "$HOOK" pre)"
assert_contains "$out" "uncommitted" "pre tells the summarizer to keep uncommitted work"
assert_contains "$out" "$HANDOFF_DIR/sess-1.md" "pre names the handoff file"
assert_eq "$([[ ${#out} -lt 10000 ]] && echo under)" under "pre stdout stays under the 10,000-character cap"
teardown

# ── pre repeats the user's /compact focus ────────────────────────────────────
setup
mkdir "$ROOT/plain"
out="$(payload sess-1 "$ROOT/plain" manual "keep the hook design" | "$HOOK" pre)"
assert_contains "$out" "keep the hook design" "pre repeats the user's /compact focus"
teardown

# ── pre never blocks or breaks a compaction ──────────────────────────────────
setup
out="$(printf 'not json' | "$HOOK" pre)"
assert_eq "$?:$out:$([[ -d "$HANDOFF_DIR" ]] && echo made || echo none)" "0::none" \
  "pre ignores a malformed payload"
out="$(payload "" "$ROOT" | "$HOOK" pre)"
assert_eq "$?:$([[ -d "$HANDOFF_DIR" ]] && echo made || echo none)" "0:none" \
  "pre writes nothing without a session id"
out="$(payload sess-1 "$ROOT/missing" | "$HOOK" pre >/dev/null; echo "$?")"
assert_eq "$out" "0" "pre exits 0 for a directory that does not exist"
teardown

# ── pre overwrites an earlier handoff for the same session ───────────────────
setup
mkdir "$ROOT/plain"
mkdir -p "$HANDOFF_DIR"
echo stale >"$HANDOFF_DIR/sess-1.md"
payload sess-1 "$ROOT/plain" | "$HOOK" pre >/dev/null
assert_eq "$(grep -c stale "$HANDOFF_DIR/sess-1.md")" "0" "pre replaces the earlier handoff"
teardown

# ── inject returns the handoff as SessionStart context ───────────────────────
setup
repo "$ROOT/proj"
payload sess-1 "$ROOT/proj" | "$HOOK" pre >/dev/null
out="$(jq -nc '{session_id: "sess-1", hook_event_name: "SessionStart", source: "compact"}' | "$HOOK" inject)"
assert_eq "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" SessionStart \
  "inject answers as a SessionStart hook"
assert_contains "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")" "dirty.txt" \
  "inject returns the saved git state"
assert_contains "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")" "$HANDOFF_DIR/sess-1.md" \
  "inject names the handoff file"
teardown

# ── inject says nothing when there is no handoff to return ───────────────────
setup
out="$(jq -nc '{session_id: "sess-1", source: "compact"}' | "$HOOK" inject)"
assert_eq "$?:$out" "0:" "inject prints nothing without a handoff file"
out="$(printf 'not json' | "$HOOK" inject)"
assert_eq "$?:$out" "0:" "inject ignores a malformed payload"
teardown

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
