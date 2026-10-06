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
#       produced by Claude Code HOOK EVENTS, not by istatus commands — a
#       future step wires attention-state.sh's hook producers to write here
#       instead of its own separate pending.json. A blocking item can NEVER
#       be marked "read" (state is always "unread" until it's removed by its
#       own resolution hook firing) — viewing it doesn't discharge it, only
#       responding to the actual prompt does. istatus resolve CAN force-
#       remove one as a manual escape hatch (mirroring the old clear-pane
#       command for a lost Esc-interrupt), but that's a deliberate CLI
#       override, not part of the normal lifecycle, and it warns loudly that
#       the underlying prompt was NOT actually answered.
#     - "notice": the agent's own judgment call that something is worth the
#       human's attention (istatus decide), or a passive FYI (a dispatched
#       task finishing). Has a `priority` (high/normal/low) set by whoever
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
#   the popup) is DERIVED, never stored here: any unread item of either
#   kind, OR any blocking item regardless of state (it can't be "read" away).
#   That derivation currently still happens by bridging to
#   claude-tmux-attention's human.requested/mark-viewed (see cmd_decide /
#   _maybe_clear_attention below) — a transitional step until the hook
#   producers themselves are migrated to write blocking items directly into
#   this file, at which point pending.json's human.requested goes away
#   entirely and the bridge calls here are deleted.
#
# State file: ~/.claude-tmux-attention/status/<session_id>.json
#   { summary: "<current work/thinking, or empty>",
#     items: [ { id, kind, text, state, priority?, created_at }, ... ] }
#   kind: "blocking" | "notice". state: "unread" | "read" (blocking is
#   always "unread"). priority (notice only): "high" | "normal" | "low".
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
#     Adds a "notice" item (default priority: normal) AND raises the
#     attention flag (human.requested on this pane) — same producer iflag
#     used. Prints the new item's id.
#
#   istatus defer <id-or-#>
#     Marks a notice "read": seen, deliberately left for later. Stays in the
#     list (doesn't disappear), but drops out of the unread/attention count.
#     Refuses on a blocking item — those can't be deferred, only resolved by
#     actually responding to the underlying prompt.
#
#   istatus resolve <id-or-#>
#     Removes the item entirely. For a notice, this is "done, acted on." For
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
# Reason/summary text is read from STDIN, never an argument — same rationale
# as isend/iflag: the permission scanner inspects the raw command line before
# shell quoting, so metachars in an argument (globs, braces-with-quotes) trip
# a prompt even with Bash(istatus:*) allowlisted. Only `decide [--priority=…]`
# / `defer <id>` / `resolve <id>` / `summary` / `show` appear as args; free
# text never does.
#
# Exit: 0 on success (each mutator prints a short confirmation); non-zero with
# a message on stderr on misuse or a missing dependency — never silent.

set -euo pipefail

PLUGIN_CACHE="$HOME/.claude/plugins/cache/gusto-claude-code/claude-tmux-attention"
STATUS_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/status"
PANES_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}/panes"
LOCK_DIR="${CLAUDE_TMUX_ATTENTION_DIR:-$HOME/.claude-tmux-attention}"

die() { printf 'istatus: %s\n' "$*" >&2; exit 1; }
warn() { printf 'istatus: WARNING: %s\n' "$*" >&2; }

sid="${CLAUDE_CODE_SESSION_ID:-}"
[[ -n "$sid" ]] \
  || die "CLAUDE_CODE_SESSION_ID not set (not inside a Claude session?) — cannot update status"

