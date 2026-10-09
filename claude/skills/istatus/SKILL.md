---
name: istatus
description: Maintain this session's live status (open decisions Adam needs to make, plus a one-line summary of current work) so a sidebar pane next to this session shows it without Adam having to ask "what do you need me for?" or scroll back through the transcript. This is standing behavior, not something Adam invokes by name — apply it any time this session raises a question/decision for Adam, learns the answer to one it raised, or materially changes what it's working on. Supersedes iflag as the flagging mechanism (iflag now aliases to istatus decide under the hood).
---

# istatus — live per-session status for the sidebar

Adam runs many concurrent Claude sessions across tmux panes. Historically, switching to a session that flagged him meant re-reading transcript to reconstruct *what* it needs and *why* — the flag said "come look," not what to look at. `istatus` fixes that: each session keeps a small, current-only record (open decisions + a work summary) in `~/.claude-tmux-attention/status/<session_id>.json`, and an optional sidebar pane next to this session renders it live, refreshing within a second or two of any change.

**The record is current-relevance-only, not a log.** Old decisions fall off when resolved; the summary is overwritten, not appended. A sidebar showing everything this session has ever asked is worse than no sidebar — it's the same wall of text the sidebar exists to avoid. This is the one discipline rule that matters most: **resolve what you raise.**

## The three commands

All take free text on stdin, never as a CLI argument (same reason as `isend`/`iflag`: the permission scanner inspects the raw command string before shell quoting, so metacharacters in an argument trip a prompt even under an allowlisted `Bash(istatus:*)` rule).

- **`istatus decide <<'EOF' ... EOF`** — raise an open decision. Adds it to this session's items as a `notice` (unread, normal priority), which the tmux status line counts as "flagged" and the popup lists as "wants you". Prints the new decision's id, e.g. `istatus: notice recorded (id=20261001T153430Z-75697, priority=normal) — "..."`. Keep the text a short, specific pointer to the actual question — the sidebar shows this verbatim, so it should be enough on its own to orient Adam, not the full reasoning behind it.

- **`istatus resolve <id>`** — remove a decision once it's answered. Use the id printed by `decide`. Once no unread notice is left, the session stops counting as "flagged" in the status line. Resolving an id that doesn't exist is an error, not a silent no-op — if that happens, it's almost always a stale id from an earlier turn, worth noticing rather than ignoring.

- **`istatus summary <<'EOF' ... EOF`** — overwrite the one-line "what I'm currently doing/thinking" string. No history, no accumulation — call it when what you're working on materially changes, not on every tool call. This is what lets someone glance at the sidebar and know what's happening in a session they haven't looked at in an hour, without reading anything else.

`istatus show` prints the current state as JSON (`{summary, items}`) — mainly for the sidebar renderer, but useful to check what you've already said before deciding whether an update is warranted.

`istatus defer <id>` marks a notice read (still listed, no longer flagged) and `istatus undefer <id>` marks it unread again; `defer --all` marks every notice read. These are mostly Adam's, from outside the session: `istatus --pane <pane> {defer|undefer|resolve|show}` acts on whichever session occupies that pane, which is how the popup and the sidebar dismiss a notice without the session's help. `decide` and `summary` refuse `--pane`, since they speak for the session.

## When to call `decide`

Same trigger as the old `iflag` rule in CLAUDE.md: **you are now waiting on Adam and will do nothing further until he responds.** A plain-text question at the end of a turn doesn't by itself tell Adam you're blocked — he has no way to know unless he happens to be looking at this pane. Call `istatus decide` as part of ending that turn, with the question as a short pointer (the full question still goes in your chat response; the flag just says "come look, and here's the gist").

Don't call `decide` for a turn that reports progress and keeps working, or one that offers optional next steps you could proceed on yourself without Adam. The bar is the same as it always was for flagging: default to raising it when genuinely blocked and idle, even for something that feels minor — a missed decision point is worse than one Adam glances at and already knew the answer to.

If more than one thing is open at once (not unusual for a `/pivotal` anchor juggling several pairs), call `decide` once per distinct item rather than bundling several questions into one entry — the sidebar is a list for a reason, and a reader should be able to resolve them independently as answers come in.

## When to call `resolve`

As soon as you have Adam's answer and have acted on it (or confirmed there's nothing further to do), resolve the corresponding id. Don't wait for the conversation to wind down, and don't bundle several resolves for "later" — a stale open decision sitting in the sidebar after Adam already answered it is exactly the failure mode this tool exists to prevent, and it erodes trust in the sidebar faster than having no sidebar at all. If you're not sure which id an answer corresponds to, `istatus show` lists the open ones with their text.

A decision that turns out to be moot (the question resolved itself, the premise changed) still gets `resolve`d — "no longer relevant" is a resolution, not a reason to leave it sitting.

## When to call `summary`

