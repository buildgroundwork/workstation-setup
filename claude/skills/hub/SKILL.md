---
name: hub
description: Adam's orchestration hub for working across many repos at once. Maps the live tmux/tmuxinator sessions, dispatches prompts into a repo's live Claude pane (gated — always confirms first), auto-starts a repo's session if needed, tracks which dispatched sessions have finished vs. are still working, navigates/hands off to a repo's Claude window, and reads back a pane's results on demand. Use when Adam asks "what's running", "show me my sessions/repos", "dispatch this to <repo>", "send <repo> a prompt", "what's ready / anything come back?", "what did <repo> come back with", "take me to <repo>", or invokes /hub. Intended to run from the Hub tmux session (rooted at ~/workspace) as a general scratch/Q&A + coordination space.
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
  - `send <target>` (prompt on stdin) → types the prompt into the target, presses Enter, and **arms the pane** (`kind: task.dispatched`) so its finish can be detected. **Does not confirm — the skill must confirm first (see below).**
  - `go <target>` → switches the active tmux client to that window (navigate / hand off).
  - `capture <target>` → prints the visible pane contents (for read-back).
  - `ready` → lists dispatched panes by state: which have **finished** (`task.ready` — the Stop hook flipped them) vs. still **in-flight** (`task.dispatched`), with each pane's `session:window` and original prompt. The read-side of dispatch.
