---
name: fresh-start
description: Begin a fresh day of development — update the workstation, set up the project, and start its dev servers on the current branch, auto-fixing the common breakage that gets in the way. Project-agnostic: discovers and delegates to the current project's own setup/start skills (e.g. zp-setup/zp-start) instead of hardcoding one project. Use when the user says "fresh start", "start my day", "get me going", "spin up the dev environment", or just wants their local environment up and working.
---

# Fresh Start

A daily-startup orchestrator. It runs on **the current branch, in its current state** — no git stashing or branch switching. (If the user wants a clean baseline, they can check out `main` themselves first. Stashing + checking out `main` was considered and rejected: it tangles with database migrations, which would have to be rolled back to match `main` and re-applied afterward.)

It does these things, in order:

1. **Update the workstation** (`workstation-update`).
2. **Set up** the project (delegating to the project's own setup skill, else `bin/setup`).
3. **Start** the project's dev servers (delegating to the project's own start skill, else `bin/server`).
4. Throughout, **auto-fix the common nonsense** that breaks startup, searching Slack/Glean/repo docs for unfamiliar failures.

**All of these run in a separate tmux pane, not as backgrounded Bash** — so the user watches the workstation update, setup, and server logs live, instead of having stdout swallowed in the Claude session. See "Execution model" below.

This skill is **project-agnostic**. It does not assume zenpayroll. It discovers the right per-project skill at runtime and delegates, falling back to conventional commands (`bin/setup`, `bin/server`) only when no project skill exists.

## Guiding principles

- **Run commands in the user's tmux pane, not in Bash.** Send each command to the adjacent pane with `tmux send-keys` so its output is visible to the user. Do NOT run setup/server via the Bash tool with `run_in_background` — that hides the logs. The Bash tool is only for *observing* state (status checks, curl, `tmux capture-pane`) and for tmux control itself.
- **Current branch, as-is.** Do not stash, switch branches, or touch git state. Run setup/boot against whatever is checked out.
- **Discover, don't hardcode.** The working directory determines the project; prefer that project's own setup/start skills.
- **Auto-fix known breakage; ask on the unknown / the dangerous.** Apply well-understood fixes silently. For unfamiliar failures, search for a solution and confirm. For anything destructive, stop and ask.
- **Confirm readiness out-of-band.** Because the run command's stdout goes to the pane (not back to you), determine success with separate observe-only commands (`overmind status`, an HTTP probe, or `tmux capture-pane` of the target pane). Don't claim the server is up until you've confirmed it that way.
- **Report honestly.** If a step fails or is skipped, say so.

## Execution model — the target pane

The skill is invoked from a Claude pane inside a tmux window that has (at least) one **other** pane beside it. Commands run in that other pane so the user can watch.

**Identify the target pane** (do this once, up front):

```bash
# The window Claude is running in
WIN=$(tmux display-message -p '#{session_name}:#{window_index}')
# All panes in this window: index, id, left-edge, active-flag
tmux list-panes -t "$WIN" -F '#{pane_index} #{pane_id} #{pane_left} #{pane_active}'
```

- The **active** pane (`#{pane_active}` = 1) is Claude's own pane — never target it.
- The **target** is the other pane. By Adam's convention the command pane is the **left-hand** pane (smallest `#{pane_left}`); the Claude pane is on the right. So pick the non-active pane with the smallest `pane_left`. Capture its `pane_id` (e.g. `%18`) as `TARGET`.
- If there is **no** other pane in the window, create one to its left and use that:
  ```bash
  tmux split-window -h -b -t "$WIN"   # -b puts the new pane before (left of) the current one
  ```
  then re-list and grab the new pane's id. (Don't resize unless asked — leave layout to the user.)

**Run a command in the target pane:**

```bash
tmux send-keys -t "$TARGET" 'cd <project-dir> && <command>' Enter
```

**Observe the target pane / wait for readiness** — use the Bash tool for these (they return output to you):

