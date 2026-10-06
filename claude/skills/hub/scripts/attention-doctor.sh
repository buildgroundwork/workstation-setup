#!/bin/bash
# Detects Claude sessions whose istatus hooks have silently stopped firing (the
# boot-burst race on `mux` launch, or the mid-session hook drop — see the
# Notion thread "Fix silent hook-registration loss in claude-tmux-attention").
# Detection only: this never restarts or reloads anything, since
# /reload-plugins has not proven reliable and a scripted restart risks killing
# a pane mid-task. It reports which sessions need a by-hand /reload-plugins or
# restart, so Adam decides per session.
#
# Method: for each tmuxinator project with a claude window, find its live
# transcript's session_id and mtime. Every istatus hook event touches
# heartbeat/<session_id> (istatus.sh never does, so it is a signal about the
# hooks and not about istatus use). A session with a transcript updated
# recently whose heartbeat is missing, or far behind the transcript, is
# reporting hooks-dead: the same "transcript active but no hook events" test as
# before, with a file instead of a debug-log grep, so it catches both a session
# whose hooks never registered and one whose hooks dropped mid-session. A
# session whose transcript is stale is just idle, not broken, and is skipped. A
# session that started before the hooks were wired has no heartbeat, and will
# read as dead until it is restarted.

set -uo pipefail

WORKSTATION_DIR="$HOME/.workstation"
TMUXINATOR_DIR="$WORKSTATION_DIR/tmuxinator"
HEARTBEAT_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/heartbeat"
STALE_AFTER_SECS="${ATTENTION_DOCTOR_STALE_SECS:-900}"  # 15 min: older = idle, not broken
# How far the transcript may have moved past the last hook event before the
# hooks count as dead. Stop and UserPromptSubmit fire at every turn boundary, so
# a few minutes is generous.
HEARTBEAT_LAG_SECS="${ATTENTION_DOCTOR_HEARTBEAT_LAG_SECS:-300}"

# hooks_alive <session_id> <transcript mtime, epoch seconds> — has a hook fired
# for the session recently enough, compared with the transcript's last write?
# Succeeds when it has.
hooks_alive() {
  local heartbeat="$HEARTBEAT_DIR/$1" transcript_mtime="$2" beat
  [[ -f "$heartbeat" ]] || return 1
  beat=$(stat -f %m "$heartbeat")
  (( transcript_mtime - beat <= HEARTBEAT_LAG_SECS ))
}

main() {
  local now healthy=0 idle=0 not_running=0 dead=()
  now=$(date +%s)

  local yml name root
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
    local expanded_root project_dir_name project_dir
    expanded_root="${root/#\~/$HOME}"
    project_dir_name=$(printf '%s' "$expanded_root" | tr '/.' '-')
    project_dir="$HOME/.claude/projects/${project_dir_name}"

    if [[ ! -d "$project_dir" ]]; then
      echo "NO TRANSCRIPT $name (expected $project_dir)"
      continue
    fi

    # Most-recently-modified transcript in that project dir is the live session.
    local latest_line mtime transcript_path session_id age
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

    if hooks_alive "$session_id" "$mtime"; then
      healthy=$((healthy + 1))
    else
      dead+=("$name (session_id=$session_id, transcript active ${age}s ago, no recent hook event)")
    fi
  done

  echo
  echo "--- summary ---"
  echo "healthy: $healthy   idle (skipped, >${STALE_AFTER_SECS}s since activity): $idle   not running: $not_running   dead hooks: ${#dead[@]}"

  if (( ${#dead[@]} > 0 )); then
    echo
    echo "Sessions with dead istatus hooks (need /reload-plugins or a restart):"
    local d
    for d in "${dead[@]}"; do
      echo "  - $d"
    done
    return 1
  fi

  return 0
}

# Run only when executed, not when sourced, so the tests can load hooks_alive.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
