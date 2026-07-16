#!/bin/bash
# PreToolUse hook: deny Bash calls that shell out to sed/cat/head/tail for
# viewing or editing WORKING-TREE files. Read/Edit are strictly better for
# this: they're tracked by the harness (so Edit can verify old_string against
# known content, and later tool calls know "file state is current"), they
# show a real diff, and Edit fails loudly on an ambiguous match instead of
# sed's silent whole-file substitution. This hook exists because the same
# rule stated in CLAUDE.md wasn't sufficient on its own — advisory text
# competes with in-the-moment task pressure and loses often enough to matter;
# a hard block doesn't.
#
# Deliberately does NOT cover `git show <ref>:<path>`. That command reads a
# file's content AS OF another commit/branch without touching the working
# tree — Read can't do that at all (it only sees what's on disk), and the
# real alternative (checkout the ref, Read, then presumably switch back) is
# heavier and riskier than the read-only `git show`, not safer. So git show
# is a genuinely different case, not a Read substitute to route around.
#
# Matches the named commands as actual command words (start of string, or
# after ;/&&/||/| separators), not as substrings anywhere in the command line
# — so a string literal or filename containing "cat" doesn't false-positive.
# Deliberately narrow: only the working-tree-viewer commands this rule is
# about, not a general command blocklist.
#
# Carve-out: `grep ... | head` / `grep ... | tail` is exempt. There's no
# built-in Grep tool in this session to redirect to (grep/glob are absent —
# a known Claude Code bug when ENABLE_TOOL_SEARCH is on, they're neither in
# the active tool set nor discoverable via ToolSearch:
# https://github.com/anthropics/claude-code/issues/63525), so grep itself is
# not blocked here. Given that, `head`/`tail` immediately after a `grep`
# pipe is paginating SEARCH RESULTS, not viewing a file — Read has no way
# to bound grep's output, so blocking this would leave no way to do it at
# all, not redirect to something better (unlike `cat file | head`, which
# still is a plain file view and stays blocked, since `cat` is caught first).

payload=$(cat)
command=$(jq -r '.tool_input.command // ""' <<<"$payload")

[[ -z "$command" ]] && exit 0

# Strip out any `grep|egrep|fgrep ... | head` / `| tail` segment before
# testing — that specific head/tail is exempt (see comment above). Whatever
# is LEFT is tested against the normal sed/cat/head/tail pattern, so an
# unrelated sed/cat/head/tail elsewhere in the same command is still caught
# (e.g. `sed -n foo; grep bar | head` still denies on the sed).
scrubbed="$command"
grep_pipe_pattern='(e|f)?grep[^|;&]*\|[[:space:]]*(head|tail)([[:space:]]|$)'
while [[ "$scrubbed" =~ $grep_pipe_pattern ]]; do
  scrubbed="${scrubbed/${BASH_REMATCH[0]}/}"
done

pattern='(^|[;&|]+[[:space:]]*)(sed|cat|head|tail)([[:space:]]|$)'

if [[ "$scrubbed" =~ $pattern ]]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Use the Read tool to view working-tree files, not sed/cat/head/tail. Read is tracked by the harness (Edit can verify old_string against it, later calls know file state is current) and handles large files with pagination. If you need to EDIT a file, use the Edit tool, not sed -i: Edit requires an exact unique match and shows a real diff, while sed -i can silently over-match and writes outside the harness'\''s tracking. (git show <ref>:<path> is fine and NOT blocked by this hook — it reads another commit/branch'\''s content without touching the working tree, which Read cannot do.) If this specific command genuinely cannot be expressed via Read/Edit (e.g. a multi-line regex substitution Edit'\''s exact-string model cannot express), explain why to the user and ask them to approve it manually rather than retrying to route around this hook."
    }
  }'
  exit 0
fi

exit 0
