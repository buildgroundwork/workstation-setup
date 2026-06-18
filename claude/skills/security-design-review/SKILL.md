---
name: security-design-review
description: Run a four-lens review of a security-critical design or spec — internal-corpus audit, owning-team audit, external-industry audit, and adversarial red-team — each as a multi-agent fan-out, then synthesize into one tiered findings set the human gates. Use when Adam says "review this spec/design", "run the four reviews", "security-review this", "red-team this", "is this design sound", or before committing to a security-critical design (authz, money movement, agent/OBO delegation, PII, anything where a flaw is a breach). For shareable-doc authoring/editing workflow use doc-review-loop instead; this is the review engine.
---

# Security Design Review (four lenses)

A design that gates something dangerous (authorization, money movement, agent
delegation, PII) deserves more than one reviewer's read. This skill runs **four
independent review lenses**, each a **multi-agent fan-out**, then synthesizes them
into a single tiered findings set. It was distilled from the rebac-pdp
agent-delegation review, where it caught a proven impersonation, a phantom
dependency guarantee, and an unstoppable attack class — each found by a *different*
lens that the others structurally could not have caught.

The whole point: **the lenses are orthogonal.** Internal review can't see industry
norms; industry review can't see your own prior decisions; neither thinks like an
attacker; none of them reads the owning team's shipped code. Run all four or you
have blind spots.

## When to use

A security-critical design/spec before it's committed to or implemented:
authz, money movement, agent/OBO delegation, PII handling, anything where a flaw
is a breach. NOT for ordinary code review (use `/code-review`) or for the
shareable-doc authoring loop (use `doc-review-loop` — that's authoring; this is
the review engine, and they compose: author with one, gate with this).

Scale to the stakes. For a money-movement PDP, run all four deep. For a lower-risk
internal change, the human may pick a subset — ask which lenses if unsure.

## The four lenses

Run them **in parallel** (background agents / a workflow). Each lens is itself a
fan-out — don't collapse a lens to one agent if the design has multiple facets.

### 1. Internal-corpus audit — "does this contradict our own prior decisions?"
Check the design against the org's *own* prior docs, ADRs, and decisions. Find
contradictions, missing requirements the corpus already established, and divergence
from a stated default. This is the lens that catches "the spec asserts X but our
parent plan says Y" and "you cite a guarantee our sync design doesn't actually
make." Sources: the writing log / decision store / ADRs / the parent design docs.
*One agent reads the corpus and cross-checks each doc against the spec; cite the
contradicting passage verbatim.*

