---
name: hub
description: Adam's orchestration hub for working across many repos at once. Maps the live tmux/tmuxinator sessions, dispatches prompts into a repo's live Claude pane (gated — always confirms first), auto-starts a repo's session if needed, navigates/hands off to a repo's Claude window, and reads back a pane's results on demand. Use when Adam asks "what's running", "show me my sessions/repos", "dispatch this to <repo>", "send <repo> a prompt", "what did <repo> come back with", "take me to <repo>", or invokes /hub. Intended to run from the Hub tmux session (rooted at ~/workspace) as a general scratch/Q&A + coordination space.
---

# Hub

Adam runs many concurrent Claude sessions — at least one per repo, across tmux sessions, windows, and panes. The hub is a single session (the `Hub` tmuxinator project, rooted at `~/workspace`) that serves two purposes:

1. **General scratch / Q&A space** — ask anything here without spending a repo session's context on it. This is a normal Claude session; it carries the global `~/.claude/CLAUDE.md` and none of a repo's baggage.
2. **Orchestrator** — see what's running, dispatch work into specific repos' live Claude panes, navigate between them, and read back results.

The hub never tries to *be* the repo sessions or proxy their conversation. It **injects a turn** into a repo's live Claude pane (the same as if Adam typed there), then leaves that session to do its work in its own deep context. Adam's repo sessions stay exactly as he runs them today.

## Environment model (how Adam's tmux is laid out)

- Each repo is a **tmuxinator project** at `~/.workstation/tmuxinator/<project>.yml`, with a `name:` (display name, e.g. "Gusto Eventing") and `root:` (e.g. `~/workspace/gusto-eventing`).
- Each project = one tmux **session** named after `name:`.
- Within a session, the conventional windows are `vim, server, db, console, shell, shell2, claude`. **The `claude` window is the dispatch target** — it auto-launches `claude` on session start.
- The display name, the tmuxinator config basename, and the repo dir all differ (e.g. config `gusto-eventing` → session "Gusto Eventing" → dir `gusto-eventing`). Always resolve via the helper scripts; never hardcode the mapping.

## Helper scripts

Two scripts under this skill's `scripts/` dir do all tmux interaction. Prefer them over ad-hoc `tmux` calls.

- **`scripts/hub-map.sh`** — prints a JSON array of every tmuxinator project with its live state: `project`, `name`, `root`, `running`, `claude_target` (`"<session>:<window>"` or `""`), `claude_panes`. Pure read.
- **`scripts/hub-dispatch.sh`** — the mutation/navigation surface:
  - `target <project>` → resolves to `"<session>:<window>"` of the claude window, **auto-starting the session via tmuxinator if it isn't running**. Prints the target.
  - `send <target>` (prompt on stdin) → types the prompt into the target and presses Enter. **Does not confirm — the skill must confirm first (see below).**
  - `go <target>` → switches the active tmux client to that window (navigate / hand off).
  - `capture <target>` → prints the visible pane contents (for read-back).

## Behaviors

### Map — "what's running?", "show me my repos", `/hub`

Run `scripts/hub-map.sh`, then present a concise table: which projects are running, which have a live Claude pane, pane counts, and which (if any) the user is currently in. Note any project that isn't running. Don't dump raw JSON.

### Dispatch — "send <repo> X", "dispatch this to <repo>"

Dispatch is **always gated**. Never call `hub-dispatch.sh send` without an explicit OK in the conversation. Steps:

1. Resolve the project with `hub-dispatch.sh target <project>` (this auto-starts the session if needed — if it had to start one, say so).
2. **Show Adam the exact prompt and the exact target** (`"<session>:<window>"`) and ask for confirmation. Tune the prompt with him if he wants.
3. Check the target isn't one he's actively typing in. If `hub-map.sh`/`tmux` shows the target pane is the focused pane, warn — sending would collide with his input.
4. On OK, pipe the prompt into `hub-dispatch.sh send <target>` via stdin (use a heredoc — `printf '%s' "$prompt" | hub-dispatch.sh send "$target"` is fine too).
5. After sending, tell him it's dispatched and that he can ask you to read it back later or navigate there. **Do not poll or auto-read** — read-back is pull-on-command.

A natural driver: run `/today` first, let its priorities suggest what to dispatch where, then dispatch each with confirmation.

### Read back — "what did <repo> come back with?", "read me <repo>"

Resolve the target, run `hub-dispatch.sh capture <target>`, and summarize the relevant part (usually the latest assistant response). The pane has settled by the time Adam asks, so the capture is clean. Offer to navigate him there if he wants to continue hands-on.

### Navigate / hand off — "take me to <repo>", "go to <repo>"

Resolve the target and run `hub-dispatch.sh go <target>`. This hands Adam into the live session; the hub's job is done for that thread.

## Guardrails

- **Confirm before every `send`.** The hub injects a turn into a real session; an unconfirmed send can clobber what Adam is typing or derail a session mid-task. Show prompt + target, wait for OK.
- **Don't auto-parse or poll panes.** Reading a dispatched pane is pull-on-command. (Automatic "results ready" notification is a future addition that depends on the `claude-attention-core` work in `Gusto/claude-code`; until then, read-back is manual.)
- **Resolve names via the scripts.** Display name ≠ config name ≠ repo dir. Never guess the mapping.
- **One writer per pane.** Only dispatch to a pane Adam isn't actively typing in.
- **Auto-start is allowed** (per Adam's choice): if a target isn't running, `target` starts it. Tell Adam when a dispatch caused a session to start.

## Future (not yet built)

- Automatic notification when a dispatched pane finishes (flip `task.dispatched` → `task.ready`), via the `claude-attention-core` fact layer + a personal `Stop` hook. See `~/workspace/claude-code/plans/attention-core-split-and-hub.md`. Until that lands, the hub dispatches and Adam reads back on demand.
