#!/bin/bash
# istatus-hook — Claude Code hook entry point that records "blocking" items in
# a session's istatus file (see istatus.sh for the item model and file shape).
#
# Every hook event that carries a payload (add, remove, start, stop) also
# touches heartbeat/<session_id>, so the time of a session's last hook event is
# on record for attention-doctor.sh.
#
# Usage (wired as a hook command; payload is the hook JSON on stdin):
#   istatus-hook.sh add
#     Adds a "blocking" item, unread, to status/<session_id>.json. Its text is
#     the payload's `message` (a permission prompt) or, failing that, the first
#     question of an AskUserQuestion menu; `source` is the payload's tool_name
#     (empty for a permission prompt). A payload with neither adds nothing.
#
#   istatus-hook.sh remove
#     Clears blocking items the payload resolves; notices and the summary are
#     never touched. No tool_name (UserPromptSubmit, SessionEnd) clears every
#     blocking item. A tool_name clears the items that tool raised, plus
#     permission prompts unless the payload carries an agent_id: a subagent's
#     auto-approved tools finish while the parent's prompt is still pending.
#     A session with no status file, or none with a blocking item, is a silent
#     no-op that takes no lock, since this fires on every tool call.
#
#   istatus-hook.sh start
#     Records which session occupies this pane (panes/<pane>.session_id) and
#     nothing else; it creates no status file. Wired on SessionStart, which
#     fires on startup, resume, clear, compact and fork, so a pane taken over
#     by /resume points at the new session straight away.
#
#   istatus-hook.sh arm <target-pane>   (prompt on stdin; run by the hub)
#     Adds a read, low-priority "hub.dispatched" notice, whose text is the
#     prompt, to the session that occupies <target-pane>, and records
#     <target-pane> as the file's pane. Any earlier item whose source starts
#     with "hub." is removed first, so a re-dispatch supersedes the last
#     one; other notices and blocking items are untouched. The session is
#     found through the pane's occupancy pointer, so it is a silent no-op
#     when there is none: a session that was already running before start
#     was wired may not have one yet, and a pane resumed before start was
#     wired can still name its previous occupant. Never reads TMUX_PANE,
#     which here is the hub's pane.
#
#   istatus-hook.sh viewed <target-pane>   (run by whoever looked at the pane)
#     Marks the unread "hub.ready" notices of the session that occupies
#     <target-pane> read. Decide notices and blocking items are never touched,
#     since looking at a pane does not answer them. Like arm it finds the
#     session through the pane's pointer, is a silent no-op without one, and
#     never reads TMUX_PANE. It takes no lock unless there is something to mark.
#
#   istatus-hook.sh consume <target-pane>   (run by the hub after capture)
#     Removes the "hub.ready" notices, read or not, of the session that
#     occupies <target-pane>. Looking at a pane (viewed) only marks the ready
#     notice read; the hub has not read the result back until it captures the
#     pane, and that is what ends the dispatch, so `ready` stops listing it.
#     A dispatch still in flight, decide notices and blocking items are left.
#     Like viewed it uses the pane's pointer, is a silent no-op without one,
#     takes no lock unless there is something to remove, and never reads
#     TMUX_PANE.
#
#   istatus-hook.sh clear-pane <target-pane>   (run by hand)
#     Force-removes the blocking items of the session that occupies
#     <target-pane>; notices and the summary are untouched. The escape hatch
#     for a prompt interrupted with Esc, where no resolution hook fires. It
#     does not answer the prompt, it only stops istatus tracking it. Like
#     viewed it uses the pane's pointer, is a silent no-op without one, and
#     never reads TMUX_PANE.
#
#   istatus-hook.sh stop
#     Wired on Stop, in the dispatched session itself. Turns its
#     "hub.dispatched" notice into an unread, normal-priority "hub.ready" one
#     (same text, fresh created_at); does nothing if there is no such notice.
#     Stop does not fire when a turn is interrupted with Esc, so an
#     interrupted dispatch stays a read "hub.dispatched" notice until the next
#     arm replaces it. A ready notice the human deferred (read) is left alone.
#     Known race: a prompt dispatched into a pane that is mid-turn queues, and
#     the CURRENT turn's Stop reports it ready before it has run. A send that
#     fails is not armed, so it raises no false ready.
#     It also drops the session's blocking items (notices are kept): once the
#     main turn has stopped no permission prompt or menu can still be pending,
#     so one still there was missed by its resolution, and this is the
#     backstop. Known limit: a background subagent that hits a permission
#     prompt after its parent's turn has ended has that item cleared by the
#     parent's NEXT Stop, while the prompt is still up.

