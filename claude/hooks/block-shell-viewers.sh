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

payload=$(cat)
command=$(jq -r '.tool_input.command // ""' <<<"$payload")

[[ -z "$command" ]] && exit 0

# Tried against the start of the command and after each shell separator.
pattern='(^|[;&|]+[[:space:]]*)(sed|cat|head|tail)([[:space:]]|$)'

if [[ "$command" =~ $pattern ]]; then
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
