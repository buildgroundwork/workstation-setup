---
name: istatus
description: Maintain this session's live status (open decisions Adam needs to make, plus a one-line summary of current work) so a sidebar pane next to this session shows it without Adam having to ask "what do you need me for?" or scroll back through the transcript. This is standing behavior, not something Adam invokes by name — apply it any time this session raises a question/decision for Adam, learns the answer to one it raised, or materially changes what it's working on. Supersedes iflag as the flagging mechanism (iflag now aliases to istatus decide under the hood).
---

# istatus — live per-session status for the sidebar

Adam runs many concurrent Claude sessions across tmux panes. Historically, switching to a session that flagged him meant re-reading transcript to reconstruct *what* it needs and *why* — the flag said "come look," not what to look at. `istatus` fixes that: each session keeps a small, current-only record (open decisions + a work summary) in `~/.claude-tmux-attention/status/<session_id>.json`, and an optional sidebar pane next to this session renders it live, refreshing within a second or two of any change.

**The record is current-relevance-only, not a log.** Old decisions fall off when resolved; the summary is overwritten, not appended. A sidebar showing everything this session has ever asked is worse than no sidebar — it's the same wall of text the sidebar exists to avoid. This is the one discipline rule that matters most: **resolve what you raise.**

## The three commands

All take free text on stdin, never as a CLI argument (same reason as `isend`/`iflag`: the permission scanner inspects the raw command string before shell quoting, so metacharacters in an argument trip a prompt even under an allowlisted `Bash(istatus:*)` rule).

- **`istatus decide <<'EOF' ... EOF`** — raise an open decision. Adds it to this session's queue and raises the attention flag (`human.requested`) on this pane, same as `iflag` used to do directly. Prints the new decision's id, e.g. `istatus: decision recorded (id=20261001T153430Z-75697) — "..."`. Keep the text a short, specific pointer to the actual question — the sidebar shows this verbatim, so it should be enough on its own to orient Adam, not the full reasoning behind it.

- **`istatus resolve <id>`** — remove a decision once it's answered. Use the id printed by `decide`. If this was the last open decision on the pane, resolving it also clears the attention flag (no human.requested state lingers after everything's been addressed). Resolving an id that doesn't exist is an error, not a silent no-op — if that happens, it's almost always a stale id from an earlier turn, worth noticing rather than ignoring.

- **`istatus summary <<'EOF' ... EOF`** — overwrite the one-line "what I'm currently doing/thinking" string. No history, no accumulation — call it when what you're working on materially changes, not on every tool call. This is what lets someone glance at the sidebar and know what's happening in a session they haven't looked at in an hour, without reading anything else.

`istatus show` prints the current state as JSON (`{summary, decisions}`) — mainly for the sidebar renderer, but useful to check what you've already said before deciding whether an update is warranted.

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