### 2. Owning-team audit — "what does the team that owns the dependency actually do?"
If the design touches a system another team owns (here: gusto-authz / ProdSec),
check against *their actual position and shipped code* — not your assumption of it.
Find where you're ahead of, behind, or contradicting them; verify load-bearing
facts in their source, not second-hand. This caught "their clamp is ZP-resident
(the thing we're replacing)" and verified the JWT `act` shape *in code*. Sources:
Glean (docs + code_search), Slack (their channels), and reading their repo
directly. *Distinguish what's a stated position from what's inferred; flag what you
could not verify.*

### 3. External-industry audit — "what's the paved path; are we blazing a trail?"
Check against published best practice and standards, web-cited. Is the chosen
approach the documented norm or an outlier? What do the primary sources (the
canonical paper, the vendor's own docs, the RFCs, OWASP) actually say? This is
where you confirm a pattern is paved vs. bespoke, and where the floor-not-a-pin
consistency subtlety surfaced. *Run it more than once if the design has distinct
sub-decisions (we ran it on the clamp pattern, the binding, and the deferral risk
separately). Use the deep-research harness and/or gerold-industry-review with web
enabled; demand cited URLs, not recalled knowledge.*

### 4. Adversarial / red-team — "how do I break it?"
Attack the design as a hostile, patient, well-resourced adversary. Two sub-passes:
(a) **tradecraft research** — gather the current attacker arsenal for this class
(CVEs, OWASP/MITRE ATLAS catalogs, real incidents, methodology), then
(b) **offensive review** — attack the spec AND the code/system layer by layer,
*reproducing exploits against a live instance where possible*. Probe: identity/
binding confusion, parsing/injection, the consistency/time window, DoS (especially
"a fail-closed authz SPOF denies everyone"), the deferrals as attack surface, the
human/operational surface, and fail-open hunting. End with a kill-chain and the
single most dangerous finding. *Give the agent explicit license to break things and
a live target to attack. The most valuable findings come from "only an adversary
thinks to set act.sub to user:" — moves no other lens makes.*

## Agent briefs (paste-and-fill — don't hand-wave the prompt)

Each lens agent fails if under-briefed. Give every agent: the artifact path (Read
working-tree files, never `git show`), the live target if any, the demand to cite
sources / `file:line` and mark **verified | inferred | could-not-verify**, and the
instruction to return findings as a structured list (severity, claim, evidence,
which design invariant it touches), not prose. Templates:

- **Internal-corpus:** "Read <artifact>. Read these internal docs [list ids/paths].
  For each, report: what it requires that bears on <artifact>; whether <artifact> is
  consistent; any contradiction or missing requirement, quoted verbatim. Do NOT
  critique on general grounds — only against these sources. The most valuable output
  is any place the design contradicts an internal decision or omits a requirement
  these docs establish."
- **Owning-team:** "What is <team>'s actual position on <topic>, and does <artifact>
  honor or contradict it? Verify load-bearing facts in their SHIPPED CODE (Glean
  code_search / read their repo), not second-hand. Distinguish stated-position from
  inferred from could-not-verify. Tell me explicitly if they have NOT taken a
  position — that's important too (it means we're defining the contract they'll
  inherit)."
- **External-industry:** "Use web search/fetch — cite live URLs, not recalled
  knowledge. Is <approach> the documented norm or an outlier? What do the primary
  sources (canonical paper, the vendor's own docs, the RFCs, OWASP/NIST) actually
  say — quote them? Where practice is split, characterize when each is used. Flag
  anything that CONTRADICTS the design, and any standard about to make it outdated."
- **Red-team tradecraft:** "Gather OFFENSIVE tradecraft for <system class>: concrete
  attack techniques per surface, each with (a) the technique, (b) how it applies to
  <this design>, (c) a cited source (CVE/advisory, OWASP/MITRE ATLAS, real incident).
  Be a black hat — I want the attacks, not the mitigations."
- **Red-team offensive:** "You are a black-hat. BREAK this design; 'looks fine' is
  failure. Read <artifact> + <code paths>. You have a LIVE target [endpoint/creds];
  reproduce exploits against it, don't only reason. Attack every layer [the probe
  checklist below]. For each finding: severity, exact attack steps, which invariant
  it breaks, proven-vs-theoretical (with commands/output if proven). End with a
  kill-chain and the single most dangerous finding. If you genuinely can't break
  something, say what you tried and why it held."

## Red-team probe checklist (run every row; absence of a finding is itself a finding)

The offensive pass must systematically walk these, not pick a favorite. Tailor the
surfaces to the system, but for an authz/identity/agent system, cover at minimum:

- **Identity / binding confusion** — forge/substitute the actor or subject; can a
  pairing (A acts-for B) be asserted that the graph/store didn't grant? type
  confusion (the proven `act.sub = "user:victim"` impersonation); empty/colliding/
  malformed ids; the binding trusted-from-token vs verified-in-graph gap.
- **Parsing / injection** — ids or claims containing the delimiter (`: # @ * /`),
  whitespace, oversized values; does a split/format on the app side smuggle a
  different subject or a wildcard? (Attack the *app's* parsing — the store usually
  validates; the Ruby/adapter layer usually doesn't.)
- **Consistency / time (TOCTOU / new-enemy)** — act in the staleness window after a
  revoke; pin/withhold/replay a freshness token to read a pre-revoke snapshot; is a
  multi-check decision atomic on one snapshot, or can checks straddle revisions?
- **DoS** — expensive-query amplification (deep traversal, non-short-circuiting
  intersection, fan-out); one-request-to-N-internal-checks; cache-bust via forced
  strong consistency; and the inverted one: **a fail-CLOSED authz SPOF denies
  everyone** (deny payroll for all) — and the recommended-retry-as-amplifier.
- **Deferrals as attack surface** — every "deferred / out-of-scope / fast-follow" is
  a hole; can a low-risk action chain into a high-value effect? is the compensating
  control enumerable/bypassable (e.g. rails on one RPC but not the lookups)?
- **Human / operational** — social-engineer the grant; clickjack/consent-fatigue the
  approval; poison the graph via a compromised writer or its upstream event; insider
  who can write a tuple; audit-log tampering; feature-flag/config as a soft target
  (a `*` allowlist, a flag that skips the check).
- **Supply chain** — build implant / dependency backdoor in the decision function;
  poisoned pipeline writing a grant; can the deploy of the schema/policy itself be
  weaponized (a caveat rewritten to `true`)?
- **Fail-open hunting** — the design claims fail-closed; find the ONE path that
  fails open: a missing field defaulting to allow, CONDITIONAL/undecided treated as
  allow, a swallowed exception, an empty relation vacuously passing, a stale default
  read, an `ask` dropped and treated as proceed. (Check the vendor's CVE list for
  fail-open bugs and set a version floor.)
- **Prompt-injection / intent hijack** (for any agent system) — the attack the authz
  layer *cannot* stop: a hijacked-but-authorized agent acts with attacker parameters
  while every check correctly allows. Confirm it's named as a non-goal + that the
  design contributes blast-radius reduction (narrow scope), not false coverage.

## Stop criteria — when a lens (and the whole review) is done

A pitbull doesn't let go early. A lens is NOT done because one pass returned;
it's done when it stops finding new things:

- **Loop-until-dry per lens.** If a pass surfaces findings, run another round
  targeting the areas it touched; stop a lens after a round returns nothing new (or
  the budget says so — say what you stopped covering and why). One-and-done is how
  the `act.sub` impersonation and the rails-bypass would have been missed.
- **Completeness critic.** Before declaring the review done, ask: which surface did
  no lens probe? which claim is still unverified (inferred, not proven)? which
  deferral has no named compensating control? what's the source the owning-team lens
  couldn't reach? Those gaps are the next round.
- **No silent caps.** If you bounded coverage (top-N findings, didn't reach a repo,
  couldn't run the live exploit), SAY SO. Silent truncation reads as "all clear"
  when it isn't.

## Severity rubric (tier consistently)

- **Critical** — directly enables the worst outcome (unauthorized money movement,
  full impersonation, mass denial), or a proven fail-open. Blocks the design.
- **High** — a real bypass or DoS needing a chained precondition, OR a load-bearing
  invariant asserted-but-unenforced (prose, not code/schema).
- **Medium** — exploitable under a narrower condition, or a hardening gap with a
  named (but imperfect) compensating control.
- **Low / track-later** — defense-in-depth, a standard to align to before rework,
  an accepted risk that must be *explicitly* accepted (and asset-class-scoped).
- Tag every finding **proven** (reproduced) or **theoretical** (reasoned); proven
  outranks theoretical at the same severity.

## How to run it

1. **Scope.** Identify the design artifact (a spec, a PR, a schema). Confirm which
   lenses (default: all four). Identify the internal corpus location, the owning
   team + their repo, and a **live target** for the red-team if one exists (a
   running dev instance the offensive agent can attack — this is what turns
   theoretical findings into proven ones).
2. **Fan out, in parallel.** Launch the lenses as background agents / a workflow.
   Each lens that has multiple facets fans out further (e.g. industry run per
   sub-decision; red-team = research + offensive). Give each agent: the artifact to
   read (working-tree files, not `git show`), its lens's specific brief, and an
   instruction to **cite sources / file:line and mark verified-vs-inferred**.
3. **Synthesize — the discipline that makes it worth it.** As findings land, do NOT
   apply them piecemeal. Collect all four lenses, then produce ONE consolidated set:
   - **Tier by severity** and by *kind*: a genuine vulnerability vs. an artifact of
     the design being not-yet-built (don't let "unbuilt = broken" stampede you) vs.
     a framing/positioning gap vs. an operational concern that's not the design's to
     solve but that it depends on (name it as an assumption).
   - **Separate proven from theoretical.** A red-team finding reproduced against a
     live instance outranks a reasoned one.
   - **Own your own errors.** Some findings will be things *you* got wrong or
     under-specified (a consistency default backwards, a guarantee that doesn't
     exist). Say so plainly.
   - **Note where lenses agree** — two independent methods finding the same
     non-obvious trap is strong signal.
   - **Name the unfixable.** Some attacks the design *structurally cannot* prevent
     (prompt-injection goal-hijack: the PDP authorizes the principal, not intent).
     State them as explicit non-goals + what the design *does* contribute
     (blast-radius reduction), rather than implying coverage. False assurance is
     worse than a named gap.
4. **The human gates the design.** Bring the consolidated findings as a decision,
   not a fait accompli — especially where a finding implies a design change (we
   pulled per-action scoping in-slice because the red-team reframed it as the
   primary defense). Recommend, with reasoning; let Adam choose. Use AskUserQuestion
   for forks that change what gets built.
5. **Record durably.** Write the kill-chain / findings to a committed doc (e.g.
   `docs/security/<thing>-red-team.md`) and fold the resulting changes into the spec
   inline, marked `[red-team]` (or `[review]`) for traceability, plus a consolidated
   threat-model section. The committed doc is the audit trail; the inline marks let
   a reader see fix-and-why together.

## What made it work (carry these or it's theater)

- **Verify, don't recall.** Every load-bearing claim checked against running
  code / a live SpiceDB / a cited URL. Several "obvious" conclusions were wrong
  until proven. An agent reasoning in the abstract produces plausible-but-wrong
  schema; an agent with a live target produces proof.
- **Orthogonality is the value.** If two lenses would find the same things, you
  have three lenses, not four. The internal/owning-team/industry/adversarial split
  is chosen because each sees what the others can't.
- **Adversarial license.** The red-team agent must be told to *break* it, with a
  live target; "looks fine" is failure. Its best findings are moves no constructive
  reviewer makes.
- **Tier honestly and gate with the human.** The reviews surface a lot; the synthesis
  separates must-fix from framing from unfixable, and the human decides what changes.
- **Empirical verification is its own discipline, woven through every lens.** When a
  claim can be tested against the running system, test it — write the schema, run the
  check, reproduce the exploit. The most expensive errors this skill exists to catch
  were "reasoned-and-wrong": a clamp that doesn't type-check, a consistency default
  backwards, an arrow that resolves to a different subject than assumed. If there's a
  live target, no security claim ships unproven.

## Anti-patterns that neuter the review (a pitbull avoids these)

- **One agent per lens when the design has facets.** Collapsing a lens to a single
  pass is how you miss the third sub-decision. Fan out.
- **Recalled instead of cited/verified.** "I believe SpiceDB does X" is not a
  finding. A finding has a URL, a `file:line`, or a reproduced command. Reject your
  own un-sourced confidence.
- **Stopping at the first clean pass.** Loop-until-dry. The best findings come on
  round two, after the first round mapped the surface.
- **"Looks fine" from the red-team.** If the offensive agent didn't try to break it
  with a live target and explicit license, you ran a friendly reviewer, not a
  red-team. Make it adversarial or it's theater.
- **Applying findings piecemeal as they land.** Wait for all lenses, then synthesize
  once — piecemeal edits contradict each other when a later lens reframes an earlier
  finding (we pulled action-scoping in-slice *because* the red-team reframed the
  industry lens's deferral-is-fine conclusion).
- **"Unbuilt = broken" stampede.** A design-stage spec describing code that doesn't
  exist yet is expected, not a vulnerability — but the *design gaps* it reveals are
  real. Separate the two; don't let an alarmed red-team report panic a rewrite of a
  sound design, and don't let "it's just a design" wave away a real flaw.
- **Implying coverage of the unfixable.** If the design can't stop an attack class,
  say so as an explicit non-goal. False assurance is the worst output a security
  review can produce.
- **Over-trusting the synthesizer.** You (the orchestrator) will be wrong sometimes
  too — about what's stale, what's settled, what a finding means. Verify the
  synthesis against the records before acting; surface the genuine forks to the human
  rather than resolving them by fiat.

## Composes with

- `doc-review-loop` — author/iterate the shareable doc; gate it with this skill.
- `/code-review`, `gerold:gerold-architecture-reviewer`, `gerold:gerold-industry-review`,
  `gerold:gerold-adr-review`, the `deep-research` harness — the building blocks the
  lenses fan out into.
