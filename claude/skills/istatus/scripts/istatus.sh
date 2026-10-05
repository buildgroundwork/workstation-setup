#!/bin/bash
# istatus — maintain THIS Claude session's live status: open decisions the
# human must make, and a one-line summary of current work/thinking. Replaces
# iflag: raising a decision now IS the flag, so there is one mechanism instead
# of two drifting ones.
#
# Why this exists: iflag lights up the attention popup, but tells the human
# nothing about WHAT changed once they arrive — they have to scroll the
# transcript to reconstruct it. istatus keeps a small, CURRENT-ONLY record per
# session (open decisions + a working summary) that a sidebar pane can render
# continuously next to the session, so switching to a flagged pane shows the
# live picture immediately. Deliberately NOT a growing log: resolved decisions
# are removed, not marked done-but-kept, and the summary is replaced in place —
# old state falls off rather than accumulating.
#
# State file: ~/.claude-tmux-attention/status/<session_id>.json
#   { summary: "<current work/thinking, or empty>",
#     decisions: [ { id, text, created_at }, ... ] }
# session_id is $CLAUDE_CODE_SESSION_ID — the Claude session UUID, NOT the
# inter-session bus name. A bus name survives a `/resume` into a different
# session in the same pane; the UUID does not, so keying by UUID is what lets
# a reader detect "this pane now holds a different session" instead of
# showing the previous occupant's stale state.
#
# Usage (run BY the agent, inside its own session):
#   istatus decide <<'EOF'
#   <the open question/decision the human must make>
#   EOF
#     Adds a decision to the queue AND raises the attention flag (human.requested
#     on this pane) — same producer iflag used. Prints the new decision's id.
#
#   istatus resolve <id>
#     Removes that decision from the queue. If it was the last open decision,
#     also clears this pane's human.requested (nothing left to flag). Exits
#     with a usage error if the id doesn't exist — resolving an unknown id is
#     almost always a stale id from an earlier turn, worth surfacing rather
#     than silently no-op'ing.
#
#   istatus summary <<'EOF'
#   <one line: what I'm currently doing/thinking>
#   EOF
#     Overwrites the summary in place. No history — this is "right now", not a
#     log. Call it when what you're working on materially changes, not on
#     every tool call.
#
#   istatus show
#     Print current state as JSON ({summary, decisions}). Used by the sidebar
#     renderer and by the session itself to check what it's already said
#     before deciding whether an update is needed.
#
# Reason/summary text is read from STDIN, never an argument — same rationale
# as isend/iflag: the permission scanner inspects the raw command line before
# shell quoting, so metachars in an argument (globs, braces-with-quotes) trip
# a prompt even with Bash(istatus:*) allowlisted. Only `decide`/`resolve
# <id>`/`summary`/`show` appear as args; free text never does.
#
# Exit: 0 on success (each mutator prints a short confirmation); non-zero with
# a message on stderr on misuse or a missing dependency — never silent.

set -euo pipefail

PLUGIN_CACHE="$HOME/.claude/plugins/cache/gusto-claude-code/claude-tmux-attention"
STATUS_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/status"
PANES_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/panes"
LOCK_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}"

die() { printf 'istatus: %s\n' "$*" >&2; exit 1; }

sid="${CLAUDE_CODE_SESSION_ID:-}"
[[ -n "$sid" ]] \
  || die "CLAUDE_CODE_SESSION_ID not set (not inside a Claude session?) — cannot update status"

mkdir -p "$STATUS_DIR"
STATUS_FILE="$STATUS_DIR/${sid}.json"
LOCK_FILE="$LOCK_DIR/status-${sid}.lock"
[[ -f "$STATUS_FILE" ]] || printf '{"summary":"","decisions":[]}' > "$STATUS_FILE"

# Record "this pane currently holds this session_id", unconditionally, on
# every call — the only data source istatus-resolve-pane.sh needs. Earlier
# versions resolved a pane's occupant by scanning claude-tmux-attention's
# debug.log, but that log only exists when CLAUDE_TMUX_ATTENTION_DEBUG=1 is
# set in the session's env — an opt-in debug flag, not a guarantee, and a
# session started before that var landed in settings.json never gets it
# (settings.json changes don't apply mid-session). This pointer has no such
# dependency: every istatus call already carries TMUX_PANE and sid for free.
# Single flat file, overwritten atomically; last-writer-wins is fine since
# only one session occupies a given pane at a time.
if [[ -n "${TMUX_PANE:-}" ]]; then
  mkdir -p "$PANES_DIR"
  pane_tmp=$(mktemp "${PANES_DIR}/.XXXXXX")
  printf '%s' "$sid" > "$pane_tmp"
  mv "$pane_tmp" "${PANES_DIR}/${TMUX_PANE}.session_id"
fi

# Same locking pattern as attention-state.sh: flock when available, a
# mkdir-based spinlock otherwise. Guards the read-modify-write against a
# concurrent istatus call from a subagent/hook in the same session.
with_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -x 9
    "$@"
  else
    local lock="$LOCK_FILE.d"
    local tries=50
    while ! mkdir "$lock" 2>/dev/null; do
      tries=$((tries - 1))
      [[ $tries -le 0 ]] && { rm -rf "$lock"; mkdir "$lock"; break; }
      sleep 0.05
    done
    local status=0
    "$@" || status=$?
    rmdir "$lock" 2>/dev/null || true
    return "$status"
  fi
}