Whenever what you're actively doing changes in a way that would surprise someone glancing at the sidebar after not having looked in a while — starting a new phase of work, picking up a different task, finishing something and moving to the next. Not on every tool call, not as a running log — it's a single line that's always overwritten, so stale information here is actively misleading, not just unhelpful. If nothing's materially changed since your last `summary` call, don't call it again just because a turn passed.

## Relationship to `iflag`

`iflag` still works exactly as before from the caller's side (reason on stdin, same semantics) — it now forwards directly to `istatus decide` under the hood, so there's one flagging mechanism instead of two that could drift apart. There's no reason to call `iflag` instead of `istatus decide` going forward; they do the same thing, but `istatus decide` is the name that makes clear it's also populating the sidebar, not just lighting up the attention bar.

## Getting a sidebar

`istatus` writes its state regardless of whether a sidebar is actually displayed anywhere — the record is useful on its own (Adam can always `istatus show` by hand), and the sidebar is an optional viewer on top of it. To attach a live sidebar to a pane: `~/.workstation/claude/skills/istatus/scripts/istatus-attach.sh` (run from inside the pane to attach to, or pass a pane id as an argument to attach from elsewhere). This is Adam's call to make, not something a session should do to its own pane unprompted.

## What else writes this file: the hooks

The commands above are what a session runs on purpose. Other items in the same file come from Claude Code hooks, wired in global `~/.claude/settings.json`, which call `scripts/istatus-hook.sh`:

- **A permission prompt or an AskUserQuestion menu** (`Notification` with the `permission_prompt` matcher, and `PreToolUse` for `AskUserQuestion`) adds a **blocking** item with the prompt's or the question's text. A blocking item is never marked read; it clears when the prompt is answered (a tool finishing or failing, a prompt being submitted, or the session ending; `PermissionDenied` is wired to clear it too, but that it fires on an interactive deny is not confirmed yet), and as a backstop when the session stops, since once a turn has stopped nothing can still be pending. (A background subagent's prompt that is still up when its parent's next turn stops is cleared too, while the prompt remains.) A subagent's tools finishing do not clear the parent's permission prompt. An `AskUserQuestion` menu's own `permission_prompt` Notification (it IS a tool use, so Claude Code raises both) arrives shortly after the menu's own add (about 7s, when observed) and is skipped rather than recorded as a second blocking item for the same menu.
- **`SessionStart`** records which session occupies the pane (`panes/<pane>.session_id`), which is how the other tools find a session from a pane.
- **A hub dispatch** adds a `hub.dispatched` notice and the `Stop` hook turns it into an unread `hub.ready` one; see the hub skill.
- Every hook event also touches `heartbeat/<session_id>`, which `hub/scripts/attention-doctor.sh` uses to spot hooks that have stopped firing.

Hooks hot-reload: a session already running when they're wired picks them up without a restart (confirmed live — its heartbeat starts moving immediately), and the doctor reads it as healthy, not dead. What it's actually missing until it calls istatus or hits a permission prompt is the pane occupancy pointer, which only `SessionStart` writes — and that fires on a fresh start/resume/clear/compact/fork, not retroactively for a session already running. So it stays dark (no row in the status line or the popup) until one of those happens.

## Where it shows

All of these read through `scripts/istatus-inbox.sh list`, which lists the live sessions (a session counts only while a live tmux pane's occupancy pointer names it, and that pane is where it shows; a pane taken over by `/resume` drops the old session, and the pane field inside a status file is not consulted) with one `state` each: `blocked`, `flagged` (an unread notice that is not from the hub), `ready`, `dispatched`, or empty.

- **The tmux status line**, `scripts/istatus-status.sh`: one colored block per non-empty state, in that order, counting sessions. Colors and glyphs can be overridden with `ISTATUS_<STATE>_FG`, `_BG` and `_GLYPH`. tmux runs the script, so those variables have to be in the tmux server's environment (for example `set-environment -g ISTATUS_BLOCKED_GLYPH '!'` in `tmux.conf`), not just exported in a shell.
- **The popup**, `prefix` then `A` `A`, `scripts/istatus-popup.sh`: the rows, most urgent first, with the reason for each; picking one jumps to the pane and marks its finished dispatch viewed. Jumping does not clear a decide notice or a blocking item, so a flagged session stays flagged until it resolves its own notice, or until Adam dismisses the row with `ctrl-x`, which marks its notices read (`istatus --pane <pane> defer --all`) and reloads the list. A blocking item survives a dismiss.
- **Focusing a pane** (a `pane-focus-in` tmux hook) marks that pane's finished hub dispatch read. Only that; a decide notice or a blocking item still needs an answer. The hub's `capture` goes one step further and removes the finished dispatch (`istatus-hook.sh consume`), because that is when the hub has read the result.
- **`prefix` `A` `C`** force-clears the blocking items of the current pane, for a prompt you interrupted with Esc (that fires no hook, so the item would stay). It does not answer the prompt, it only stops istatus tracking it.
