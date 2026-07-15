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

1. **The `claude-tmux-attention` plugin** (from the Gusto marketplace) must be installed. It provides `attention-state.sh`, the shared state file (`~/.claude-tmux-attention/pending.json`), and the `arm`/`ready` producer API the hub builds on.
   ```
   /plugin marketplace update gusto-claude-code
   /plugin install claude-tmux-attention@gusto-claude-code
   /reload-plugins   # or restart
   ```
2. **The workstation tmuxinator session.** `~/.workstation/tmuxinator/workstation.yml` defines it (`name: Workstation`, root `~/.workstation`, `vim` in window 0, `INTER_SESSION_NAME=workstation claude --continue` in the claude window). The `mux` boot script starts it first (`tmuxinator start workstation`). Formerly "Hub" rooted at `~/workspace` — repurposed from a dispatch controller into the whole-workstation config session as peer messaging replaced top-down dispatch; the bus identity is `workstation`.
3. **The finish-detection Stop hook.** Wired in global `~/.claude/settings.json` as a `Stop` hook pointing at `scripts/hub-stop-hook.sh`. Takes effect on the next Claude restart (settings load at startup).
4. **This skill** lives at `~/.claude/skills/hub/` (symlinked from `~/.workstation/claude/skills/hub/`, so it's version-controlled and reproduced by `setup.sh`).

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

The hub is a thin coordination layer over tmux and the `claude-tmux-attention` state file. Everything crosses through that state file; nothing screen-scrapes a session's TUI to decide what's happening.

### The scripts

All under `scripts/`:

- **`hub-map.sh`** — reads the tmuxinator configs + live tmux and emits JSON: each project's display name, root, whether it's running, and its claude window target. Pure read. The name↔config↔dir mapping is resolved here, never guessed (display name ≠ config basename ≠ repo dir).
- **`hub-dispatch.sh`** — the mutation/navigation surface: `target` (resolve + auto-start), `send` (type a prompt + arm the pane), `go` (navigate), `capture` (read-back), `ready` (list finished vs. in-flight dispatches).
- **`hub-status.sh`** / **`hub-status-pane.sh`** — the live dashboard: a compact, auto-sizing pane showing each running session's state and context usage.
- **`hub-wait.sh`** — blocks until a dispatched pane finishes, then prints its settled contents. The babysitting primitive — it polls the state file in a cheap shell loop so the hub's Claude context isn't spent waiting.
- **`hub-stop-hook.sh`** — the personal `Stop` hook (wired in `settings.json`, not called directly).

### The dispatch → finish loop

This is the core mechanism:

1. **Dispatch.** `hub-dispatch.sh send` types the prompt into the target pane, then calls `attention-state.sh arm <pane> <prompt>`, writing a `kind: task.dispatched` row to the state file.
2. **Finish.** When that session stops (finishes its turn), Claude fires its `Stop` hooks. The personal `hub-stop-hook.sh` checks: is *this* pane armed (has a `task.dispatched` row)? If yes, it calls `attention-state.sh ready <pane>`, flipping the row to `task.ready`. If not armed — the overwhelmingly common case for non-dispatched sessions — it no-ops and exits 0.
3. **Surface.** `hub-dispatch.sh ready` reads those facts back: `task.ready` = finished, `task.dispatched` = still working. `hub-wait.sh` blocks on the same flip for orchestration.

So "is the dispatched session done?" is answered by an *event* (the Stop-hook flip recorded as a fact), never by polling or parsing the session's screen. Reading *what it said* is still a deliberate `capture` — content is pull-on-command; only state is automatic.

### Why the Stop hook is personal, not in the shipped plugin

`Stop` fires on every turn of every session. A `Stop` hook in the shipped `claude-tmux-attention` plugin would tax every marketplace user. So the hook lives in Adam's personal layer (global `settings.json`), and it cheap-checks "is this pane armed?" first — marketplace users never arm a pane, so for them it's a no-op that costs nothing. The plugin ships the `arm`/`ready` *vocabulary and producer API*; the hub supplies the personal `Stop` *wiring* that drives it. See `~/workspace/claude-code/plans/attention-core-split-and-hub.md` for the full split.

### Why orchestration is a loop, not a subagent

The long-lived "dispatch, babysit, follow up, report" task-runner is the hub session itself driving `send → hub-wait → read → decide`, not a spawned subagent. Subagents are synchronous and bounded — they'd burn context polling a pane for the duration of a long task and die on return. The persistent hub session (which already holds the task context) plus the cheap shell-level `hub-wait` is the right shape: the expensive reasoning stays in the hub; the dumb waiting stays in a shell loop.

## Relationship to other pieces

- **`claude-tmux-attention`** (marketplace plugin) — provides the state file, the `arm`/`ready`/`list` API, and the `prefix+A` attention popup that renders the hub's `task.*` facts for free.
- **`/today`** — Adam's Notion orientation reader. A natural driver: run `/today`, let its priorities suggest what to dispatch where, then dispatch each with confirmation.
- **`~/.workstation`** — the dotfiles repo. The hub skill, `workstation.yml`, the `settings.json` Stop hook, and `setup.sh` wiring all live there, version-controlled.
