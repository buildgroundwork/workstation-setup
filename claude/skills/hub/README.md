# Hub

A personal control center for working across many Claude Code sessions at once.

## What is this?

Adam runs one Claude Code session per repo, each in its own tmux session, all day. The **hub** is one extra session — a dedicated tmux session rooted at `~/workspace` — that doesn't work on any single repo. Instead it *orchestrates* the others:

- **See** which repos are running and what state each session is in (working / waiting on you / idle / finished a dispatched task).
- **Dispatch** a prompt into a specific repo's live Claude pane — as if you'd typed it there yourself — without leaving the hub.
- **Know when a dispatched session finishes**, without watching it, and read its result back on demand.
- **Delegate a whole multi-step task** to a repo session: the hub sends a prompt, waits for it to finish, reads the result, and (with your OK) sends the follow-up — babysitting it for you.

It also doubles as a general scratch/Q&A space: it carries only the global `~/.claude/CLAUDE.md`, none of a repo's context, so you can ask anything here without spending a repo session's context on it.

The hub never tries to *be* the repo sessions or proxy their conversations. It injects a turn into a repo's live pane and lets that session do its work in its own deep context — exactly as if you'd typed there.

## Setup

The hub depends on a few pieces. On a fresh machine, in order:

1. **The istatus hooks.** They are wired in global `~/.claude/settings.json` (`Notification`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `UserPromptSubmit`, `SessionStart`, `SessionEnd` and `Stop`) and call `skills/istatus/scripts/istatus-hook.sh`. They record each session's status under `~/.claude-tmux-attention/` (the directory keeps that name), which is what the hub reads. `tmux.conf` points the status line, the popup chord and a pane-focus hook at the istatus scripts. Hooks hot-reload: a session already running when they're wired picks them up without a restart (confirmed live — its heartbeat starts moving immediately), so `scripts/attention-doctor.sh` reads it as healthy, not dead. What it's actually missing until it calls istatus or hits a permission prompt is the pane occupancy pointer (written by `SessionStart`, which only fires on a fresh start/resume/clear/compact/fork — not retroactively for an already-running session), so it's dark (no row in the status line or popup) until one of those happens. The scripts need `jq`, `tmux`, `fzf` and `flock`, all in the `Brewfile`.
    - **A machine also running Runlayer's `aiwatch`** (its own `PreToolUse`/`PostToolUse`/`PostToolUseFailure` hooks) needs care when hand-merging `settings.json`: Runlayer's hook reconcile periodically restores ITS OWN hook group to canonical form on these shared events, which silently drops anything merged INTO that same group object. Add istatus's hook as its own separate `{ "hooks": [...] }` entry in the array, alongside Runlayer's group, never combined into one. (Bit twice in one day before this was understood — the fix held up across a real 900s reconcile cycle once each event's istatus and Runlayer entries were split into separate groups.)
2. **The workstation tmuxinator session.** `~/.workstation/tmuxinator/workstation.yml` defines it (`name: Workstation`, root `~/.workstation`, `vim` in window 0, `INTER_SESSION_NAME=workstation claude --continue` in the claude window). The `mux` boot script starts it first (`tmuxinator start workstation`). Formerly "Hub" rooted at `~/workspace` — repurposed from a dispatch controller into the whole-workstation config session as peer messaging replaced top-down dispatch; the bus identity is `workstation`.
3. **This skill** lives at `~/.claude/skills/hub/` (symlinked from `~/.workstation/claude/skills/hub/`, so it's version-controlled and reproduced by `setup.sh`).

## Using it

Talk to the hub session in plain language — the `hub` skill routes the request:

| You say | What happens |
|---|---|
| "what's running?", `/hub` | Maps live sessions + their state. |
| "dispatch this to gusto-eventing", "send web a prompt" | Shows you the prompt + target, confirms, then types it into that repo's Claude pane (and arms it for finish-detection). |
| "what's ready?", "anything come back?" | Lists which dispatched sessions have finished vs. are still working. |
| "what did gusto-pro come back with?" | Reads back (captures) that pane and summarizes it. |
| "run this task in <repo> and watch it" | Delegation loop: dispatch → wait for finish → read → (with your OK) follow up → report. |
| "take me to adr" | Switches you into that repo's Claude window. |

**Dispatch is always gated:** the hub shows you the exact prompt and target and waits for your OK before sending — even for follow-up prompts mid-orchestration. It's injecting a real turn into a real session; an unconfirmed send could clobber what you're typing or derail a session mid-task.

## How it works (architecture)

The hub is a thin coordination layer over tmux and the istatus status files. Everything crosses through those files; nothing screen-scrapes a session's TUI to decide what's happening.

### The scripts

All under `scripts/`:

- **`hub-map.sh`** — reads the tmuxinator configs + live tmux and emits JSON: each project's display name, root, whether it's running, and its claude window target. Pure read. The name↔config↔dir mapping is resolved here, never guessed (display name ≠ config basename ≠ repo dir).
- **`hub-dispatch.sh`** — the mutation/navigation surface: `target` (resolve + auto-start), `send` (type a prompt + arm the pane), `go` (navigate), `capture` (read-back), `ready` (list finished vs. in-flight dispatches).
- **`hub-status.sh`** / **`hub-status-pane.sh`** — the live dashboard: a compact, auto-sizing pane showing each running session's state and context usage.
- **`hub-wait.sh`** — blocks until a dispatched pane finishes, then prints its settled contents. The babysitting primitive — it polls the istatus inbox in a cheap shell loop so the hub's Claude context isn't spent waiting. Exit 0 finished, 2 timed out, 3 the pane is not (or is no longer) an armed dispatch, 4 blocked on its own permission prompt.
- **`attention-doctor.sh`** — reports sessions whose istatus hooks have silently stopped firing, by comparing each session's hook heartbeat with its transcript. Detection only.

### The dispatch → finish loop

This is the core mechanism:

1. **Dispatch.** `hub-dispatch.sh send` types the prompt into the target pane, then calls `istatus-hook.sh arm <pane>` with the prompt on stdin. That adds a read, low-priority `hub.dispatched` notice (the prompt as its text) to the status file of the session that occupies the pane. The session is found through the pane's occupancy pointer, which the `SessionStart` hook writes, so a session that started before the hooks were wired may have none and the arm is silently dropped.
2. **Finish.** When that session stops (finishes its turn), Claude fires its `Stop` hooks, and `istatus-hook.sh stop` turns its `hub.dispatched` notice into an unread `hub.ready` one. If there is no dispatched notice — the overwhelmingly common case — it exits early without taking the lock.
3. **Surface.** `hub-dispatch.sh ready` reads those facts back from the istatus inbox: `task.ready` = finished and not yet read back by `capture` (focusing the pane does not clear it), `task.dispatched` = still working. `hub-wait.sh` blocks on the same notice for orchestration. A finished dispatch has two different ends. *Adam looking at the pane* (focusing it, or jumping to it from the popup) marks the ready notice read (`istatus-hook.sh viewed`), so it stops counting in the status line, but it stays in `ready`, because the hub has not read the result yet. *The hub reading it back with `capture`* consumes it (`istatus-hook.sh consume`): the notice is removed and `ready` stops listing it. Dispatching to the pane again also replaces it.

So "is the dispatched session done?" is answered by an *event* (the `Stop` hook's notice, recorded as a fact), never by polling or parsing the session's screen. Reading *what it said* is still a deliberate `capture` — content is pull-on-command; only state is automatic.

Known limits:
- A prompt dispatched into a pane that is mid-turn queues. Tested live (a 20s `sleep` dispatched, then a second prompt dispatched ~10s in): `UserPromptSubmit` fires at DEQUEUE time, not queue time — the second prompt ran as a continuation of the SAME turn, after the sleep finished, and `Stop` fired once, after both had actually run. So `hub.ready` reports ready only once genuine work is done, not falsely early; the notice's text is whichever prompt was armed last (the second one overwrites the first's `hub.dispatched`, same as a re-dispatch). This was an open question with a design for a timing fix on standby if it came out the other way; it didn't, so no fix was needed.
- A turn interrupted with Esc never fires `Stop`, so the dispatch stays `task.dispatched` until it is re-armed. `hub-wait.sh` keeps waiting on it (its default is no timeout).
- A send that fails is not armed, so it raises no false ready.

### Why Stop is cheap

`Stop` fires on every turn of every session, so the hook has to cost almost nothing when nothing was dispatched. `istatus-hook.sh stop` reads the payload, checks that the session has a status file, and checks that the file holds a `hub.dispatched` item, all before taking any lock; only a session that was actually dispatched to pays for the write.

### Why orchestration is a loop, not a subagent

The long-lived "dispatch, babysit, follow up, report" task-runner is the hub session itself driving `send → hub-wait → read → decide`, not a spawned subagent. Subagents are synchronous and bounded — they'd burn context polling a pane for the duration of a long task and die on return. The persistent hub session (which already holds the task context) plus the cheap shell-level `hub-wait` is the right shape: the expensive reasoning stays in the hub; the dumb waiting stays in a shell loop.

## Relationship to other pieces

- **istatus** (`skills/istatus/`) — owns the per-session status files, the hooks that write them, the inbox reader the hub calls, and the `prefix+A A` popup and status-line segment that show the hub's dispatches alongside everything else. It replaces the old `claude-tmux-attention` plugin, which is disabled.
- **`/today`** — Adam's Notion orientation reader. A natural driver: run `/today`, let its priorities suggest what to dispatch where, then dispatch each with confirmation.
- **`~/.workstation`** — the dotfiles repo. The hub skill, `workstation.yml`, the `settings.json` hooks, and `setup.sh` wiring all live there, version-controlled.