```bash
tmux capture-pane -t "$TARGET" -p   # see pane output (bare — matches Bash(tmux *) allowlist)
overmind status                     # ground-truth process state (zenpayroll)
curl -sf http://localhost:3000/ -o /dev/null && echo up || echo down
```

**Poll with SIMPLE, allowlist-matching commands — do NOT wrap the observe command in an `until ... do sleep ... done` loop or a `| tail | grep` pipeline.** A compound shell line (loop keywords, pipes, `sleep`, `;`-sequencing) does not match the simple `Bash(tmux *)` / `Bash(curl *)` prefix rules even when every individual binary in it is allowlisted, so the harness falls through to a permission prompt on *every* poll. That makes a long boot prompt repeatedly. Instead:

- Issue a **bare** `tmux capture-pane -t "$TARGET" -p` (or bare `overmind status`, bare `curl ...`) and do the "is the prompt back / is it up?" decision in the harness from the returned output — one observe call per check, no shell wrapper.
- To space out repeated checks, prefer the **`Monitor` tool** or a `run_in_background` Bash command, not a hand-rolled `until`/`sleep` loop in the foreground.
- Never read the `send-keys` command's stdout (there isn't any); always observe via a separate bare command.

**Note on delegated skills:** if a project setup/start skill (e.g. `zp-start`) is invoked and it runs things via the Bash tool itself, its output won't land in the target pane. Prefer to honor the user's pane convention: when delegating, drive the underlying command (e.g. `bin/server`) into the target pane yourself, or — if the project skill must own the flow — tell the user that step's logs are in the Claude session rather than the pane. Adam's strong preference is logs in the pane.

## Step 1 — Update the workstation

Send `workstation-update` to the **target pane** (`tmux send-keys -t "$TARGET" 'workstation-update' Enter`). It can take minutes; the user watches it in the pane. Poll for completion by capturing the pane (`tmux capture-pane -t "$TARGET" -p`) until the shell prompt returns. Summarize the result in one line. If it fails, note it — it's often the root cause of later failures — but continue; the project may still boot.

## Step 2 — Set up the project

Discover the project's setup skill:

- Scan the **available-skills list** for a skill whose description is about *setting up* this project's dev environment (convention `<project>-setup`, e.g. `zp-setup` for zenpayroll). Match on description, not just name.
- If found, **invoke it** — but route the actual setup command into the target pane (see the delegation note in "Execution model") so its output is visible.
- Else fall back to `bin/setup`: `tmux send-keys -t "$TARGET" 'cd <project-dir> && bin/setup' Enter`, then watch the pane until it finishes. (For zenpayroll, `bin/setup` seeds `tmp/local_secrets/` and runs migrations.)
- Else skip and note it.

If a status/diagnose skill exists (e.g. `zp-status`), you may consult it first to avoid a redundant full setup when the environment is already healthy — set up only what's missing.

## Step 3 — Start the dev servers

Discover the project's start skill:

- Scan for a skill whose description is about *starting* this project's dev servers (convention `<project>-start`, e.g. `zp-start`).
- If found, **invoke it** — but drive the start command into the target pane (see the delegation note) so the server logs are visible to the user.
- Else fall back to `bin/server` if present, else `bin/dev`, else the project's documented start command (check README/Procfile).

**Start the server in the target pane**, e.g. `tmux send-keys -t "$TARGET" 'cd <project-dir> && bin/server' Enter`. The server is a long-lived foreground process living in that pane — do NOT background it with the Bash tool; that's the whole point (the user watches the logs there).

Then **poll for readiness with the Bash tool using bare, allowlist-matching observe commands** — bare `overmind status`, a bare HTTP probe (`curl -sf http://localhost:3000/ -o /dev/null && echo up || echo down`), or bare `tmux capture-pane -t "$TARGET" -p` to read the logs. Make the up/not-up decision in the harness from the output; do NOT wrap the check in an `until`/`sleep` loop or `| grep` pipeline (it prompts for permission every poll — see "Observe the target pane" above). Space repeated checks via the `Monitor` tool or a `run_in_background` command. Never read send-keys output (there is none). Don't claim it's up until a bare observe confirms it.