- **`scripts/hub-wait.sh <target> [timeout]`** — blocks until a dispatched pane finishes (flips to `task.ready`), then prints its settled contents. Polls the state file in a cheap shell loop (not Claude's context), so it's the babysitting primitive for multi-step orchestration. Exit 0 = finished (+ capture), 2 = timeout, 3 = pane wasn't an armed dispatch.
- **`scripts/hub-stop-hook.sh`** — the personal `Stop` hook (wired in global `~/.claude/settings.json`, not invoked directly): when a session stops, flips its pane `task.dispatched` → `task.ready` if armed, else no-ops. This is what makes finish-detection work.

## Behaviors

### Map — "what's running?", "show me my repos", `/hub`

Run `scripts/hub-map.sh`, then present a concise table: which projects are running, which have a live Claude pane, pane counts, and which (if any) the user is currently in. Note any project that isn't running. Don't dump raw JSON.

### Dispatch — "send <repo> X", "dispatch this to <repo>"

Dispatch is **always gated**. Never call `hub-dispatch.sh send` without an explicit OK in the conversation. Steps:

1. Resolve the project with `hub-dispatch.sh target <project>` (this auto-starts the session if needed — if it had to start one, say so).
2. **Show Adam the exact prompt and the exact target** (`"<session>:<window>"`) and ask for confirmation. Tune the prompt with him if he wants.
3. Check the target isn't one he's actively typing in. If `hub-map.sh`/`tmux` shows the target pane is the focused pane, warn — sending would collide with his input.
4. On OK, pipe the prompt into `hub-dispatch.sh send <target>` via stdin (use a heredoc — `printf '%s' "$prompt" | hub-dispatch.sh send "$target"` is fine too).
5. After sending, tell him it's dispatched. The `send` armed the pane (`task.dispatched`), so when that session finishes, the personal `Stop` hook flips it to `task.ready` — ask the hub "what's ready?" to see finished dispatches. Still **don't auto-poll a pane's text** — read-back of *content* is pull-on-command; only the finished/in-flight *state* is tracked automatically.

A natural driver: run `/today` first, let its priorities suggest what to dispatch where, then dispatch each with confirmation.

### Results ready — "what's ready?", "anything come back?", "what's still working?"

Run `hub-dispatch.sh ready`. It lists dispatched panes split by state — `task.ready` (finished, results waiting) vs. `task.dispatched` (still working) — each with its `session:window` and the prompt it was given. Present it concisely: which dispatches have finished and are worth reading back, which are still in flight. For a finished one, offer to read it back (`capture`) or navigate there (`go`). This is the payoff of the finish-detection layer: the hub knows *when* a dispatched session is done without parsing its TUI.

### Orchestrate — "run this task in <repo> and watch it", "dispatch and babysit", multi-step delegation

For a task that's more than one dispatch — where you want to send a prompt, wait for it to finish, read the result, and decide whether to send a follow-up — the hub runs a **delegation loop**. The hub session (this Claude) holds the task; the waiting is done cheaply by `hub-wait.sh`, not by burning turns polling.

The loop, per dispatched step:

1. **Dispatch** the step (gated as always — show Adam the prompt + target, get OK, then `send`). `send` arms the pane.
2. **Wait** with `hub-wait.sh <target> [timeout]`. It blocks, then returns when the step **finishes** (exit 0, prints the settled pane) — or **blocks on its own permission prompt** (exit 4: the dispatched session hit a permission it doesn't have; tell Adam to approve in that pane, then re-wait) — or **times out** (exit 2). Run it so you get control back at any of those (background it or let it block between turns); don't sit in a Claude polling loop. Exit 4 is common for real tasks — a dispatched session that needs to run a not-allowlisted command will stop and ask; surface that to Adam rather than waiting blind.
3. **Read + decide.** From the captured result, decide: task done → report back to Adam; needs a follow-up → formulate the next prompt and **re-confirm with Adam before sending it** (every `send` stays gated, even mid-orchestration — a follow-up prompt is still injecting a turn into a real session).
4. Repeat until the task is complete, then summarize the whole arc for Adam.

Keep Adam in the loop: he sees each prompt before it's sent, and you report the result of each step. The orchestrator removes the *waiting* and the *plumbing*, not Adam's oversight of *what gets said*.

### Read back — "what did <repo> come back with?", "read me <repo>"

Resolve the target, run `hub-dispatch.sh capture <target>`, and summarize the relevant part (usually the latest assistant response). The pane has settled by the time Adam asks, so the capture is clean. Offer to navigate him there if he wants to continue hands-on.

### Navigate / hand off — "take me to <repo>", "go to <repo>"

Resolve the target and run `hub-dispatch.sh go <target>`. This hands Adam into the live session; the hub's job is done for that thread.

## Guardrails

- **Confirm before every `send`.** The hub injects a turn into a real session; an unconfirmed send can clobber what Adam is typing or derail a session mid-task. Show prompt + target, wait for OK.
- **Don't auto-parse or poll a pane's text.** Reading a dispatched pane's *content* is pull-on-command (via `capture`). What *is* tracked automatically is the dispatch's *state*: `send` arms the pane, and a personal `Stop` hook flips it to `task.ready` on finish — surfaced via `ready`, no TUI parsing. So "is it done?" is automatic; "what did it say?" is still on request.
- **Resolve names via the scripts.** Display name ≠ config name ≠ repo dir. Never guess the mapping.
- **One writer per pane.** Only dispatch to a pane Adam isn't actively typing in.
- **Auto-start is allowed** (per Adam's choice): if a target isn't running, `target` starts it. Tell Adam when a dispatch caused a session to start.

## Finish detection (built)

When `send` dispatches, it arms the target pane as `task.dispatched` (via `claude-tmux-attention`'s `arm`). A personal `Stop` hook (`scripts/hub-stop-hook.sh`, wired in global `~/.claude/settings.json`) fires when *any* session stops; if the stopping pane was armed, it flips `task.dispatched` → `task.ready`. The `ready` subcommand reads those facts back. The `Stop` hook lives in the personal layer, not the shipped plugin — it no-ops unless a pane was armed, so it costs other marketplace users nothing. See `~/workspace/claude-code/plans/attention-core-split-and-hub.md`.

## Orchestration (built)

The "Orchestrate" behavior above is the long-lived dispatch task-runner: the hub session owns a multi-step task and drives dispatch → `hub-wait.sh` → read → decide → (gated) follow-up, reporting back at the end. It is deliberately **not** a subagent — subagents are synchronous and bounded, and would burn context polling a pane for the duration; the persistent hub session plus the cheap shell-level `hub-wait` is the right shape. Adam's per-`send` confirmation is preserved throughout.
