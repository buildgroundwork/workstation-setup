#!/bin/bash
# istatus — maintain THIS Claude session's live status: a prioritized inbox
# of items the human may need to act on, plus a one-line summary of current
# work/thinking.
#
# Why this exists: switching to a flagged session used to tell the human
# nothing about WHAT changed — they had to scroll the transcript to
# reconstruct it. istatus keeps a small, CURRENT-ONLY record per session (an
# items list + a working summary) that a sidebar pane can render continuously
# next to the session, so switching to a flagged pane shows the live picture
# immediately.
#
# THE ITEM MODEL (design note, not just a schema comment — read this before
# changing the shape):
#
#   Every item has a `kind`:
#     - "blocking": the session is stopped and cannot proceed without a
#       response (a permission prompt, an AskUserQuestion menu). These are
#       produced by Claude Code HOOK EVENTS, not by istatus commands:
#       istatus-hook.sh, wired in settings.json, writes them here. A
#       blocking item can NEVER be marked "read" (state is always "unread"
#       until it's removed by its
#       own resolution hook firing) — viewing it doesn't discharge it, only
#       responding to the actual prompt does. istatus resolve CAN force-
#       remove one as a manual escape hatch (mirroring the old clear-pane
#       command for a lost Esc-interrupt), but that's a deliberate CLI
#       override, not part of the normal lifecycle, and it warns loudly that
#       the underlying prompt was NOT actually answered.
#     - "notice": the agent's own judgment call that something is worth the
#       human's attention (istatus decide), or a hub dispatch's notices
#       (see `source` below). Has a `priority` (high/normal/low) set by whoever
#       created it. Unlike blocking items, a notice can be marked "read"
#       (seen, deliberately deferred — stays in the list, drops out of the
#       unread/attention count) without being removed, and later resolved
#       (removed entirely) once it's actually been acted on. This is the
#       email-inbox model: unread vs. read vs. gone, not just present/absent.
#
#   Sort order (owned by consumers reading this file, not stored): all
#   "blocking" items first (there's rarely more than one at a time, so
#   recency suffices among them), then "notice" items by priority
#   (high -> normal -> low), then recency within a priority tier.
#
#   Aggregate "does this pane need the human" (for the status-line count,
#   the popup) is DERIVED, never stored here, by istatus-inbox.sh: one `state`
#   per live session, "blocked" (any blocking item) > "flagged" (an unread
#   notice that is not from the hub) > "ready" (an unread hub.ready) >
#   "dispatched" (a hub.dispatched) > "".
#
# State file: ~/.claude-tmux-attention/status/<session_id>.json
#   { summary: "<current work/thinking, or empty>",
#     pane: "<tmux pane id>",   (optional; written by some hooks)
#     items: [ { id, kind, text, state, priority?, source?, created_at }, ... ],
#     done: [ { ...a resolved notice, resolved_at }, ... ] }   (optional)
#   kind: "blocking" | "notice". state: "unread" | "read" (blocking is
#   always "unread"). priority (notice only): "high" | "normal" | "low".
#   source: what raised the item. For a blocking item, the tool_name of the
#   hook payload ("" for a permission prompt, "AskUserQuestion" for a menu),
#   which is how a resolution knows what it resolves. For a hub dispatch,
#   "hub.dispatched" (read, low) or "hub.ready" (unread when finished). A
#   decide notice has none. Readers must tolerate its absence.
#   done: the last DONE_LIMIT notices resolved with `istatus resolve`, oldest
#   first, so the sidebar can show what was finished. Not part of the inbox:
#   only the sidebar reads it, and nothing derives attention from it.
#   pane: informational only. istatus.sh never writes it and only some hooks
#   do, so it is often absent, and readers must not depend on it: where a
#   session lives, and whether it is still live, come from the pane pointers
#   (panes/<pane>.session_id) alone.
#   Other files in the same directory: panes/<pane>.session_id (which session
#   occupies a pane), heartbeat/<session_id> (touched by every hook event).
#
# session_id is $CLAUDE_CODE_SESSION_ID — the Claude session UUID, NOT the
# inter-session bus name. A bus name survives a `/resume` into a different
# session in the same pane; the UUID does not, so keying by UUID is what lets
# a reader detect "this pane now holds a different session" instead of
# showing the previous occupant's stale state.
#
# Usage (run BY the agent, inside its own session):
#   istatus decide [--priority=high|normal|low] <<'EOF'
#   <the open question/decision/notice for the human>
#   EOF
#     Adds a "notice" item (default priority: normal). An unread notice is
#     what istatus-inbox.sh reads as "flagged" — the status line and popup
#     pick it up directly from this file, no separate flag to raise. Prints
#     the new item's id.
#
#   istatus defer <id-or-#>
#   istatus defer --all
#     Marks a notice "read": seen, deliberately left for later. Stays in the
#     list (doesn't disappear), but drops out of the unread/attention count.
#     Refuses on a blocking item — those can't be deferred, only resolved by
#     actually responding to the underlying prompt. --all marks every notice
#     read and leaves blocking items alone.
#
#   istatus undefer <id-or-#>
#     The reverse of defer: marks a read notice unread again. Refuses on a
#     blocking item, which is always unread.
#
#   istatus resolve <id-or-#>
#     Removes the item from the open list. For a notice, this is "done, acted
#     on," and the notice moves to the done list. For
#     a blocking item, this is the manual force-clear escape hatch — it does
#     NOT answer the underlying prompt, it only stops istatus from tracking
#     it; use only when a prompt is genuinely stuck/stale. Prints a warning
#     when used on a blocking item. Accepts either the item's real id, or the
#     small [N] ordinal the sidebar displays (1-based, current display order,
#     resolved fresh against the live list, never stored). Exits with a
#     usage error if the id/ordinal doesn't resolve — almost always a stale
#     reference from an earlier turn, worth surfacing rather than silently
#     no-op'ing.
#
#   istatus restore <id>
#     The reverse of resolving a notice: moves it from the done list back to
#     the open items, unread. By id only; the done list has no ordinals.
#
#   istatus summary <<'EOF'
#   <one line: what I'm currently doing/thinking>
#   EOF
#     Overwrites the summary in place. No history — this is "right now", not
#     a log. Call it when what you're working on materially changes, not on
#     every tool call.
#
#   istatus show
#     Print current state as JSON ({summary, items}). Used by the sidebar
#     renderer and by the session itself to check what it's already said
#     before deciding whether an update is needed.
#
# Usage (run from OUTSIDE the session, by the popup and the sidebar):
#   istatus --pane <pane> {defer|undefer|resolve|restore|show} ...
#     Acts on the session that occupies <pane>, found through
#     panes/<pane>.session_id, instead of on $CLAUDE_CODE_SESSION_ID. Only the
#     commands that act on items already there: decide and summary speak for
#     a session, so only the session runs them. Fails if no session is
#     recorded for the pane or it has no status file, and never writes an
#     occupancy pointer for the caller's own pane.
#
# Reason/summary text is read from STDIN, never an argument — same rationale
# as isend/iflag: the permission scanner inspects the raw command line before
# shell quoting, so metachars in an argument (globs, braces-with-quotes) trip
# a prompt even with Bash(istatus:*) allowlisted. Only `--pane <pane>`,
# `decide [--priority=…]`, `defer <id>|--all`, `undefer <id>`, `resolve <id>`,
# `restore <id>`, `summary` and `show` appear as args; free text never does.
#
# Exit: 0 on success (each mutator prints a short confirmation); non-zero with
# a message on stderr on misuse or a missing dependency — never silent.