set -euo pipefail

# A hook must never break or pollute the session it runs in. A non-zero exit
# surfaces as a hook error (and exit 2 can block the action), and stdout on
# exit 0 is injected into Claude's context for some events, so: send stdout
# nowhere and force exit 0 on the way out. The work above still fails fast
# under set -e; at worst a failure costs a missed item. stderr stays for
# anyone running the script by hand.
exec >/dev/null
trap 'exit 0' EXIT

ATTENTION_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}"
STATUS_DIR="$ATTENTION_DIR/status"
PANES_DIR="$ATTENTION_DIR/panes"
# Seconds to wait for the session lock before dropping the write.
# ISTATUS_LOCK_TIMEOUT overrides it, for tests.
LOCK_TIMEOUT="${ISTATUS_LOCK_TIMEOUT:-2}"

die() { printf 'istatus-hook: %s\n' "$*" >&2; exit 1; }

# A jq def for writers that add to a status file. A file written by the
# pre-items istatus.sh has `decisions` and no `items`; `.items += [...]` on it
# would create `items` next to the stale `decisions`, and istatus.sh's next
# migration would then keep only our items and drop every legacy decision.
# Convert the same way that migration does (each decision becomes an unread,
# normal-priority notice; an existing `items` takes precedence), then drop
# `decisions`. Other keys such as `pane` are kept, as they are by that
# migration (which used to rebuild the file and drop them).
NORMALIZE_JQ='
  def normalize:
    if has("decisions") or (has("items") | not) then
      (if has("items") then .items
       else [ (.decisions // [])[]
              | { id, kind: "notice", text, state: "unread", priority: "normal", created_at } ]
       end) as $items
      | del(.decisions) | .items = $items
    else . end;
'

cmd_add() {
  local text source
  read_payload
  text=$(jq -r '.message // .tool_input.questions[0].question // empty' <<<"$PAYLOAD")
  source=$(jq -r '.tool_name // empty' <<<"$PAYLOAD")

  # A blocking item can only be cleared by its own resolution, so one with no
  # text would sit in the sidebar blank. That is what a miswired matcher would
  # add on every tool call.
  [[ -n "$text" ]] || return 0

  mkdir -p "$STATUS_DIR"
  LOCK_FILE="$ATTENTION_DIR/status-${SESSION_ID}.lock"
  with_lock record_blocking_item "$SESSION_ID" "$text" "$source"
}

cmd_remove() {
  local tool agent status_file
  read_payload

  # Both checks run before taking the lock, so a session with no status file,
  # or none with a blocking item, takes no lock and writes nothing on a tool
  # call. Any session that has ever run istatus has a status file, so the file
  # check alone would not spare most of them. Writers replace the file
  # atomically, so an unlocked read sees a whole file.
  status_file="$STATUS_DIR/${SESSION_ID}.json"
  [[ -f "$status_file" ]] || return 0
  has_blocking_item "$status_file" || return 0

  tool=$(jq -r '.tool_name // empty' <<<"$PAYLOAD")
  agent=$(jq -r '.agent_id // empty' <<<"$PAYLOAD")
  LOCK_FILE="$ATTENTION_DIR/status-${SESSION_ID}.lock"
  with_lock clear_resolved_items "$status_file" "$tool" "$agent"
}

cmd_start() {
  read_payload
  record_pane_occupant "$SESSION_ID"
}

cmd_stop() {
  local status_file
  read_payload

  # Stop fires at the end of every turn in every session, so the checks run
  # before taking the lock: no status file, or neither a dispatched nor a
  # blocking item in it, means there is nothing to do. Writers replace the file
  # atomically, so an unlocked read sees a whole file; at worst it misses an
  # arm that lands right after.
  status_file="$STATUS_DIR/${SESSION_ID}.json"
  [[ -f "$status_file" ]] || return 0
  has_dispatched_item "$status_file" || has_blocking_item "$status_file" || return 0
  LOCK_FILE="$ATTENTION_DIR/status-${SESSION_ID}.lock"
  with_lock settle_stopped_session "$status_file"
}

# Run by the hub, not by the target session, so TMUX_PANE here is the hub's
# pane and must never be read: the target is the argument.
cmd_arm() {
  local target="$1" prompt sid
  prompt=$(cat)
  [[ -n "$prompt" ]] || return 0
  sid=$(session_in_pane "$target") || return 0

  mkdir -p "$STATUS_DIR"
  LOCK_FILE="$ATTENTION_DIR/status-${sid}.lock"
  with_lock record_dispatch "$sid" "$target" "$prompt"
}

# Run by whoever looked at the target pane (the focus hook, the popup jump, the
# hub reading a result back), not by its session, so like arm it never reads
# TMUX_PANE: the target is the argument. Marks the session's finished dispatch
# notices read. Decide notices and blocking items are never touched, since
# looking at a pane does not answer them.
cmd_viewed() {
  # The check runs before taking the lock: a focus event fires constantly, and
  # almost always there is no unread finished dispatch to mark.
  update_pane_session "$1" has_unread_ready_item mark_ready_read
}

# Run by the hub after it reads a pane's result back (capture), which is what
# ends a dispatch: the result has been consumed, not just seen. Removes the
# session's finished-dispatch notices, read or not, so `ready` stops listing
# them. A dispatch still in flight, decide notices and blocking items stay.
# Addressed by pane, so it never reads TMUX_PANE.
cmd_consume() {
  update_pane_session "$1" has_ready_item drop_ready_items
}

# The manual escape hatch for a prompt that was interrupted with Esc, where no
# resolution hook fires and the blocking item would otherwise stay. Addressed by
# pane like viewed, so it never reads TMUX_PANE. Removes only blocking items.
cmd_clear_pane() {
  update_pane_session "$1" has_blocking_item drop_blocking_items
}

# update_pane_session <pane> <has fn> <write fn> — the skeleton the commands
# addressed by pane share. Find the session through the pane's pointer, and if
# its status file passes the cheap unlocked check <has fn>, run <write fn> on
# it under the session lock. A pane with no known session, no status file, or
# nothing to do takes no lock.
update_pane_session() {
  local target="$1" has="$2" write="$3" sid status_file
  sid=$(session_in_pane "$target") || return 0

  status_file="$STATUS_DIR/${sid}.json"
  [[ -f "$status_file" ]] || return 0
  "$has" "$status_file" || return 0
  LOCK_FILE="$ATTENTION_DIR/status-${sid}.lock"
  with_lock "$write" "$status_file"
}

# The session id that the pane's occupancy pointer names. Fails when the pane
# is empty or has no pointer, so callers treat "nobody known there" as a no-op.
session_in_pane() {
  local pane="$1" pointer sid
  pointer="$PANES_DIR/${pane}.session_id"
  [[ -n "$pane" && -f "$pointer" ]] || return 1
  sid=$(<"$pointer")
  [[ -n "$sid" ]] || return 1
  printf '%s' "$sid"
}

# Reads the hook payload from stdin into PAYLOAD and its session_id into
# SESSION_ID. Globals rather than a subshell capture, so a missing session_id
# can die the whole invocation.
read_payload() {
  PAYLOAD=$(cat)
  SESSION_ID=$(jq -r '.session_id // empty' <<<"$PAYLOAD")
  [[ -n "$SESSION_ID" ]] || die "no session_id in payload"
  beat
}

# Record that a hook fired for this session: truncate heartbeat/<session_id>, so
# its mtime is the time of the last hook event. attention-doctor compares it
# with the session's transcript to spot hooks that have silently stopped firing.
# Only hooks write it (istatus.sh never does), which is what makes it a signal
# about hooks and not about istatus use. `: >` is a builtin, so the common case
# forks nothing; the directory is made only when the first write fails. A
# failure here must never stop the hook's real work.
beat() {
  local file="$ATTENTION_DIR/heartbeat/$SESSION_ID"
  { : > "$file"; } 2>/dev/null && return 0
  mkdir -p "$ATTENTION_DIR/heartbeat" 2>/dev/null || return 0
  { : > "$file"; } 2>/dev/null || true
}

# The read-modify-write for add. Runs under the session lock.
record_blocking_item() {
  local sid="$1" text="$2" source="$3" status_file id
  status_file="$STATUS_DIR/${sid}.json"
  id=$(date -u +%Y%m%dT%H%M%SZ)-$$
  ensure_status_file "$status_file"
  rewrite_status "$status_file" \
    --arg id "$id" --arg text "$text" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pane "${TMUX_PANE:-}" --arg source "$source" "$NORMALIZE_JQ"'
    normalize
    # Record the pane only when known, so an add without one cannot erase it.
    | (if $pane != "" then .pane = $pane else . end)
    | .items += [ { id: $id, kind: "blocking", text: $text, source: $source, state: "unread", created_at: $ts } ]
  '

  record_pane_occupant "$sid"
}

# The read-modify-write for arm. Runs under the session lock.
record_dispatch() {
  local sid="$1" pane="$2" prompt="$3" status_file id
  status_file="$STATUS_DIR/${sid}.json"
  id=$(date -u +%Y%m%dT%H%M%SZ)-$$
  ensure_status_file "$status_file"
  rewrite_status "$status_file" \
    --arg id "$id" --arg text "$prompt" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pane "$pane" "$NORMALIZE_JQ"'
    normalize
    | .pane = $pane
    | .items |= map(select((.source // "") | startswith("hub.") | not))
    | .items += [ { id: $id, kind: "notice", text: $text, source: "hub.dispatched",
                    state: "read", priority: "low", created_at: $ts } ]
  '
}

has_blocking_item() { has_item "$1" '.kind == "blocking"'; }
has_unread_ready_item() { has_item "$1" '.source == "hub.ready" and .state == "unread"'; }
has_ready_item() { has_item "$1" '.source == "hub.ready"'; }
has_dispatched_item() { has_item "$1" '.source == "hub.dispatched"'; }

# has_item <status_file> <jq predicate> [jq-arg-flags...] — does any item
# satisfy the predicate? Used for the cheap unlocked checks before a hot-path
# hook takes the lock. A file jq cannot read (a legacy file with no items)
# counts as having none. Extra args are forwarded to jq (--arg NAME value,
# ...) so a predicate can reference $-bound variables instead of shell-
# interpolating untrusted values into the program text.
has_item() {
  local file="$1" predicate="$2"
  shift 2
  jq -e "$@" "[.items[] | select($predicate)] | length > 0" "$file" >/dev/null 2>&1
}

# The read-modify-write for stop. Runs under the session lock. A dispatched
# notice becomes an unread ready one. Phase lives in `source`, not in
# read/unread: a ready notice the human deferred is read but is not dispatched,
# so it must not be raised again on the next Stop. Blocking items are dropped:
# once the main turn has stopped no permission prompt or menu can still be
# pending, so one still there was missed by its resolution (a tool failing,
# or the add and remove hooks landing out of order). Notices are kept.
settle_stopped_session() {
  rewrite_status "$1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .items |= map(
      if .source == "hub.dispatched"
      then .source = "hub.ready" | .state = "unread" | .priority = "normal" | .created_at = $ts
      else . end)
    | .items |= map(select(.kind != "blocking"))
  '
}

# The read-modify-write for viewed. Runs under the session lock.
mark_ready_read() {
  rewrite_status "$1" '
    .items |= map(if .source == "hub.ready" and .state == "unread"
                  then .state = "read" else . end)
  '
}

# The read-modify-write for consume. Runs under the session lock.
drop_ready_items() {
  rewrite_status "$1" '.items |= map(select(.source != "hub.ready"))'
}

# The read-modify-write for clear-pane. Runs under the session lock.
drop_blocking_items() {
  rewrite_status "$1" '.items |= map(select(.kind != "blocking"))'
}

# The jq predicate shared by clear_resolved_items' no-op check and its
# rewrite: does this resolution payload resolve THIS item? A payload with no
# tool resolves every blocking item. A tool-bearing one resolves the items it
# raised, plus permission prompts (empty source) unless it came from a
# subagent, whose auto-approved tools finish while the parent still waits.
RESOLVES_DEF='
  def resolves($tool; $agent):
    .kind == "blocking"
    and ($tool == ""
         or (if (.source // "") == "" then $agent == "" else .source == $tool end));
'

# The read-modify-write for remove. Runs under the session lock.
#
# This fires on every tool call in every session, so most calls reach this
# function with a blocking item present but NOT raised by this particular
# resolution (e.g. an unrelated tool finishing while a menu is still
# pending). Checking first whether anything actually matches `resolves`
# avoids rewriting the file when nothing would change: same array content
# either way, so there is nothing to gain from replacing it on disk.
clear_resolved_items() {
  local status_file="$1" tool="$2" agent="$3"
  has_item "$status_file" "$RESOLVES_DEF resolves(\$tool; \$agent)" \
    --arg tool "$tool" --arg agent "$agent" || return 0
  rewrite_status "$status_file" --arg tool "$tool" --arg agent "$agent" "
    $RESOLVES_DEF
    .items = [ .items[] | select(resolves(\$tool; \$agent) | not) ]
  "
}

# Same lock istatus.sh takes (status-<sid>.lock in the attention dir; flock when
# available, a mkdir-based spinlock otherwise), so a hook write can't race an
# istatus call, or another hook, in the same session and lose an item. Copied
# from istatus.sh except that the flock wait is bounded: a wedged holder must
# not make every later hook in the session hang until Claude Code kills it,
# which would surface as a hook error on every tool call. On timeout the write
# is dropped, costing at most a missed item. The mkdir fallback is untested
# here; the Brewfile installs flock so that the tested path is the usual one.
with_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -x -w "$LOCK_TIMEOUT" 9 || return 0
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

# ensure_status_file <status_file> — create an empty status file if there is
# none, without ever exposing a partial one. The seed is written to a temp file
# and hard-linked into place: ln fails when the target exists, which makes it
# an atomic create-if-absent, and a failure just means someone else created it
# first. A plain `printf > file` would truncate in place, so an unlocked reader
# could see a zero-byte file or a racing writer could lose its seed.
ensure_status_file() {
  local status_file="$1" seed
  if [[ ! -f "$status_file" ]]; then
    seed=$(mktemp "${status_file}.XXXXXX")
    printf '{"summary":"","items":[]}' > "$seed"
    ln "$seed" "$status_file" 2>/dev/null || true
    rm -f "$seed"
  fi
}

# rewrite_status <status_file> <jq args...> — apply a jq program to the status
# file atomically (mktemp + mv), leaving the file untouched if jq fails.
rewrite_status() {
  local status_file="$1" tmp
  shift
  tmp=$(mktemp "${status_file}.XXXXXX")
  jq "$@" "$status_file" > "$tmp" || { rm -f "$tmp"; die "failed to update $status_file"; }
  mv "$tmp" "$status_file"
}

# Records "this pane currently holds this session_id" so a consumer can trust
# the status file only while the pointer still names its session. Same pointer
# istatus.sh writes; the hook writes it too because a session can block before
# it ever calls istatus.
record_pane_occupant() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  local pane_tmp
  mkdir -p "$PANES_DIR"
  pane_tmp=$(mktemp "${PANES_DIR}/.XXXXXX")
  printf '%s' "$1" > "$pane_tmp"
  mv "$pane_tmp" "${PANES_DIR}/${TMUX_PANE}.session_id"
}

case "${1:-}" in
  add)        cmd_add ;;
  remove)     cmd_remove ;;
  start)      cmd_start ;;
  arm)        cmd_arm "${2:-}" ;;
  stop)       cmd_stop ;;
  viewed)     cmd_viewed "${2:-}" ;;
  consume)    cmd_consume "${2:-}" ;;
  clear-pane) cmd_clear_pane "${2:-}" ;;
  *)          die "usage: istatus-hook.sh add|remove|start|arm <pane>|stop|viewed <pane>|consume <pane>|clear-pane <pane>" ;;
esac