mkdir -p "$STATUS_DIR"
STATUS_FILE="$STATUS_DIR/${sid}.json"
LOCK_FILE="$LOCK_DIR/status-${sid}.lock"
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
# drop the dead key either way, items (if any) take precedence.
if jq -e 'has("decisions") or (has("items") | not)' "$STATUS_FILE" >/dev/null 2>&1; then
  migrate_tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq '
    { summary: (.summary // ""),
      items: (
        if has("items") then .items
        else [ (.decisions // [])[]
          | { id, kind: "notice", text, state: "unread", priority: "normal", created_at }
        ]
        end
      )
    }
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
# as iflag). TRANSITIONAL: only decide (request-human) and the
# zero-unread-remaining case (mark-viewed) still call into this — see the
# design note at the top of the file. A later step migrates the hook
# producers themselves to write "blocking" items directly into THIS file,
# at which point this bridge and pending.json's human.requested both go away.
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

_unread_count() {
  jq '[.items[] | select(.kind == "blocking" or .state == "unread")] | length' "$STATUS_FILE"
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

_remove_item() {
  local id="$1" tmp
  tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq --arg id "$id" '.items = [.items[] | select(.id != $id)]' \
    "$STATUS_FILE" > "$tmp" || { rm -f "$tmp"; die "failed to resolve item"; }
  mv "$tmp" "$STATUS_FILE"
}

_item_kind() {
  jq -r --arg id "$1" '[.items[] | select(.id == $id)][0].kind // ""' "$STATUS_FILE"
}

_set_summary() {
  local tmp
  tmp=$(mktemp "${STATUS_FILE}.XXXXXX")
  jq --arg s "$1" '.summary = $s' "$STATUS_FILE" > "$tmp" \
    || { rm -f "$tmp"; die "failed to set summary"; }
  mv "$tmp" "$STATUS_FILE"
}

# TRANSITIONAL bridge to claude-tmux-attention — see the design note up top
# and the comment on _resolve_state_sh. Clears human.requested only when
# nothing in this session's list is unread any longer.
_maybe_clear_attention() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  [[ "$(_unread_count)" -eq 0 ]] || return 0
  local state_sh
  state_sh=$(_resolve_state_sh)
  "$state_sh" mark-viewed "$TMUX_PANE" || true
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

  # Raise human.requested on this pane, same producer iflag used. cwd is
  # best-effort context, same as iflag. TRANSITIONAL — see design note.
  local state_sh payload
  state_sh=$(_resolve_state_sh)
  payload=$(jq -nc --arg sid "$sid" --arg msg "$text" --arg cwd "$PWD" \
    '{session_id: $sid, message: $msg, cwd: $cwd}') || die "failed to build payload"
  printf '%s' "$payload" | "$state_sh" request-human || die "attention-state.sh request-human failed"

  printf 'istatus: notice recorded (id=%s, priority=%s) — "%s"\n' "$id" "$priority" "$text"
}

cmd_defer() {
  local ref="${1:-}"
  [[ -n "$ref" ]] || die "usage: istatus defer <id-or-#>"
  [[ $# -le 1 ]] || die "usage: istatus defer <id-or-#> (one at a time)"

  local id
  id=$(with_lock _find_item_or_die "$ref") || exit 1

  local kind
  kind=$(_item_kind "$id")
  [[ "$kind" != "blocking" ]] \
    || die "item $id is blocking (a pending permission prompt or menu) — it can't be deferred, only resolved by responding to it directly"

  with_lock _set_item_state "$id" read
  printf 'istatus: deferred (marked read) %s\n' "$id"
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
  _maybe_clear_attention

  local remaining
  remaining=$(_item_count)
  printf 'istatus: resolved %s (%s item(s) remaining)\n' "$id" "$remaining"
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
    resolve)  cmd_resolve "$@" ;;
    summary)  cmd_summary "$@" ;;
    show)     cmd_show "$@" ;;
    *)
      echo "usage: istatus {decide [--priority=high|normal|low]|defer <id-or-#>|resolve <id-or-#>|summary|show}" >&2
      echo "  istatus decide [--priority=P] <<'EOF' … EOF   add a notice + flag" >&2
      echo "  istatus defer <id-or-#>                        mark a notice read (not blocking items)" >&2
      echo "  istatus resolve <id-or-#>                       remove an item" >&2
      echo "  istatus summary <<'EOF' … EOF                  replace the current-work summary" >&2
      echo "  istatus show                                    print current state as JSON" >&2
      exit 2
      ;;
  esac
}

main "$@"