set -euo pipefail

STATUS_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/status"
PANES_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/panes"
LOCK_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}"
DONE_LIMIT=20

die() { printf 'istatus: %s\n' "$*" >&2; exit 1; }
warn() { printf 'istatus: WARNING: %s\n' "$*" >&2; }

# --pane <pane> acts on the session that occupies <pane> rather than on the
# caller's own. It is how the popup and the sidebar, which run from tmux and
# not inside any Claude session, mark another session's items read, unread or
# resolved. The session comes from the pane's occupancy pointer, the same
# source istatus-inbox.sh trusts.
TARGET_PANE=""
if [[ "${1:-}" == --pane ]]; then
  [[ -n "${2:-}" ]] || die "usage: istatus --pane <pane> {defer|undefer|resolve|restore|show} ..."
  TARGET_PANE="$2"
  shift 2
fi

if [[ -n "$TARGET_PANE" ]]; then
  # Only the commands that act on items already there. decide and summary
  # speak for a session, so only the session itself runs them.
  case "${1:-}" in
    defer | undefer | resolve | restore | show) ;;
    *) die "--pane works only with defer, undefer, resolve, restore and show, not '${1:-}'" ;;
  esac
  pointer="$PANES_DIR/${TARGET_PANE}.session_id"
  sid=""
  [[ -f "$pointer" ]] && sid=$(<"$pointer")
  [[ -n "$sid" ]] || die "no session recorded for pane $TARGET_PANE"
