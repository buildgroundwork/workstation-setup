#!/usr/bin/env bash
# Tests for block-shell-viewers.sh, the PreToolUse hook that denies sed, cat,
# head and tail used to view or edit a file, and allows them as filters on
# another command's output.
#
# Each case feeds the hook a Bash tool payload on stdin, as Claude Code does,
# and reads its verdict: "deny" when it prints a deny decision, "allow" when it
# prints nothing. No `set -e`: a failing hook must surface as a FAIL line from
# assert_eq.
#
# Run: claude/hooks/block-shell-viewers.test.sh

set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-shell-viewers.sh"
PASS=0
FAIL=0

# verdict <command> -> "deny" or "allow" for that Bash command.
verdict() {
  local out
  out=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | "$HOOK")
  if [[ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" == deny ]]; then
    echo deny
  else
    echo allow
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

# ── a viewer in command position reads a file: denied ────────────────────────
assert_eq "$(verdict 'cat README.md')" deny "cat of a file is denied"
assert_eq "$(verdict 'head -20 lib/foo.rb')" deny "head of a file is denied"
assert_eq "$(verdict 'tail -n 50 log/test.log')" deny "tail of a file is denied"
assert_eq "$(verdict "sed -n '1,20p' lib/foo.rb")" deny "sed printing a file is denied"
assert_eq "$(verdict 'tail -f log/development.log')" deny "tail -f of a file is denied"

# ── after a separator it is still in command position: denied ────────────────
assert_eq "$(verdict 'cd lib && cat foo.rb')" deny "cat after && is denied"
assert_eq "$(verdict 'true; head foo.rb')" deny "head after ; is denied"
assert_eq "$(verdict 'false || tail foo.rb')" deny "tail after || is denied"
assert_eq "$(verdict 'sleep 1 & cat foo.rb')" deny "cat after & is denied"

# ── cat feeding a pipe is still a file view: denied ──────────────────────────
assert_eq "$(verdict 'cat foo.rb | head')" deny "cat of a file piped to head is denied"

# ── cat writing a file is a shell write: denied ──────────────────────────────
assert_eq "$(verdict 'cat > foo.rb <<EOF
x
EOF')" deny "cat writing a heredoc to a file is denied"

# ── sed -i edits a file wherever it appears: denied ──────────────────────────
assert_eq "$(verdict "sed -i '' 's/a/b/' foo.rb")" deny "sed -i in command position is denied"
assert_eq "$(verdict "git ls-files | xargs sed -i 's/a/b/'")" deny "sed -i behind xargs is denied"
assert_eq "$(verdict "ls | sed -i 's/a/b/' foo.rb")" deny "sed -i after a pipe is denied"
assert_eq "$(verdict "sed --in-place 's/a/b/' foo.rb")" deny "sed --in-place is denied"

# ── a filter after a pipe reads the command's output: allowed ────────────────
assert_eq "$(verdict 'git log --oneline | head -20')" allow "head on git log output is allowed"
assert_eq "$(verdict 'tmux list-panes | tail -1')" allow "tail on tmux output is allowed"
assert_eq "$(verdict "jq . foo.json | head")" allow "head on jq output is allowed"
assert_eq "$(verdict "git log | sed 's/^/  /'")" allow "sed rewriting a command's output is allowed"
assert_eq "$(verdict 'grep -rn foo . | sort | head')" allow "head after grep and sort is allowed"
assert_eq "$(verdict 'grep -rn foo . | head -5')" allow "head straight after grep is allowed"
assert_eq "$(verdict 'git show main:lib/foo.rb | head -40')" allow "head on git show output is allowed"

# ── the names inside other words or arguments: allowed ───────────────────────
assert_eq "$(verdict 'git log --grep=cat')" allow "cat inside an argument is allowed"
assert_eq "$(verdict 'ls concatenate/')" allow "cat inside a path is allowed"
assert_eq "$(verdict 'bin/rspec spec/head_spec.rb')" allow "head inside a filename is allowed"
assert_eq "$(verdict "git commit -F - <<'EOF'
Deny sed -i anywhere, which closes the gap of sed -i behind xargs
EOF")" allow "sed -i mentioned in prose is allowed"
assert_eq "$(verdict 'payload=$(cat)')" allow "cat reading stdin in a substitution is allowed"

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
