---
name: spicedb-demo
description: Conduct the SpiceDB ReBAC steel-thread demo locally. Lays out the tmux instrument panes (4 servers / 2 logs) around the current control pane, brings up the stack, then walks the demo beats one at a time as the Notion runbook defines them — arming + verifying each beat before handing Adam the mic to narrate and drive the UI. The runbook owns the demo semantics (cast, what each beat shows); this skill owns the local execution (pane layout, arm/verify/watch mechanics). Use when Adam runs /spicedb-demo (or "spicedb-demo layout-only" to eyeball pane geometry without starting anything). Adam narrates each beat through the Gus web UI; when he says "next" / "move to next step", arm the next beat and report readiness.
---

# SpiceDB ReBAC demo conductor

This skill runs the demo. Adam invokes it from a Claude session **he has already started in a fresh tmux window** (that session — this one — is the *control pane*, pane 0). The skill:

1. Lays out the **instrument panes** (4 servers + 2 logs) by splitting them off the current control pane.
2. Brings up the stack (servers, log tails), port-guarded.
3. Walks the **beats** (as the runbook defines them) one at a time: arm a beat, verify it's ready (≤2s budget — see Readiness contract), point Adam at the runbook for what it shows + how to drive the UI, then wait. Adam narrates + drives the UI; when he says "next" (or similar), arm the next beat.

Adam drives the **Gus web UI in a browser** (not in tmux). The tmux window is the observability surface for the screen-share: servers logging, Kafka events landing, SpiceDB tuples appearing.

## Coordinating with the repo agents on the bus (a first-class capability — use it)

The repos in this demo each have a live Claude session on the inter-session bus (zenpayroll, rebac-pdp, rebac-relationship-writer, gusto-authz, web, …). **Many checks + actions are better answered/done by ASKING THE OWNING AGENT than by running a local command** — the owner knows the exact accessor, can run it in-process instantly (no cold `rails runner` boot), and is authoritative for its layer. The skill should treat the bus as a primary tool, not a fallback.

- **Discover peers with `ilist`** (never guess names, never poke the filesystem). Send with `isend <name> < file` (write the body with the Write tool first, then redirect — metachars in an inline body trip the permission scanner). Read full replies from `~/.claude/data/inter-session/messages.log`.
- **Route each check/action to its owner** rather than defaulting to a local command:
  - **ZP (zenpayroll):** app-config + flags (shadow mode, full-consistency, the pilot flags), the ZP source-data shape, firing the real UI mutations' effects, seed state. When a check needs an in-process Ruby read (e.g. `Spicedb.config.consistency`, `FeatureFlags.active_globally?`), ASK ZP for a clean greppable one-liner + the live value rather than running a noisy local `rails runner` (that boot-noise/Sorbet parsing is exactly why local runner checks are flaky — the owner gives you a crisp answer).
  - **rebac-pdp:** the delegation baseline (`composition-probe --verify-baseline`), the flip/reset/stage-book primitives, composed agent decisions, SpiceDB lifecycle (it owns the container).
  - **rebac-relationship-writer:** tuple-level firm_client state, the backfill, the event→tuple mappings, DLQ/consumer health.
  - **gusto-authz:** the Router shadow/live + coverage + consistency mechanism (from the gem side).
- **Local commands are still right for** port checks (`lsof`), health probes (`curl`), and `zed` reads the control pane can run directly — use those inline (prompt-free, one bare command per concern). But for anything an owning agent knows better or can run faster/cleaner, ASK. A preflight/verify that *only* runs local commands and never consults the owners is under-using the bus.
- **Peers go idle after replying** — re-prompt if waiting; don't assume progress. Read the latest from the log.
- This applies across ALL phases (preflight, setup, the beats), not just preflight — e.g. during a beat, confirm a live decision with rebac-pdp, or a tuple landing with the writer, by asking, not only by watching a pane.

## Invocation

**Two-phase model (Adam's flow): PREFLIGHT runs BEFORE recording; SETUP runs on-camera at the start of the recording during the intro narration.** Keep them separate — preflight must NOT lay out panes or start demo servers (that's the on-camera moment).

- `/spicedb-demo preflight` (or "run preflight") — **BEFORE recording.** Verify everything is ready, touch no on-camera state. Do NOT lay out panes, do NOT start demo servers. Auto-fix DATA/FLAGS only; NEVER bring servers down (stop-and-ask Adam to down PDP+agent-core, then re-check). When fully green, **pause + `iflag` and WAIT for an explicit go-ahead** — do not auto-advance. See **Preflight** (the gated flow) below. Adam runs this ahead of time so he knows the machine is ready before hitting record.
- `/spicedb-demo` (or "start setup" once preflight is green) — **AT recording start, during the intro.** Requires Adam's EXPLICIT go-ahead (this is the moment the recording begins; never auto-enter it from a green preflight). Lay out the panes + bring up the demo-owned servers (PDP, agent-core — the SETUP phase). Then begin the beat walk-through. (Assumes preflight already passed; if it wasn't run, run preflight's checks first and STOP on any red rather than laying out a stack that'll fail.)
- `/spicedb-demo layout-only` — build the pane layout but **start nothing**: each instrument pane prints the command it *would* run, then drops to a shell. Touches no live state. For eyeballing geometry safely; re-runnable freely.
- `/spicedb-demo reset` — restore the beat-0 baseline between audiences (see **Reset**).

