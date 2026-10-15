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
# Heredoc bodies are stripped before any of that is checked (see
# strip_heredoc_bodies): a line inside a body that starts with "tail" or "sed -i"
# is text, not a command, so a commit message or `istatus summary` body can say
# anything. The opener's line stays, so `cat <<EOF > file` is still caught. The
# stripping works on plain text, so a `<<WORD` inside a quoted string reads as
# an opener and hides the lines after it; that fails open (allows) rather than
# wrongly denying, the same trade as the gap below.
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
sq="'"
dq='"'
command_position="(^|[;&${nl}]|\|\|)[[:space:]]*(sed|cat|head|tail)([[:space:]]|$)"
in_place_sed="(^|[;&|${nl}]|xargs([[:space:]]+-[^[:space:]]+)*)[[:space:]]*sed[[:space:]]([^;&|${nl}]*[[:space:]])?(-[[:alpha:]]*i|--in-place)"
# A heredoc opener: << or <<-, then a marker that is a bare word, 'quoted' or
# "quoted". Not preceded by another <, so a here-string (<<<) is not one, and
# the marker must start with a letter, underscore or quote, so a shift in
# arithmetic (1 << 2) is not one either.
heredoc_opener="(^|[^<])<<(-?)[[:space:]]*(\\\\?[A-Za-z_][A-Za-z0-9_]*|${sq}[^${sq}]*${sq}|${dq}[^${dq}]*${dq})"

# strip_heredoc_bodies <command> — the command with the body lines of each
# heredoc removed, from the line after its opener through its closing marker
# (or the end of the command, if it never closes). The opener's own line stays,
# so `cat <<EOF > file` and anything after it on that line are still checked.
# Several heredocs on one line take their bodies in order, as the shell does.
strip_heredoc_bodies() {
  local line rest match token
  local -a markers=() dashes=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ${#markers[@]} )); then
      if closes_heredoc "$line" "${markers[0]}" "${dashes[0]}"; then
        markers=("${markers[@]:1}")
        dashes=("${dashes[@]:1}")
      fi
      continue
    fi
    printf '%s\n' "$line"
    rest="$line"
    while [[ "$rest" =~ $heredoc_opener ]]; do
      match="${BASH_REMATCH[0]}"
      dashes+=("${BASH_REMATCH[2]}")
      token="${BASH_REMATCH[3]}"
      markers+=("${token//[\'\"\\]/}")
      rest="${rest#*"$match"}"
    done
  done <<<"$1"
}

# closes_heredoc <line> <marker> <dash> — whether the line ends the heredoc.
# With <<-, the shell ignores leading tabs on the closing line.
closes_heredoc() {
  local line="$1"
  if [[ "$3" == "-" ]]; then
    while [[ "$line" == $'\t'* ]]; do line="${line#$'\t'}"; done
  fi
  [[ "$line" == "$2" ]]
}

scrubbed=$(strip_heredoc_bodies "$command")

if [[ "$scrubbed" =~ $command_position || "$scrubbed" =~ $in_place_sed ]]; then
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