# Resolve attention-state.sh once (newest installed plugin version wins, same
# as iflag), for the decide/resolve paths that raise or clear human.requested.
_resolve_state_sh() {
  local state_sh
  state_sh=$(ls -d "$PLUGIN_CACHE"/*/scripts/attention-state.sh 2>/dev/null \
    | sort -V | tail -1) || true
  [[ -n "${state_sh:-}" && -x "$state_sh" ]] \
    || die "attention-state.sh not found under $PLUGIN_CACHE (plugin installed?)"
  printf '%s' "$state_sh"
}

_read_stdin_body() {
  local label="$1"
  [[ $# -le 1 ]] \
    || die "$label goes on STDIN, not as an argument. Use: istatus $label <<'EOF' … EOF"
  [[ -t 0 ]] && die "no $label on stdin. Use a heredoc: istatus $label <<'EOF' … EOF"
  local body
  body=$(cat)
  [[ -n "$body" ]] || die "empty $label on stdin; nothing to record"
  printf '%s' "$body"
}

_add_decision() {
  local tmp id
  id=$(date -u +%Y%m%dT%H%M%SZ)-$$
  tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq --arg id "$id" --arg text "$1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.decisions += [{id: $id, text: $text, created_at: $ts}]' \
    "$STATUS_FILE" > "$tmp" || { rm -f "$tmp"; die "failed to record decision"; }
  mv "$tmp" "$STATUS_FILE"
  printf '%s' "$id"
}

_remove_decision() {
  local id="$1" tmp existed
  existed=$(jq --arg id "$id" '[.decisions[] | select(.id == $id)] | length' "$STATUS_FILE")
  [[ "$existed" -gt 0 ]] || die "no open decision with id '$id' (already resolved, or a stale id?)"
  tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq --arg id "$id" '.decisions = [.decisions[] | select(.id != $id)]' \
    "$STATUS_FILE" > "$tmp" || { rm -f "$tmp"; die "failed to resolve decision"; }
  mv "$tmp" "$STATUS_FILE"
}

_set_summary() {
  local tmp
  tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq --arg s "$1" '.summary = $s' "$STATUS_FILE" > "$tmp" \
    || { rm -f "$tmp"; die "failed to set summary"; }
  mv "$tmp" "$STATUS_FILE"
}

_open_decision_count() {
  jq '.decisions | length' "$STATUS_FILE"
}

cmd_decide() {
  local text
  text=$(_read_stdin_body decide "$@")

  local id
  id=$(with_lock _add_decision "$text")

  # Raise human.requested on this pane, same producer iflag used. cwd is
  # best-effort context, same as iflag.
  local state_sh payload
  state_sh=$(_resolve_state_sh)
  payload=$(jq -nc --arg sid "$sid" --arg msg "$text" --arg cwd "$PWD" \
    '{session_id: $sid, message: $msg, cwd: $cwd}') || die "failed to build payload"
  printf '%s' "$payload" | "$state_sh" request-human || die "attention-state.sh request-human failed"

  printf 'istatus: decision recorded (id=%s) — "%s"\n' "$id" "$text"
}

cmd_resolve() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: istatus resolve <id>"
  [[ $# -le 1 ]] || die "usage: istatus resolve <id> (one id at a time)"

  with_lock _remove_decision "$id"

  # If that was the last open decision, nothing left to flag — clear
  # human.requested on this pane. mark-viewed also clears task.ready, which
  # is fine: a session resolving its own decision isn't a dispatched-task
  # result, so that state is never set on this pane anyway.
  local remaining
  remaining=$(_open_decision_count)
  if [[ "$remaining" -eq 0 ]] && [[ -n "${TMUX_PANE:-}" ]]; then
    local state_sh
    state_sh=$(_resolve_state_sh)
    "$state_sh" mark-viewed "$TMUX_PANE" || true
  fi

  printf 'istatus: resolved decision %s (%s open remaining)\n' "$id" "$remaining"
}

cmd_summary() {
  local text
  text=$(_read_stdin_body summary "$@")
  with_lock _set_summary "$text"
  printf 'istatus: summary updated\n'
}

cmd_show() {
  [[ $# -eq 0 ]] || die "usage: istatus show (no arguments)"
  jq '.' "$STATUS_FILE"
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    decide)   cmd_decide "$@" ;;
    resolve)  cmd_resolve "$@" ;;
    summary)  cmd_summary "$@" ;;
    show)     cmd_show "$@" ;;
    *)
      echo "usage: istatus {decide|resolve <id>|summary|show}" >&2
      echo "  istatus decide <<'EOF' … EOF     add an open decision + flag" >&2
      echo "  istatus resolve <id>             remove a resolved decision" >&2
      echo "  istatus summary <<'EOF' … EOF    replace the current-work summary" >&2
      echo "  istatus show                     print current state as JSON" >&2
      exit 2
      ;;
  esac
}

main "$@"
