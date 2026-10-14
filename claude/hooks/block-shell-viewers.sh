#!/bin/bash
# PreToolUse hook: deny Bash calls that use sed/cat/head/tail to view or edit
# a WORKING-TREE file. Read/Edit are strictly better for this: they're tracked
# by the harness (so Edit can verify old_string against known content, and
# later tool calls know "file state is current"), they show a real diff, and
# Edit fails loudly on an ambiguous match instead of sed's silent whole-file
# substitution. This hook exists because the same rule stated in CLAUDE.md
# wasn't sufficient on its own — advisory text competes with in-the-moment
# task pressure and loses often enough to matter; a hard block doesn't.
#
# What it tells apart is whether the command reads a FILE or a STREAM:
#
#   - In command position (the start of the command line, or after ;, &&,
#     ||, & or a newline), sed/cat/head/tail read the file named on the
#     command line. That's a file view, or with `cat >` a shell write, and
#     is denied.
#   - After a single `|`, head/tail/sed filter the previous command's output
#     (`git log | head`, `tmux list-panes | tail -1`, `cmd | sed 's/x/y/'`).
#     There's no file for Read to read, so these are allowed. `cat file |
#     head` is still denied, on the cat.
#   - `sed -i` / `sed --in-place` edits a file in place, so it's denied
#     wherever sed can run as a command: command position, after a pipe, or
#     behind xargs. Not as bare words mid-line, so a commit message or
#     heredoc that mentions sed -i in prose still goes through.
#
# Known gap, on purpose: `: | head file` sneaks a file read in after a pipe.
# Catching it means parsing each command's arguments; the deny message tells
# the model not to route around the hook, which covers a deliberate dodge.
#
# Deliberately does NOT cover `git show <ref>:<path>`. That command reads a
# file's content AS OF another commit/branch without touching the working
# tree — Read can't do that at all (it only sees what's on disk), and the
# real alternative (checkout the ref, Read, then presumably switch back) is
# heavier and riskier than the read-only `git show`, not safer.
#
# Matches the named commands as actual command words, not as substrings
# anywhere in the command line — so a string literal or filename containing
# "cat" doesn't false-positive. Deliberately narrow: only the file-viewer
# commands this rule is about, not a general command blocklist.
#
# Tests: claude/hooks/block-shell-viewers.test.sh

payload=$(cat)
command=$(jq -r '.tool_input.command // ""' <<<"$payload")

[[ -z "$command" ]] && exit 0

nl=$'\n'
command_position="(^|[;&${nl}]|\|\|)[[:space:]]*(sed|cat|head|tail)([[:space:]]|$)"
in_place_sed="(^|[;&|${nl}]|xargs([[:space:]]+-[^[:space:]]+)*)[[:space:]]*sed[[:space:]]([^;&|${nl}]*[[:space:]])?(-[[:alpha:]]*i|--in-place)"

if [[ "$command" =~ $command_position || "$command" =~ $in_place_sed ]]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Use the Read tool to view working-tree files, not sed/cat/head/tail on a file. Read is tracked by the harness (Edit can verify old_string against it, later calls know file state is current) and handles large files with pagination. If you need to EDIT a file, use the Edit tool, not sed -i: Edit requires an exact unique match and shows a real diff, while sed -i can silently over-match and writes outside the harness'\''s tracking. To WRITE a file, use the Write tool, not cat > file. (Filtering another command'\''s output after a pipe, like `git log | head` or `cmd | sed s/x/y/`, is fine and NOT blocked, and neither is git show <ref>:<path>.) If this specific command genuinely cannot be expressed via Read/Edit (e.g. a multi-line regex substitution Edit'\''s exact-string model cannot express), explain why to the user and ask them to approve it manually rather than retrying to route around this hook."
    }
  }'
  exit 0
fi

exit 0