Watch for `bin/server`'s **interactive prompts** in the pane (e.g. the stale `.overmind.sock` Y/n). Because the command runs in the pane, you can answer it directly: `tmux send-keys -t "$TARGET" 'Y' Enter`. But prefer to pre-empt the known ones via the auto-fix catalog (clear the stale socket before starting) so no prompt appears.

## Auto-fix catalog (apply silently, then retry the failed step once)

| Symptom | Auto-fix |
|---|---|
| `.overmind.sock exists but overmind does not seem to be started` / interactive Y/n prompt | Pre-empt it: before starting, verify overmind truly isn't running (`overmind status` fails), then `rm -f ./.overmind.sock`. If the prompt does appear in the pane, you can answer it: `tmux send-keys -t "$TARGET" 'Y' Enter`. |
| `Gusto::Config::Sops::DecryptionError: Failed to get the data key` | Run `bin/setup` to seed `tmp/local_secrets/`. If SSO is the cause, `aws sso login` then retry. Last resort in a worktree: copy `tmp/local_secrets/` from the main checkout. |
| `aws sts get-caller-identity` expired | `aws sso login` (interactive — if headless, tell the user to run `! aws sso login`). |
| `ulimit` below the start script's threshold (e.g. 8194) | `ulimit -n 8194` in the start shell. |
| Elasticsearch/Docker not up (ports 9200/5601 not listening) | Ensure Colima/Docker is running, then `docker compose up -d es01 kibana` (or what the start script expects) and wait for the ports. |
| Karafka topic/web migrations pending | `bin/karafka-web migrate && bin/karafka topics migrate`. |
| `bin/setup` not completed (`tmp/dev_setup/last_complete` missing) | Run `bin/setup` before starting servers. |

Run these fixes in the **target pane** too (`tmux send-keys`) when they produce output worth seeing (`bin/setup`, `bin/karafka ... migrate`, `docker compose up`), so the user keeps watching one stream. Quick non-interactive checks (`overmind status`, `aws sts get-caller-identity`) can run via the Bash tool.

For **unfamiliar** failures, don't guess destructively:
1. Search the repo (CLAUDE.md, README, the start script itself).
2. Search **Glean** (`mcp__gleangusto__search` / `chat`) and **Slack** (`mcp__claude_ai_Slack_Gusto_Offical__slack_search_public`) for the error text — dev-env fixes are often posted there.
3. Propose the fix with its source; apply after confirming. Apply silently only for a clear match to a known-safe pattern.

Never reset/drop the local database to "fix" startup — backfill or repair instead. (User standing preference.)

## Wrap-up

Report: what updated, what was set up, what's running (with proof), and anything you auto-fixed. Remind the user the live logs are in the adjacent pane. If you applied a fix worth making permanent, mention it.

## Notes for the maintainer

- This is a personal skill in `~/.claude/skills/` on purpose. The project-level `.claude/skills/` directory is regenerated by the `gusto-zenpayroll-local` marketplace plugin and will silently delete local skills dropped into it (this is how the original `server-startup` skill was lost). Keep `fresh-start` here.
- In zenpayroll, the skills this delegates to are `zp-setup` (Step 2) and `zp-start` (Step 3); `zp-status` can inform Step 2.
- **The tmux-pane execution model is core**, inherited from the original `server-startup` skill: commands run in the adjacent (left) pane of Claude's tmux window via `tmux send-keys`, so the user watches workstation-update/setup/server logs live instead of having stdout swallowed in the Claude session. The Bash tool is used only to *observe* (status/curl/`capture-pane`) and to control tmux.