If Adam types a bare beat instruction mid-run ("next", "move to next step", "beat 5", "redo this beat", "reset"), interpret it against the beat loop below.

## Preflight (run BEFORE recording — the "is everything ready?" gate; touches no on-camera state)

Runs on `/spicedb-demo preflight` (or "run preflight"). **The runbook's PREFLIGHT section is the source of truth for WHAT to check** (the deps-UP list, the demo-procs-DOWN list, the flags, and the beat-0 start-shape checks + their exact commands/expected values, incl. the check-first-seed-only-if-failed rule). **READ it and execute those checks — do NOT keep a copy here** (a duplicated checklist drifts from the runbook; the runbook owns the demo content, this skill owns only the execution).

This skill's job for preflight is the EXECUTION discipline, not the check list:
- **Read the runbook PREFLIGHT section first** (Notion: "SpiceDB ReBAC Demo — Setup & Run Runbook"), then run its checks in order.
- **Route each of the runbook's checks to its owner where an agent knows it best** (see "Coordinating with the repo agents on the bus" above): port/health checks run LOCAL (bare `lsof`/`curl`); owner-known in-process reads (e.g. the authz-config/flags) by ASKING the owner (ZP) for a clean greppable line + live value rather than a noisy local `rails runner`. `ilist` to find peers, `isend <name> < file` to ask. WHICH checks exist + their commands/expected values = the runbook; this is just how to execute them.
- Run any LOCAL checks **prompt-free**: bare command per concern, one at a time (no compound pipelines — they trip the permission matcher).
- **Do NOT lay out panes or start demo servers** — preflight touches no on-camera state (that's SETUP).

### The gated preflight flow (Adam's contract — hold it exactly)

Preflight is a **report + human-gated** phase. It self-heals DATA/FLAGS silently but NEVER touches servers and NEVER auto-advances into SETUP. This section is **execution discipline only** — WHICH instances must be up vs down, WHICH checks to run, their commands + expected values all live in the runbook's PREFLIGHT section; read them there and do NOT restate them here (that duplication is exactly what drifts). The discipline:

1. **Run the runbook's checks + report** each GREEN/RED. Don't stop at the first RED — run the whole set so Adam sees the full picture in one report. Route each check to its owner (bus) or run it locally per the coordination rules above.
   - **Local execution detail for the runbook's "warm ZP Rails console" check (the Beat-2 flip target):** on this machine that console lives in tmux window **`ZP:3`** (ZP windows: `ZP:1`=puma, `ZP:3`=console, `ZP:4`=zp-shell). Verify it's a live console, not a bare shell: `tmux list-panes -t ZP:3 -F '#{pane_current_command}'` → expect a ruby-ish command (`ruby`/`irb`, or a `bin/rails` still resolving), NOT `zsh`/`bash`. If it's a bare shell or `ZP:3` is absent, the console isn't up → the Beat-2 flip falls back to the ~12s runner (dead on-camera pause), so treat this as a real gate. (The `ZP:3` binding is a THIS-MACHINE fact — it lives here in the skill, NOT the runbook, which only says "a warm console must exist, placement is the runner's choice.")
2. **Ordering constraint (a HOW-fact the runbook's check list implies but doesn't sequence): some checks require a demo-owned proc to be UP, yet SETUP needs those procs DOWN.** So preflight is **CHECK-THEN-DOWN** — run every up-requiring check FIRST (while the proc is up), and only THEN move to the down-requirement. Never drive a proc down before the checks that need it have run. (Which checks need which proc: the runbook says. Don't hardcode the mapping here.)
3. **Auto-fix DATA + FLAGS only** (the answer to "set the data from any state"): a failed data/flag check → run the runbook's matching SET/reset for that layer, re-verify, report exactly what was done. Safe, off-camera, reversible. Still FLAG — don't silently do — anything the runbook says to flag (heavy ops like a recreate + re-backfill); ask first.
4. **NEVER bring servers down yourself.** For any demo-owned proc the runbook says must be DOWN before SETUP: if it's UP, **STOP and ask Adam to bring it down himself** (report the PIDs/ports); do not offer to kill it.
5. **Re-check after Adam confirms.** When Adam says a proc is down (or "check again"), re-verify with `lsof` — don't advance on his word alone. Loop 4↔5 until the runbook's down-set is confirmed down.
6. **When everything matches the runbook's start shape** (its checks green, its up-set up, its down-set down): **PRE-READ Beat 1's runbook section into context NOW** (during this quiet pre-recording pause), so that when Adam starts recording there's no on-camera wait to fetch the runbook. Then **pause, report the full green summary + "Beat 1 loaded, ready", and raise an `iflag`** ("preflight green — ready for your go-ahead to start SETUP / recording"). Then STOP and wait. Do NOT lay out panes, start servers, or proceed on your own.
7. **Require an EXPLICIT go-ahead to enter SETUP.** Only when Adam explicitly says to start setup (e.g. "start setup", "go", "begin") do you move into the SETUP phase. **SETUP is the moment the demo recording begins** — treat entering it as consequential; never auto-enter it from a green preflight.

**READ-AHEAD (standing conductor behavior — no on-camera runbook fetches).** Never read a beat's runbook section on-camera when Adam says "next" — that's a visible pause. Instead, always have the NEXT beat already loaded: at preflight-green, pre-read Beat 1 (above); then as each beat is armed/handed to Adam, immediately pre-read the FOLLOWING beat's runbook section during the gap while Adam narrates the current one. So the pattern is always "Beat N is up + Beat N+1 already read, ready to go the instant you say next." If Adam jumps out of order ("go to beat 5"), read that one on demand, then resume reading-ahead from there. The read-ahead is silent prep — don't narrate it.

If the runbook's PREFLIGHT specifics and this skill ever disagree, the runbook wins — update this skill's execution notes, never fork the check list.

## The layout (absorbed from the proven `rebac-pdp/bin/demo-window`)

One window, three horizontal bands. **The control pane (this session) is pane 0 and already exists** — split the instruments off it; do NOT create a control pane.

```
+-------------------------+-----------+-----------+
| shadow log (~half)      | Writer    | agent-core|   band 1: servers
+-------------------------+-----------+-----------+
| Kafka events            | SpiceDB relationships |   band 2: logs (causal pair)
+-------------------------+-----------------------+
| Claude control pane (this session, full width, short) |  band 3
+-------------------------------------------------------+
```
**No PDP pane** (dropped 2026-07-06): the PDP logs NOTHING per decision (all `.error`/`.warn` + a boot line — verified in source), so a PDP pane shows nothing all demo. **The shadow-log pane takes ~HALF of band-1 width** (it's the star of Beats 1–2, wide enough to read the comparison/SERVED lines); Writer + agent-core split the OTHER half (~a quarter each). They're beat-specific (Writer lights up Beat 3 the write path, agent-core Beats 4–6) but need enough width to be READABLE when they do — quarter-width each, not crushed. SpiceDB itself runs headless in its container — the leftmost pane tails the shadow log (it is NOT a SpiceDB server pane; see below).

Browser (outside tmux) = the Gus UI driver, and optionally kafka-ui at http://localhost:8081.

### Executor-local dir vars (this skill's own convenience bindings)
- `WS=$HOME/workspace`; `PDP_DIR=$WS/rebac-pdp`, `WRITER_DIR=$WS/rebac-relationship-writer`, `AGENT_DIR=$WS/agent-core`.
- Everything else — ports, tokens, launch commands, Kafka topics, which proc is up vs down — is the **runbook's** (its PREFLIGHT + SETUP sections). Read it there; this skill just maps the runbook's processes onto tmux panes.

### Prerequisites: the runbook owns them

The runbook's **PREFLIGHT** section is the sole source of truth for which long-running deps must be UP, which demo-owned procs must be DOWN, how to bring each prereq up, and the per-service gotchas. This skill does NOT restate any of that (a second copy just drifts — the sufficiency rubric is that anyone could run this demo from the runbook alone, on any machine). The gated-preflight flow above already reads the runbook and follows its lists. `layout-only` needs no prereqs (it starts nothing).

### Building the layout (tmux, from this control pane)

**Fixed assumptions (Adam-confirmed — do NOT re-measure or branch on them):** window is **52 rows × 191 cols**; we start in a **fresh window with exactly ONE pane** (this session = pane 0). Do NOT query dimensions, do NOT `list-panes` to confirm a single pane. Band sizing: **servers 20 / logs 12 / control 18 rows.** (Validated in the layout-only dry-run.)

**Two hard-won rules (dry-run findings — encode exactly):**
- **NEVER verify "which pane holds my session" with `display-message` or `#{pane_active}` — both FOLLOW my own process through a swap, so they always report "I'm here" and cause swap oscillation.** The ONLY reliable signal is **`#{pane_current_command}`** — `claude.exe` is my session, `zsh` is a placeholder pane.
- **ONE swap, not a loop.** Carving the control band needs exactly one `swap-pane`. If the first swap "looks wrong," it's the verification *signal* that's wrong (you used display-message), NOT the swap — do NOT swap again. Verify once, by `pane_current_command`, done.
- Do NOT use `select-layout` presets once there's >1 band (a preset reflows the whole window and wrecks band boundaries). Size bands with `-l` on the split + explicit `-x`/`-y` resizes.
- **Batch independent tmux commands into single Bash calls** (~3 calls total, not ~9 round-trips) — the splits/resizes are independent, chain them with `;` targeting explicit pane ids; read `list-panes` once to confirm, not between each.

**The first-time-correct recipe (carve control band first, with the single verified swap, then build everything in the PLACEHOLDER region so my session is never disturbed again):**

Call 1 — carve the control band + the single swap + verify:
```
tmux split-window -v -l 18 -d 'exec $SHELL'   # my session = top 33-row region; new placeholder pane = bottom 18 rows
tmux swap-pane -U                              # move my session DOWN into the 18-row control band
tmux list-panes -F '#{pane_id} #{pane_top} #{pane_current_command}'
#   EXPECT: claude.exe at top≈34 (bottom control band); zsh at top=0 (top 33-row region). Verify by claude.exe, NOT display-message.
```
Call 2 — from the top placeholder region (`zsh`, target it by its pane_id from Call 1's list-panes), build the rest, all chained, targeting placeholder pane ids so my session (now bottom) is untouched:
```
# log band: split the top region to leave servers=20 above, logs=12 below
tmux split-window -v -l 12 -t <top_zsh_pane_id> -d 'exec $SHELL'   # → server region (20r) above, log band (12r) below
# 4 EVEN servers — use SIZED -h splits so they land even FIRST TIME, NO resize pass.
#   GOTCHA: `-h -l N` sizes the NEW (right) pane to N and shrinks the targeted pane to the remainder.
#   A naive 3x `-h` (no -l) HALVES the target each time → 23/23/47/95, NOT even (dry-run finding).
#   3 panes, shadow-log ~HALF + Writer/agent-core ~quarter each: on 191 cols leave the shadow-log
#   pane ~95 (half) and carve two right-hand panes ~48 each. Split the SAME server pane 2x with
#   sized -l on the NEW (right) pane: 191 → (143 + new 48) → (95 + new 48). Result:
#   shadow-log ≈95, Writer ≈48, agent-core ≈48 (95 + 48 + 48 + 2 dividers ≈ 191). No PDP pane.
tmux split-window -h -l 48 -t <server_region_id> -d 'exec $SHELL'   # shadow-log→143, new (agent-core)=48
tmux split-window -h -l 48 -t <server_region_id> -d 'exec $SHELL'   # shadow-log→95,  new (Writer)=48  → 95/48/48
# 2 logs across the log band: one -h split (-l 95 → 95/95, even on 191)
tmux split-window -h -l 95 -t <log_band_id> -d 'exec $SHELL'
tmux list-panes -F '#{pane_id} #{pane_top} #{pane_left} #{pane_width} #{pane_height} #{pane_current_command}'   # one final confirm
# (If a band's cols don't divide evenly, sized -l splits still beat halve-then-resize: compute each new pane's -l share up front; do NOT halve then correct.)
```
Call 3 — the per-pane commands (or, for `layout-only`, the echoes): one batched set of `send-keys`, one per pane, targeting each placeholder pane id.

Resulting bands: [shadow-log (dominant) | Writer | agent-core] (servers, 20r) / [Kafka events | SpiceDB relationships] (logs, 12r) / [this session] (control, 18r). No PDP pane (it shows nothing per decision).

**PANE COMMAND LOOKUP TABLE — the exact command per pane, fire all in one batched `send-keys` pass, NO runbook lookup at setup time.** (SETUP is a hot path: reading the runbook per pane mid-recording is the slow-setup bug. This table is a SPEED MIRROR of the runbook's SETUP commands — the runbook stays the source of truth; if they ever diverge, the runbook wins and you fix THIS table. Placing the panes should take <30s: batch these, done.) `WS=$HOME/workspace`.

| Pane (position) | Exact command (via `send-keys`) |
| --- | --- |
| **shadow-log** (band1, dominant/left) | `tail -f $WS/zenpayroll/tmp/shadow_decisions.log` — pure tail, starts nothing (SpiceDB+PDP are prereqs, already up). |
| **Writer** (band1, mid) | `cd $WS/rebac-relationship-writer && bin/rebac-relationship-writer` |
| **agent-core** (band1, right) | `cd $WS/agent-core && bin/server --local --agent pro --no-gateway` (`--no-gateway` REQUIRED) |
| **Kafka events** (band2, left) | `kafka-console-consumer --bootstrap-server localhost:9092 --include 'firm-management.firm-member.added\|firm-management.client.added\|firm-management.firm-member.assigned-to-client\|firm-management.firm-member.permission-granted\|firm-management.client.ceiling-authorized' --from-beginning --property print.timestamp=true --property print.key=true` (single-quote the `--include` — the `\|` alternation has metachars) |
| **SpiceDB relationships** (band2, right) | `zed --endpoint localhost:50051 --token spicedb-local-key --insecure watch --object_types firm_management/firm_client --timestamp` — STREAMS tuple changes live, FILTERED to the firm_client edge. The object type MUST be passed as the `--object_types` FLAG, NOT positionally: `zed watch firm_management/firm_client` swallows the arg and streams `over types []` (empty filter = unfiltered), even though it "looks like it works" (verified 2026-07-07, zed v0.35.0). Correct form prints `over types [firm_management/firm_client]`. Ignore the harmless "watch is deprecated" warning (the suggested `relationships watch` nested form FAILS on this build). NOT a one-shot `relationship read` (prints once, pane dies). For the delegation beat, also `watch --object_types authz/delegation`. |

Do NOT start SpiceDB (`:50051`) or the PDP (`:50052`) at SETUP — long-running prereqs, already up (Preflight 1). ZP puma is clean-restarted LAST (`bin/spring stop` → `rm -rf tmp/cache/bootsnap` → restart), separately from these panes. (Full rationale/gotchas for each command live in the runbook SETUP section; this table is just the fast lookup.)

**Why no SpiceDB/PDP pane** (context for the table's shadow-log row): SpiceDB + PDP are long-running PREREQS (up before the demo, Preflight 1) with no watchable per-beat output (SpiceDB is headless; PDP logs nothing per decision) — that's why neither gets a pane. The dominant shadow-log pane is where their decisions become visible (Beat 1 comparison rows; Beat 2 the switch to `SERVED … via spicedb`). If that pane looks empty, the cause is upstream — no covered check driven, or a prereq down — NOT the pane; it's a pure tail.

**How to place a command in a pane — via `tmux send-keys` (cd, then the command, as separate send-keys so cwd is visible) — NEVER run the server/log launch commands through a Bash() tool call.** send-keys is pane-local and unscanned by the permission matcher; a metachar-bearing command (the Kafka `--include` regex, the `|` in topic alternation) run through Bash() would trip a permission prompt mid-setup (dry-run finding #3). One command per send-keys; no compound chains that obscure what's running.

**Conductor tone during SETUP (Adam's standing preference): be terse and confident — build, don't narrate the mechanics.** Do NOT walk through each tmux split/swap/resize step-by-step in chat; just run the batched calls and report the END STATE ("panes up: shadow-log/writer/agent-core + kafka/relationships + control — stack starting" or "[layout-only] geometry built, nothing started"). This extends the "don't narrate tmux mechanics to the audience" rule to the setup phase itself — the setup is plumbing, report its result, not its play-by-play. (The per-BEAT arm/ready reporting is different — that IS the conductor's job and should be clear; terseness applies to the mechanical setup, not the beat walk-through.)

**Start guard (per demo-owned proc, prompt-to-kill default-no):** before starting each proc, check it isn't ALREADY running — and pick the check by how the runbook says to detect it, because not every proc has a port:
- **Port-bound procs** (PDP, agent-core, SpiceDB): `lsof` the port the runbook lists.
- **No-port procs — the writer especially:** the rebac-relationship-writer is a Karafka consumer with NO listening port, so `lsof` CANNOT see it. Guard it by PROCESS: `pgrep -fl 'bin/rebac-relationship-writer'`. **This is a known trap** — a stale writer is invisible to a port scan, and starting SETUP anyway spawns a DUPLICATE consumer (two in one Kafka group → rebalancing + doubled processing). Never start the writer pane without the pgrep check first. (Match `bin/rebac-relationship-writer` specifically, not bare `karafka` — that also catches ZP's own consumer.)

If already running, warn + ask Adam before killing; never silently double-start. (Run the guard check however is prompt-free; the start goes via send-keys.) The runbook's PREFLIGHT/SETUP is authoritative on which procs exist and how each is detected.

**`layout-only`:** build the SAME band geometry (top-down, sized — exactly as above), but in each instrument pane just `echo` the command it *would* run and drop to a shell — start nothing, touch nothing, no port guards needed. Re-runnable; this is the geometry-validation path (already dry-run-approved).

## Readiness contract (the reliability core — hold this exactly)

The loop is: Adam narrates beat N → says "next" → run beat N+1's ACTION immediately → Adam narrates beat N+1. Per the JUST-DO default (see "Walking the beats"), a beat is an action, not a verify-gate — don't run checks during the live run. **The one prep that DOES happen in the quiet gap is READ-AHEAD: while Adam narrates beat N, silently pre-read beat N+1's runbook section so its action is loaded and instant when he says "next"** (never fetch the runbook on-camera). Read-ahead is silent; the beat's action runs the moment Adam cues it, with nothing to look up.

- **Every beat: cheap sanity check** at arm time (process up / tuple present / config in expected state). Baseline.
- **A beat MAY run a fuller positive-verify ONLY if it completes in ≤ 2 seconds.** (Beat 4's composed re-decide probe — the delegation flip's `--verify-flip` — is one gRPC call, qualifies. Use it.) If a verify would exceed 2s, do NOT run it as a gate.
- **NEVER block Adam's narration on a check.** If setup or a verify would exceed the budget, report status ("armed; <slow thing> still settling — proceed when ready") and hand him the mic. The 2s ceiling governs the *verify*; slow *setup* (a restart, a backfill) is reported, not gated.
- When a beat is armed + checked, tell Adam: **(1)** beat N is ready, **(2)** the runbook pointer for what it shows + how to drive the UI (don't restate the semantics — that's the runbook's), **(3)** what to watch in which instrument pane. Then wait.

## Walking the beats (local execution only — semantics live in the runbook)

**The runbook is the source of truth for WHAT each beat is** (cast, what it shows, the Prompt). This section carries ONLY what THIS local Claude needs to arm/verify/watch each beat in the tmux layout. Per beat: the runbook pointer, the **watch-pane** (where the signal shows in this layout), the **arm/verify** step, and the **primitive** to invoke. Do NOT restate the demo's meaning here — read it from the runbook (Notion: "SpiceDB ReBAC Demo — Setup & Run Runbook", child of the ReBAC page). If a beat's semantics and this section ever disagree, the runbook wins; fix this section.

The runbook defines the beats; walk them in its order. `[stub]` = a per-beat instrument still being built by a repo session — until it lands, the arm step says what it WILL call and Adam drives manually. Beat numbers below track the runbook's; if the runbook renumbers, follow it.

**SPEED DURING THE LIVE RUN — this is a RECORDING; JUST DO, DON'T VERIFY (Adam's hard default).** Preflight verified the machine off-camera. On-camera the conductor runs scripts and sets values WITHOUT CEREMONY. The rules, no hedging:
- **JUST DO IT.** Each beat = run its script / set its value / flip its flag, immediately on Adam's cue. No pre-check, no post-check, no confirming it landed.
- **Do NOT message other agents to confirm a change landed.** No `isend` mid-run, no "did X take?" round-trips. (The bus is a PREFLIGHT tool only.)
- **Do NOT verify — not even the fast local ≤2s checks.** If a change silently doesn't land, Adam will either re-record from the top, or ask to add a time-lag to that ONE specific step. That's the recovery, NOT defensive verification on every beat. Default to speed; let Adam call for a check on the rare step that needs it.
- **Watch, don't check.** The audience already sees the relevant pane; point at it, don't run a command to prove it. If a beat looks wrong live, keep moving — Adam decides re-record vs. carry on; you don't stop to diagnose on-camera.
- **No narration of mechanics.** Run the action, don't describe the plumbing.

For each beat, this section gives ONLY: the **watch-pane** (which instrument pane in THIS tmux layout shows the beat's signal — a display fact the runbook doesn't own), the **action** (the single thing to run/set — no verify), and any **tmux-specific gotcha** (e.g. "this pane is silent here, don't point at it"). Everything else — what the beat shows, the UI click-path, the cast, expected ALLOW/DENY values, the flip mechanism, the deny-rule framing — is the runbook's Beat N; read it there. (Any "arm/verify" wording that remains below is preflight-era vestigial — during the LIVE run it's a NO-OP; just do the action per the JUST-DO default.)

### Beat 1 — shadow parity  · runbook: Beat 1
- **Watch-pane:** the `tail -f` shadow-decisions-log pane.
- **Action:** none to run — shadow is already ON from preflight. Adam drives the covered check (per runbook); comparison rows appear. Don't check the log header, don't verify — just point at the pane.

### Beat 2 — flip to live SpiceDB  · runbook: Beat 2
- **FAST BEAT — do NOT arm/verify, do NOT MESSAGE THE ZP AGENT, do NOT re-drive shadow.** Beat 1 already established shadow. Beat 2 is ONE action the CONDUCTOR runs itself: deactivate the GLOBAL `authz.rebac.shadow_mode` FeatureFlag. Flip on Adam's cue. (Asking the ZP agent to flip is the SLOW/AMBIGUOUS path that broke this beat 2026-07-07 — "demo asked ZP to flip, ZP thought it was supposed to hold." The conductor flips directly; no bus, no round-trip.)
- **THE FLIP — `tmux send-keys` this bare line into the PRE-WARMED ZP:3 console** (ZP-confirmed fast path):
  ```ruby
  FeatureFlags.deactivate("authz.rebac.shadow_mode")
  ```
  ~17ms when the console is warm → puma serves the SpiceDB candidate within the Router's ~2s TTL → dominant pane switches comparison → `SERVED … via spicedb`. **Revert** (between takes): send-keys `FeatureFlags.activate("authz.rebac.shadow_mode")` (~17ms).
  - **Why send-keys to a warm console, not a runner:** a cold `DISABLE_SPRING=1 bin/rails runner` is ~12s (dead on-camera pause); the FIRST flag write in ANY process is ~3s (lazy machinery). A pre-warmed console makes the on-camera flip ~ms. (The runner one-liner `DISABLE_SPRING=1 bin/rails runner 'FeatureFlags.deactivate("authz.rebac.shadow_mode")'` is the FALLBACK only, if no ZP:3 console exists — accept the ~12s.)
  - **SETUP prereq (off-camera):** ZP:3 must hold a live `rails console` started with **`DISABLE_SPRING=1 bin/rails console`** (Spring is why a console won't boot under the demo's reloading-disabled config; DISABLE_SPRING boots it fine). Then PRE-WARM it: the clean-start `FeatureFlags.activate("authz.rebac.shadow_mode")` you already run IS the warm-up — it pays the ~3s first-write so Beat 2's deactivate is hot. (ZP windows: `ZP:1`=puma, `ZP:3`=console=flip target, `ZP:4`=zp-shell.)
  - `reset_cache` NOT needed (puma's FeatureFlags cache is per-request `CurrentAttributes`, re-reads every request). Send the BARE Ruby — no `{ }` blocks (they trip zsh parse errors); `FeatureFlags.deactivate(...)` has no braces, sends clean.
  - Do NOT ask the ZP agent to flip (the slow/ambiguous round-trip that broke this beat 2026-07-07 — "demo asked ZP, ZP thought hold"). The conductor send-keys it directly.
- **DO NOT use the in-process `Router.configure { |c| c.shadow_mode = false }` toggle.** It only flips the ONE process it runs in AND sets `@shadow_mode_override` which FREEZES the live-read — so it does NOT affect puma's request-serving (this was the Beat-2 "nothing happened" bug 2026-07-07: flag stayed globally TRUE, pane kept showing comparison rows). Also its `{ }` block trips `zsh: parse error near }` if send-keys'd into a shell. The DB-backed global `deactivate` above is the only correct flip.
- **Even under move-fast, this one is worth confirming it took** (the exception to "just do, don't verify"): after the flip, the dominant pane should switch comparison-rows → `SERVED … via spicedb`. If it DOESN'T switch within a few seconds, the deactivate didn't land (flag still true) — re-run the exact command above; do NOT fall back to the in-process toggle. (This is the ONE beat where a silent no-op is invisible without a glance at the pane, so glance.)
- **Watch-pane:** the dominant shadow-log pane — it switches from comparison rows to `SERVED ... via spicedb` within ~2s. That switch IS the beat; no other verification.

*(Former Beat 3 — per-client correctness human render — REMOVED 2026-07-07: redundant with the Beats 1–2 shadow-parity rows, and Beta's Client-Details page errors pre-authz for an unassigned client. Its human-UI proof folded into the write-path beat's post-grant reload. Beats renumbered contiguously below.)*

### Beat 3 — write path  · runbook: Beat 3
- **Watch-pane:** Kafka-events pane (the assign event lands) + SpiceDB-relationships pane (the new tuple appears). The skill's job is to have BOTH visible so the event → writer → tuple flow is watchable; Adam drives the real UI assignment, then reloads Beta's Overview (the folded-in human-UI proof: deny→grant on the actual page).
- **Action:** none to pre-run — Adam drives the real UI assign; the emit fires live (fixed, `f2740f8`), writer materializes the grant. Confirm the `assigned-to-client` topic log-end ADVANCES (per runbook) rather than trusting the click.

### Beat 4 — live agentic delegation flip  · runbook: Beat 4
- **Watch-pane (NOT the writer):** the delegation flip is a direct `zed` write, NOT the Kafka→writer path, so the **writer pane is silent here — do NOT point at it (it looks broken).** Watch the **SpiceDB-relationships pane** (the flip tuple appears) + the **PDP pane** (decision flips DENY→ALLOW). (Contrast Beat 3, which DOES use the writer pipeline.)
- **Action + the ONE allowed verify (≤2s, high-stakes beat):** run the runbook's Beat-4 flip + its composed `--verify-flip` (one fast FetchDecisions) and confirm ALLOW on the flip-client BEFORE handing Adam the mic. If not ALLOW, say so; don't let him narrate into a stale DENY. (Flip command, flip-client, Option-B baseline, freshness mechanism all the runbook's.)

### Beat 5 — perf beat, SLOW half: incumbent fan-out (shadow ON)  · runbook: Beat 5
- **Watch-pane:** agent-core pane (the incumbent's fan-out) vs the PDP pane.
- **Arm — shadow ON:** Beats 5+6 are the SAME query run once per backend; Beat 5 is the slow half. If Beat 2 flipped shadow OFF, RE-ACTIVATE — the inverse of Beat 2, send-keys the BARE Ruby: `FeatureFlags.activate("authz.rebac.shadow_mode")` (~17ms). Same mechanism/caveats as Beat 2 (no `{ }` blocks, no in-process `Router.configure`, don't ask the ZP agent — conductor send-keys directly). **Confirm:** dominant pane switches BACK from `SERVED … via spicedb` to comparison rows within a few seconds; if not, re-send. (Idempotent if Beat 2 wasn't run this take.) With shadow ON both backends run → Adam's query fans out ~18–20s: the number to beat.
- **Action:** per runbook. **[stub: SSN resolver — the runbook wires the field + both authz paths when zenpayroll reports; follow it.]**

### Beat 6 — perf beat, FAST half: SpiceDB one traversal (flip shadow OFF)  · runbook: Beat 6
- **Watch-pane:** same as Beat 5 — agent-core vs PDP pane.
- **Arm — the flip IS the beat:** on Adam's cue, send-keys `FeatureFlags.deactivate("authz.rebac.shadow_mode")` (~17ms, same warm console). **Confirm** (the move-fast exception, same as Beat 2): pane switches comparison rows → `SERVED … via spicedb`; if it doesn't switch in a few seconds, re-send (do NOT fall back to the in-process toggle). SpiceDB now served → the SAME query resolves in one traversal, fast. The Beat-5-slow / Beat-6-fast delta on the identical request is the payoff. Stack ends live-on-SpiceDB (flows into Beat 7).

### Beat 7 — open Q&A  · runbook: Beat 7
- **Watch-pane:** PDP pane (decisions resolving).
- **Action:** none — full stack up, cast at baseline, shadow OFF (live on SpiceDB). The deny-rule framing + how to pre-delegate a client for open-floor are the runbook's.

## Reset (re-runnability between audiences)

`/spicedb-demo reset` restores the beat-0 baseline so the demo can re-run without re-laying-out or regenerating the cast. The reset primitive + what the baseline IS are the runbook's (and rebac-pdp's `bin/demo-reset`); the skill just invokes it and re-arms:
- Invoke the runbook's reset primitive (`cd $PDP_DIR && bin/demo-reset`). Its own composed verify fails non-zero on a mismatch, so a clean exit IS the baseline confirmation — trust that, don't re-implement a check.
- Re-arm beat 1 if beat 2's flip was done.
- It does NOT re-seed the cast (see the runbook for the fresh-cast path); the cheap between-run loop is just `bin/demo-reset`.
- Does NOT re-seed the cast (the cast persists between runs on the stable firm / the id-map). If the cast was wiped, that's a full re-seed (ZP `accountants:demo:seed_cast` no-arg = fresh firm); the cheap between-rehearsal loop is just `bin/demo-reset` against the stable cast (and `seed_cast[<firm_id>]` re-emits an existing firm's map without a new firm — see note).
- **Fresh-cast-seed wrinkle (re-runnability, not the steady-state path):** the no-arg `seed_cast` (full fresh cast / new firm) is INTERMITTENT — it can fail with `AccountantNotPartOfCompany` (a race: the per-client accountant assign vs PA creation / a stale Company cache in a reused process). **Retry works** (it's a transient race, not a real failure). So if a fresh reseed is ever needed mid-prep and errors with that, just retry. The steady-state `bin/demo-reset` loop does NOT reseed, so it doesn't hit this — only the rare deliberate fresh-cast does. (Race not chased / not fixed — flagged as a known retry-on-this-error, not a blocker.)

## Instruments owned elsewhere (this skill is the conductor, not the instruments)

The skill SHELLS OUT to the primitives the repo sessions own (the runbook names them per beat — the flip/reset/stage-book scripts, the composition probe, the seed/backfill rakes, the flag toggle); it does not reimplement them and does not keep a status ledger of what's landed where (that's the runbook + the Notion umbrella — a duplicated ledger drifts and goes stale). If a primitive the runbook names is missing/fails at arm time, fail loud and let Adam drive manually rather than guessing a command.

## Notes
- Personal skill, lives in `~/.claude/skills/` (never a repo `.claude/skills/`, which the marketplace plugin clobbers).
- The durable demo record (beats, decisions, the cast, the per-beat instruments) is the Notion umbrella + the synthesis/conductor pages; this skill is the executable form. Keep them consistent.
- Don't narrate the tmux/observability mechanics to the audience; the panes are the screen-share backdrop. Narrate the authorization story.
