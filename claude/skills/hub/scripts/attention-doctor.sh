#!/bin/bash
# Detects claude-tmux-attention sessions whose hooks have silently stopped
# firing (the boot-burst race on `mux` launch, or the mid-session hook drop —
# see the Notion thread "Fix silent hook-registration loss in
# claude-tmux-attention"). Detection only: this never restarts or reloads
# anything, since /reload-plugins has not proven reliable and a scripted
# restart risks killing a pane mid-task. It reports which sessions need a
# by-hand /reload-plugins or restart, so Adam decides per session.
#
# Method: for each tmuxinator project with a claude window, find its live
# transcript's session_id and mtime. A session with a transcript updated
# recently but with zero matching entries in the attention debug log is
# reporting hooks-dead; a session whose transcript is stale is just idle,
# not broken, and is skipped.

set -uo pipefail

WORKSTATION_DIR="$HOME/.workstation"
TMUXINATOR_DIR="$WORKSTATION_DIR/tmuxinator"
DEBUG_LOG="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/debug.log"
STALE_AFTER_SECS="${ATTENTION_DOCTOR_STALE_SECS:-900}"  # 15 min: older = idle, not broken

if [[ ! -f "$DEBUG_LOG" ]]; then
  echo "error: debug log not found at $DEBUG_LOG (is CLAUDE_TMUX_ATTENTION_DEBUG=1 set?)" >&2
  exit 1
fi

now=$(date +%s)
healthy=0
idle=0
not_running=0
dead=()

for yml in "$TMUXINATOR_DIR"/*.yml; do
  name=$(awk -F': ' '/^name:/{print $2; exit}' "$yml")
  root=$(awk -F': ' '/^root:/{print $2; exit}' "$yml")
  [[ -z "$name" || -z "$root" ]] && continue

  # ngrok and similar utility projects have no claude window to check.
  # Window entries are YAML list items ("  - claude: ..."), not bare keys.
  grep -qE '^\s*-?\s*claude:' "$yml" 2>/dev/null || continue

  if ! tmux has-session -t "$name" 2>/dev/null; then
    echo "NOT RUNNING   $name (tmuxinator project not started)"
    not_running=$((not_running + 1))
    continue
  fi

  # Expand ~ and the transcript-directory naming convention: / and . -> -
  expanded_root="${root/#\~/$HOME}"
  project_dir_name=$(printf '%s' "$expanded_root" | tr '/.' '-')
  project_dir="$HOME/.claude/projects/${project_dir_name}"

  if [[ ! -d "$project_dir" ]]; then
    echo "NO TRANSCRIPT $name (expected $project_dir)"
    continue
  fi

  # Most-recently-modified transcript in that project dir is the live session.
  latest_line=$(find "$project_dir" -maxdepth 1 -name '*.jsonl' -exec stat -f '%m %N' {} \; 2>/dev/null \
    | sort -rn | awk 'NR==1')
  [[ -z "$latest_line" ]] && { echo "NO TRANSCRIPT $name (no .jsonl in $project_dir)"; continue; }

  mtime="${latest_line%% *}"
  transcript_path="${latest_line#* }"
  session_id=$(basename "$transcript_path" .jsonl)
  age=$((now - mtime))

  if (( age > STALE_AFTER_SECS )); then
    idle=$((idle + 1))
    continue
  fi

  if grep -qF "\"session_id\":\"${session_id}\"" "$DEBUG_LOG"; then
    healthy=$((healthy + 1))
  else
    dead+=("$name (session_id=$session_id, transcript active ${age}s ago, zero hook events logged)")
  fi
done

echo
echo "--- summary ---"
echo "healthy: $healthy   idle (skipped, >${STALE_AFTER_SECS}s since activity): $idle   not running: $not_running   dead hooks: ${#dead[@]}"

if (( ${#dead[@]} > 0 )); then
  echo
  echo "Sessions with dead attention hooks (need /reload-plugins or a restart):"
  for d in "${dead[@]}"; do
    echo "  - $d"
  done
  exit 1
fi

exit 0
