#!/bin/bash
# Hooks that carry state across a compaction. A compaction keeps a summary of
# the conversation and drops the rest, and the summary tends to lose the facts
# that sit outside the conversation: which files are uncommitted, which commits
# are unpushed, and which decisions are still waiting on the user. These hooks
# save those facts to disk before the compaction and put them back after it.
#
#   compact-handoff.sh pre      PreCompact, manual and auto. Writes
#                               $HANDOFF_DIR/<session_id>.md and prints
#                               instructions for the summarizer.
#   compact-handoff.sh inject   SessionStart with matcher "compact". Returns
#                               that file as context for the compacted session.
#
# Everything here is deterministic shell: no model call, so it adds no cost or
# delay, and it runs on auto-compaction as well as /compact. It does not know
# what was only said in the conversation (decisions, preferences); the printed
# instructions ask the summarizer to keep those. PreCompact hooks cannot run a
# model (only command, http and mcp_tool handlers), and a hook that exits
# non-zero can block the compaction, so every path exits 0.
#
# Handoff files are never deleted; one per session accumulates under
# $HANDOFF_DIR (default ~/.claude/handoffs).
#
# Tests: claude/hooks/compact-handoff.test.sh

HANDOFF_DIR="${HANDOFF_DIR:-$HOME/.claude/handoffs}"
ATTENTION_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}"

# pre — write the handoff file and print instructions for the summarizer.
pre() {
  local payload session cwd trigger custom transcript file tmp
  payload=$(cat)
  session=$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null) || return 0
  [[ -z "$session" || "$session" == */* ]] && return 0
  cwd=$(jq -r '.cwd // ""' <<<"$payload")
  trigger=$(jq -r '.trigger // "unknown"' <<<"$payload")
  custom=$(jq -r '.custom_instructions // ""' <<<"$payload")
  transcript=$(jq -r '.transcript_path // ""' <<<"$payload")

  file="$HANDOFF_DIR/$session.md"
  mkdir -p "$HANDOFF_DIR" || return 0
  tmp="$file.$$"
  {
    echo "# State saved before a $trigger compaction"
    echo
    echo "Saved $(date -u +%Y-%m-%dT%H:%M:%SZ) for session $session."
    echo "Directory: $cwd"
    echo "Full transcript: $transcript"
    echo
    echo "## Git"
    describe_git "$cwd"
    echo
    echo "## istatus"
    describe_istatus "$session"
  } >"$tmp" && mv "$tmp" "$file" || return 0

  summarizer_instructions "$file" "$custom"
}

# inject — return the handoff file as SessionStart context, if there is one.
inject() {
  local payload session file
  payload=$(cat)
  session=$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null) || return 0
  [[ -z "$session" || "$session" == */* ]] && return 0
  file="$HANDOFF_DIR/$session.md"
  [[ -f "$file" ]] || return 0

  jq -n --arg path "$file" --rawfile body "$file" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("State saved before the compaction (also at " + $path + "):\n\n" + $body)
    }
  }'
}

# describe_git <dir> — branch, uncommitted files, unpushed commits and
# worktrees for the repository containing <dir>.
describe_git() {
  local dir="$1" status unpushed
  if ! git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null; then
    echo "$dir is not a git repository."
    return
  fi
  echo "Branch: $(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  status=$(git -C "$dir" status --short)
  echo "Uncommitted:"
  echo "${status:-none}"
  if git -C "$dir" rev-parse --abbrev-ref '@{u}' &>/dev/null; then
    unpushed=$(git -C "$dir" log --oneline '@{u}..HEAD')
    echo "Unpushed commits:"
    echo "${unpushed:-none}"
  else
    echo "Unpushed commits: this branch has no upstream."
  fi
  echo "Worktrees:"
  git -C "$dir" worktree list
}

# describe_istatus <session_id> — the session's summary line and its open
# items, from the file the istatus skill keeps.
describe_istatus() {
  local file="$ATTENTION_DIR/status/$1.json"
  if [[ ! -f "$file" ]]; then
    echo "This session has no istatus state."
    return
  fi
  jq -r '
    "Summary: \(.summary // "none")",
    "Open items:",
    (if ((.items // []) | length) == 0 then "none"
     else (.items[] | "- [\(.kind)] \(.text)\(if .state == "read" then " (read)" else "" end)") end)
  ' "$file" 2>/dev/null || echo "This session has no readable istatus state."
}

# summarizer_instructions <file> <custom> — stdout of a PreCompact hook becomes
# instructions for the compaction summary (capped at 10,000 characters, which
# this text stays well under).
summarizer_instructions() {
  cat <<EOF
Keep these in the summary: uncommitted and unpushed work (which files, which branch), decisions and questions still waiting on the user, approvals the user has given or withheld, and the user's stated preferences and corrections. Git and istatus state is saved at $1 and returns after the compaction, so the summary does not need to repeat it in full.
EOF
  [[ -n "$2" ]] && printf "The user's focus for this compaction: %s\n" "$2"
  return 0
}

case "${1:-}" in
  pre) pre ;;
  inject) inject ;;
esac
exit 0
