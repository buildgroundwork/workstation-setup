#!/bin/bash
# hub-map.sh — emit a JSON map of Adam's tmuxinator projects and their live
# tmux state, for the hub skill to reason over.
#
# For each tmuxinator config (~/.workstation/tmuxinator/*.yml) we report:
#   project   - config basename (the `tmuxinator start <project>` name)
#   name      - the session display name (`name:` in the YAML)
#   root      - the project root (`root:` in the YAML)
#   running   - whether a live tmux session with that name exists
#   claude_target  - "<session>:<window>" of the claude window, if the session
#                    is running and has one (else "")
#   claude_panes   - number of panes in that claude window running `claude`
#
# Pure read. No tmux mutation. Output is a JSON array on stdout.

set -euo pipefail

TMUXINATOR_DIR="${TMUXINATOR_DIR:-$HOME/.workstation/tmuxinator}"

# Snapshot live tmux panes once: "session_name<TAB>window_index<TAB>window_name<TAB>pane_command"
live_panes=""
if command -v tmux >/dev/null 2>&1 && tmux list-panes -a >/dev/null 2>&1; then
  live_panes=$(tmux list-panes -a -F '#{session_name}	#{window_index}	#{window_name}	#{pane_current_command}' 2>/dev/null || true)
fi

# Extract a top-level scalar (`key: value`) from a tmuxinator YAML.
yaml_scalar() {
  local file="$1" key="$2"
  sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -1
}

emit_entries() {
  local first=1
  printf '['
  local cfg
  for cfg in "$TMUXINATOR_DIR"/*.yml; do
    [[ -e "$cfg" ]] || continue
    local project name root
    project=$(basename "$cfg" .yml)
    name=$(yaml_scalar "$cfg" name)
    root=$(yaml_scalar "$cfg" root)
    [[ -n "$name" ]] || name="$project"

    # Is a live session with this display name running?
    local running=false claude_target="" claude_panes=0
    if [[ -n "$live_panes" ]] && printf '%s\n' "$live_panes" | awk -F'\t' -v s="$name" '$1==s{found=1} END{exit !found}'; then
      running=true
      # Find the claude window and count claude panes. Match window names that
      # CONTAIN "claude", not an exact "claude": tmux automatic-rename rewrites a
      # window's name to its running command, so a session running the `claude.exe`
      # binary (e.g. the ReBAC overseer) shows a window named "claude.exe", not the
      # static "claude" the tmuxinator layout assigns. An exact match dropped those
      # sessions from the map entirely (claude_panes=0 -> excluded from the
      # dashboard). Contains-match keeps line 51 consistent with the pane-command
      # match on line 55 ($4 ~ /claude/). Lowest-index match wins (print $2; exit),
      # which picks the canonical window 6 even when a session has a stray second
      # claude window.
      local cwin
      cwin=$(printf '%s\n' "$live_panes" \
        | awk -F'\t' -v s="$name" '$1==s && $3 ~ /claude/{print $2; exit}')
      if [[ -n "$cwin" ]]; then
        claude_target="${name}:${cwin}"
        claude_panes=$(printf '%s\n' "$live_panes" \
          | awk -F'\t' -v s="$name" -v w="$cwin" '$1==s && $2==w && $4 ~ /claude/{n++} END{print n+0}')
      fi
    fi

    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"project":"%s","name":"%s","root":"%s","running":%s,"claude_target":"%s","claude_panes":%d}' \
      "$project" "$name" "$root" "$running" "$claude_target" "$claude_panes"
  done
  printf ']'
}

emit_entries