else
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  [[ -n "$sid" ]] \
    || die "CLAUDE_CODE_SESSION_ID not set (not inside a Claude session?) — cannot update status"
fi

mkdir -p "$STATUS_DIR"
STATUS_FILE="$STATUS_DIR/${sid}.json"
LOCK_FILE="$LOCK_DIR/status-${sid}.lock"
# From outside, there is nothing to act on unless the session has a file;
# creating one for it would be speaking for it.
[[ -z "$TARGET_PANE" || -f "$STATUS_FILE" ]] \
  || die "no istatus state for the session in pane $TARGET_PANE"
if [[ ! -f "$STATUS_FILE" ]]; then
  # Create-if-absent without a window where the file is empty or a racing
  # writer's seed is lost: write a temp file, then hard-link it into place.
  seed_tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  printf '{"summary":"","items":[]}' > "$seed_tmp"
  ln "$seed_tmp" "$STATUS_FILE" 2>/dev/null || true
  rm -f "$seed_tmp"
fi

# One-time migration: a file written by the pre-items version of this script
# has `decisions` but no `items`. jq's `.items += [...]` on such a file would
# silently CREATE an items key alongside the stale decisions key rather than
# erroring — leaving both present, which is exactly the kind of silent-drift
# mess worth avoiding. Convert in place before anything else touches the
# file: each old decision becomes a "notice", unread, default priority. Also
# fires if `decisions` is still lingering even when `items` is ALREADY
# present (a file written by a transient bad version of this migration) —
# drop the dead key either way, items (if any) take precedence. Every other
# key is kept: the hooks record the session's pane in the same file.
if jq -e 'has("decisions") or (has("items") | not)' "$STATUS_FILE" >/dev/null 2>&1; then
  migrate_tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq '
    . as $file
    | del(.decisions)
    | .summary = (.summary // "")
    | .items = (
        if $file | has("items") then $file.items
        else [ ($file.decisions // [])[]
          | { id, kind: "notice", text, state: "unread", priority: "normal", created_at }
        ]
        end
      )
  ' "$STATUS_FILE" > "$migrate_tmp" && mv "$migrate_tmp" "$STATUS_FILE" || rm -f "$migrate_tmp"
fi

# Record "this pane currently holds this session_id", unconditionally, on
# every call — the only data source istatus-resolve-pane.sh needs. Earlier
# versions resolved a pane's occupant by scanning claude-tmux-attention's
# debug.log, but that log only exists when CLAUDE_TMUX_ATTENTION_DEBUG=1 is
# set in the session's env — an opt-in debug flag, not a guarantee, and a
# session started before that var landed in settings.json never gets it
# (settings.json changes don't apply mid-session). This pointer has no such
# dependency: every istatus call already carries TMUX_PANE and sid for free.
# Single flat file, overwritten atomically; last-writer-wins is fine since
# only one session occupies a given pane at a time. Not with --pane: then
# TMUX_PANE is the caller's pane (the popup's, the sidebar's), which the
# target session does not occupy.
if [[ -z "$TARGET_PANE" && -n "${TMUX_PANE:-}" ]]; then
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

_read_stdin_body() {
  local label="$1"
  [[ -t 0 ]] && die "no $label on stdin. Use a heredoc: istatus $label <<'EOF' … EOF"
  local body
  body=$(cat)
  [[ -n "$body" ]] || die "empty $label on stdin; nothing to record"
  printf '%s' "$body"
}

# A bare small integer (as shown by the sidebar's [N] ordinal, 1-based in
# current display order — blocking items first, then notices by priority)
# resolves to the real id it currently refers to; anything else is treated
# as a literal id. The ordinal is NOT stored anywhere and is only ever valid
# for the list as it exists right now, so this resolves fresh on every call.
# Mirrors the consumer-side sort order exactly (see the design note up top)
# so a displayed [N] always maps to the same item this resolves to.
_resolve_ref_to_id() {
  local ref="$1"
  if [[ "$ref" =~ ^[0-9]+$ ]]; then
    local by_ordinal
    by_ordinal=$(jq -r --argjson n "$ref" '
      ( .items
        | sort_by(
            (if .kind == "blocking" then 0 else 1 end),
            (if .kind == "notice" then
               (if .priority == "high" then 0 elif .priority == "low" then 2 else 1 end)
             else 0 end),
            .created_at
          )
      )[$n - 1].id // ""
    ' "$STATUS_FILE")
    [[ -n "$by_ordinal" ]] || die "no item at position $ref (only $(_item_count) open)"
    printf '%s' "$by_ordinal"
  else
    printf '%s' "$ref"
  fi
}

_item_count() {
  jq '.items | length' "$STATUS_FILE"
}

_add_item() {
  local kind="$1" text="$2" priority="${3:-}" tmp id
  id=$(date -u +%Y%m%dT%H%M%SZ)-$$
  tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq --arg id "$id" --arg kind "$kind" --arg text "$text" \
     --arg priority "$priority" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .items += [
      { id: $id, kind: $kind, text: $text, state: "unread", created_at: $ts }
      + (if $priority != "" then { priority: $priority } else {} end)
    ]
  ' "$STATUS_FILE" > "$tmp" || { rm -f "$tmp"; die "failed to record item"; }
  mv "$tmp" "$STATUS_FILE"
  printf '%s' "$id"
}

# Resolves ref (id or ordinal) to a real id and confirms it still exists.
# Kind-specific rules (e.g. "blocking items can't be deferred") are enforced
# by the caller after this returns, via _item_kind — this only answers
# "does this reference resolve to a real, currently-open item."
_find_item_or_die() {
  local ref="$1" id found
  id=$(_resolve_ref_to_id "$ref") || return 1
  found=$(jq --arg id "$id" '[.items[] | select(.id == $id)][0] // null' "$STATUS_FILE")
  [[ "$found" != "null" ]] || die "no open item with id '$id' (already resolved, or a stale reference?)"
  printf '%s' "$id"
}

_set_item_state() {
  local id="$1" state="$2" tmp
  tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq --arg id "$id" --arg state "$state" '
    .items = [.items[] | if .id == $id then .state = $state else . end]
  ' "$STATUS_FILE" > "$tmp" || { rm -f "$tmp"; die "failed to update item"; }
  mv "$tmp" "$STATUS_FILE"
}

# A resolved notice moves to .done, stamped, and only the last DONE_LIMIT are
# kept, so the sidebar can show what was finished without the file becoming
# a log. A blocking item is just dropped: resolving one here is a force-clear,
# not a completion. Nothing but the sidebar reads .done.
_remove_item() {
  local id="$1" tmp
  tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq --arg id "$id" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson limit "$DONE_LIMIT" '
    [.items[] | select(.id == $id and .kind == "notice") | . + { resolved_at: $ts }] as $done
    | .items = [.items[] | select(.id != $id)]
    | if ($done | length) > 0 then .done = ((.done // []) + $done)[-$limit:] else . end
  ' "$STATUS_FILE" > "$tmp" || { rm -f "$tmp"; die "failed to resolve item"; }
  mv "$tmp" "$STATUS_FILE"
}

_restore_item() {
  local id="$1" tmp
  jq -e --arg id "$id" '[(.done // [])[] | select(.id == $id)] | length > 0' \
    "$STATUS_FILE" >/dev/null || die "no done item with id '$id'"
  tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq --arg id "$id" '
    .items += [.done[] | select(.id == $id) | del(.resolved_at) | .state = "unread"]
    | .done = [.done[] | select(.id != $id)]
  ' "$STATUS_FILE" > "$tmp" || { rm -f "$tmp"; die "failed to restore item"; }
  mv "$tmp" "$STATUS_FILE"
}

_item_kind() {
  jq -r --arg id "$1" '[.items[] | select(.id == $id)][0].kind // ""' "$STATUS_FILE"
}

# Resolves ref to an open item's id and refuses a blocking one: its state is
# always unread, and only answering the prompt changes that.
_notice_id_or_die() {
  local ref="$1" verb="$2" id
  id=$(with_lock _find_item_or_die "$ref") || return 1
  [[ "$(_item_kind "$id")" != "blocking" ]] \
    || die "item $id is blocking (a pending permission prompt or menu) — it can't be $verb, only resolved by responding to it directly"
  printf '%s' "$id"
}

# Marks every unread notice read and prints how many. Writes nothing when
# there are none, so a no-op leaves the file (and its watchers) alone.
_defer_all_notices() {
  local count tmp
  count=$(jq '[.items[] | select(.kind == "notice" and .state == "unread")] | length' "$STATUS_FILE")
  if [[ "$count" -gt 0 ]]; then
    tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
    jq '.items = [.items[] | if .kind == "notice" then .state = "read" else . end]' \
      "$STATUS_FILE" > "$tmp" || { rm -f "$tmp"; die "failed to update items"; }
    mv "$tmp" "$STATUS_FILE"
  fi
  printf '%s' "$count"
}

_set_summary() {
  local tmp
  tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq --arg s "$1" '.summary = $s' "$STATUS_FILE" > "$tmp" \
    || { rm -f "$tmp"; die "failed to set summary"; }
  mv "$tmp" "$STATUS_FILE"
}

cmd_decide() {
  local priority="normal"
  while [[ "${1:-}" == --priority=* ]]; do
    priority="${1#--priority=}"
    shift
  done
  case "$priority" in
    high | normal | low) ;;
    *) die "--priority must be high, normal, or low (got '$priority')" ;;
  esac
  [[ $# -eq 0 ]] || die "usage: istatus decide [--priority=high|normal|low] <<'EOF' … EOF"

  local text
  text=$(_read_stdin_body decide)

  local id
  id=$(with_lock _add_item notice "$text" "$priority") || exit 1

  printf 'istatus: notice recorded (id=%s, priority=%s) — "%s"\n' "$id" "$priority" "$text"
}

cmd_defer() {
  if [[ "${1:-}" == --all ]]; then
    [[ $# -eq 1 ]] || die "usage: istatus defer --all (no other arguments)"
    local count
    count=$(with_lock _defer_all_notices) || exit 1
    printf 'istatus: deferred (marked read) %s notice(s)\n' "$count"
    return
  fi
  local ref="${1:-}"
  [[ -n "$ref" ]] || die "usage: istatus defer <id-or-#> | --all"
  [[ $# -le 1 ]] || die "usage: istatus defer <id-or-#> (one at a time, or --all)"

  local id
  id=$(_notice_id_or_die "$ref" deferred) || exit 1
  with_lock _set_item_state "$id" read
  printf 'istatus: deferred (marked read) %s\n' "$id"
}

cmd_undefer() {
  local ref="${1:-}"
  [[ -n "$ref" ]] || die "usage: istatus undefer <id-or-#>"
  [[ $# -le 1 ]] || die "usage: istatus undefer <id-or-#> (one at a time)"

  local id
  id=$(_notice_id_or_die "$ref" undeferred) || exit 1
  with_lock _set_item_state "$id" unread
  printf 'istatus: undeferred (marked unread) %s\n' "$id"
}

cmd_resolve() {
  local ref="${1:-}"
  [[ -n "$ref" ]] || die "usage: istatus resolve <id-or-#>"
  [[ $# -le 1 ]] || die "usage: istatus resolve <id-or-#> (one at a time)"

  local id
  id=$(with_lock _find_item_or_die "$ref") || exit 1

  local kind
  kind=$(_item_kind "$id")
  if [[ "$kind" == "blocking" ]]; then
    warn "item $id is blocking (a pending permission prompt or menu) — removing it here does NOT answer the underlying prompt. Use only if it's genuinely stuck/stale."
  fi

  with_lock _remove_item "$id" || exit 1

  local remaining
  remaining=$(_item_count)
  printf 'istatus: resolved %s (%s item(s) remaining)\n' "$id" "$remaining"
}

cmd_restore() {
  local id="${1:-}"
  [[ -n "$id" && $# -eq 1 ]] || die "usage: istatus restore <id>"
  with_lock _restore_item "$id" || exit 1
  printf 'istatus: restored %s (marked unread)\n' "$id"
}

cmd_summary() {
  local text
  text=$(_read_stdin_body summary)
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
    defer)    cmd_defer "$@" ;;
    undefer)  cmd_undefer "$@" ;;
    resolve)  cmd_resolve "$@" ;;
    restore)  cmd_restore "$@" ;;
    summary)  cmd_summary "$@" ;;
    show)     cmd_show "$@" ;;
    *)
      echo "usage: istatus [--pane <pane>] {decide [--priority=high|normal|low]|defer <id-or-#>|defer --all|undefer <id-or-#>|resolve <id-or-#>|restore <id>|summary|show}" >&2
      echo "  istatus decide [--priority=P] <<'EOF' … EOF   add a notice + flag" >&2
      echo "  istatus defer <id-or-#>                        mark a notice read (not blocking items)" >&2
      echo "  istatus defer --all                            mark every notice read" >&2
      echo "  istatus undefer <id-or-#>                      mark a read notice unread again" >&2
      echo "  istatus resolve <id-or-#>                       remove an item (a notice is kept in done)" >&2
      echo "  istatus restore <id>                           bring a done notice back, unread" >&2
      echo "  istatus summary <<'EOF' … EOF                  replace the current-work summary" >&2
      echo "  istatus show                                    print current state as JSON" >&2
      echo "  --pane <pane>   act on the session in <pane> (defer, undefer, resolve, show only)" >&2
      exit 2
      ;;
  esac
}

main "$@"
