---
name: pr-ownership
description: How a pair (or any session pair-programming with another) scopes, owns, and sequences pull requests when review latency is the binding constraint — end-to-end ownership of a PR, stacking a second PR on an in-flight first one, and when to stop and report being blocked rather than invent more work. Applies to /pivotal's Navigator/Driver pairs but is independent of pairing mechanics. Use when a pair is deciding whether to open a new PR, whether to stack on an existing one, who owns responding to review feedback, or whether it's actually blocked. Triggers: "should we open a new PR", "can we stack this", "who owns responding to this review", "are we blocked on PRs".
---

## Why this is a separate skill from `/pivotal`

`/pivotal` encodes how sessions collaborate: roles, adversarial review, the TDD
spine, agreement gates, bus messaging, tmux bootstrap. This skill encodes something
orthogonal: how work gets packaged into PRs and sequenced against review latency. It
would apply the same way to a two-session pair or a different role arrangement, so it
stays separate rather than folded into `/pivotal`. Cross-reference `/pivotal` for the
collaboration mechanics; this skill doesn't restate them.

## The problem this solves

Implementation is fast; human review is not. On a real day running this model, a
project had five PRs sitting at zero unanswered automated findings and zero human
reviews, three of them waiting on a reviewer for over a day. If a pair sits idle
until a PR merges, most of its time is spent waiting. The model below exists so a
pair stays productive while a PR is in review, and so that by the time a human looks
at a PR, every automated finding (Gerold, Fresh Eyes, linters) is already resolved —
the goal being that human review becomes close to pro forma. Read the rules below
with this constraint in mind; it's what makes the edge cases resolve sensibly instead
of by rote.

## The policy

**Ownership is end to end, and it's exclusive.** A pair owns a PR from creation to
merge: opening it, running the Gerold PR review, and addressing ALL feedback —
Gerold's, Fresh Eyes', and human reviewers'. No handoff mid-PR. One pair per PR,
always.

**Every PR targets `main`.** Never another pair's branch. PRs should be minimal.

**The same-pair exception.** Because review latency is long, a pair with an open PR
MAY build its next unit of work on that PR's own commits, to stay productive instead
of idling. The new PR still targets `main`, so it carries both its own new commits
and the original PR's commits — that's expected, not a mistake. Consequence: a pair
may have several PRs in flight at once and should interleave them: while PR 1 sits
in CI or review, start PR 2; when PR 1 gets review comments, switch to PR 1's branch,
resolve them, push, then return to PR 2. If PR 2 depends on PR 1 and PR 1 changes
underneath it, the pair propagates that change into PR 2 itself — this is on the
owning pair, not automatic, and not the anchor's job.

**This exception is same-pair only.** If pair A needs work that's sitting unmerged in
pair B's PR, that is a CROSS-PAIR DEPENDENCY, not a stacking opportunity. Cross-pair
dependency is treated as a conflict: the anchor reallocates the work rather than
having pair A build on pair B's unmerged branch. The same-pair exception does not
extend across pairs under any circumstance — it exists because one pair can manage
its own two branches without losing track of which commits are whose; two different
pairs coordinating a shared unmerged dependency is a different, riskier problem, and
the anchor solving it by reallocating avoids it entirely rather than managing it.

**Ceiling: three unmerged PRs with dependencies between them.** The ceiling is about
ENTANGLEMENT, not the raw count of open PRs — a PR touching files no other open PR
touches adds a review to the queue, not a resolution burden, and doesn't count
against this ceiling on its own. It's specifically about PRs that depend on each
other (the same-pair exception above, or anything else creating a chain a pair has to
track). Past three dependent, unmerged PRs, if the anchor can't find genuinely
non-conflicting work to hand the pair, THE PAIR IS BLOCKED. Say so plainly — to the
anchor, and let the anchor decide what's next — rather than inventing more stacked
work to stay busy or quietly sitting idle without reporting it. Being blocked and
saying so is the correct outcome at the ceiling; it is not a failure to route around.

**Rebasing is expected, not exceptional.** Don't avoid a rebase because it's
friction. A pair pushes its own rebases as part of normal PR maintenance (see
`/pivotal`'s Worktree isolation for the mechanics of a pair managing its own branch).
**Push is pair-owned, not human-gated, under this policy** — end-to-end ownership
(above) includes the push that keeps a PR current; the human's role is merging it,
not authorizing each push along the way.

**Not retroactive.** A pre-existing stack of PRs built before this policy was in
effect gets resolved under whatever model it was actually built under. This policy
governs new work going forward, not a retroactive reinterpretation of PRs already in
flight when it was adopted.

**The anchor allocates without waiting for approval to allocate.** (This skill says
"anchor" throughout for whoever holds the backlog and hands out units of work —
under a different pairing arrangement, substitute that role.) If non-conflicting
work exists, assign it; don't hold a pair pending the human's blessing of the
assignment itself. This is the anchor's half of a contract the skill already states
the pair's half of: a pair reports being blocked rather than sitting idle (see the
ceiling rule above), and the corollary is that a pair going idle means the anchor
didn't have the next unit ready — that is an anchor failure, not a pair failure.

The reason allocation doesn't need the human's sign-off is that it's reversible and
cheap: reassigning work costs nothing if it turns out to be the wrong call, unlike a
merge or a scope change. The line that actually needs the human is reversibility,
not scale or importance — irreversible or outward-facing actions (merges, closing
PRs, changing this policy itself, and design decisions a pair escalates because it
can't resolve them) still need the human; deciding who works on what next does not,
and neither does pushing (see "Rebasing is expected, not exceptional" above) — a
push under this policy's branch-protection expectations is correctable by another
push, not a one-way action the way a merge to `main` is. Checking "does this
conflict with anything in flight" is the
anchor's job to do before assigning, using the same non-conflicting-work test defined
above for the cross-pair-dependency case — not something to defer to the human
because asking feels safer. Asking when allocation was never the risky part just
trades a five-minute round trip for however long a pair sits with nothing to do.

## Practical guidance for the failure modes this model introduces

**Tracking two branches without cross-contaminating them.** This is the main new way
to get this wrong. Before switching context between PR 1's branch and PR 2's branch,
confirm which branch is actually checked out (or which worktree you're in, per
`/pivotal`) — don't assume from memory. A commit made on the wrong branch under this
model is easy to make and easy to miss, because both branches are legitimately the
same pair's own work.

**What "minimal PR" means once the same-pair exception is in play.** A reviewer
looking at PR 2 will see a diff that includes PR 1's commits, which is a larger diff
than PR 2's actual new work. "Minimal" here means PR 2 adds no unrelated work on top
of what it depends on — it does not mean the diff a reviewer sees is small. State
this plainly in PR 2's description: name which PR it's built on and which commits are
the actual new contribution, so a reviewer isn't left inferring it from the commit
list.

**Detecting a cross-pair conflict before allocating work, not after.** Before handing
a pair a new unit, the anchor checks whether that unit depends on anything currently
unmerged in another pair's PR. Catching this before the work starts is much cheaper
than catching it after a pair has already built on the wrong assumption — reallocate
at assignment time, not at review time.

**Reporting blocked.** When a pair hits the three-PR ceiling with no non-conflicting
work available, the report to the anchor should say plainly: which PRs are open and
unmerged, what work would depend on them, and that no independent unit was
available — not a vague "waiting on review," and not silence.

## When is a PR ready to merge

**Six** conditions, all required. Conditions 1, 2 and 4 are the team's own standard,
stricter than the repo enforces. Condition 3 is the repo's. Condition 6 is GitHub's.
Keep the three sources distinct: the ruleset is not yours to relax — and note that
conditions 1 and 2 (a Gerold PR review AND a Fresh Eyes review, each bound to the
CURRENT head commit) are ALSO not relaxable, by explicit standing rule. A PR does not
merge without both, on the head. This is the one place the "your own standards are
yours to relax" latitude does NOT apply: a stale Gerold or Fresh Eyes review — one
bound to any SHA other than the current head — does not count, and its absence on the
head blocks merge exactly as a failing required check would. If Fresh Eyes did not run
on the head (e.g. it didn't auto-re-run after a rebase), the owning pair TRIGGERS it on
the head (via the fresh-eyes skill's trigger mode / a manual CI build) and waits for
the head-bound verdict; the PR is not ready until that verdict exists. "Old reviews are
not acceptable" is the rule, stated by the human and binding.

1. The Gerold-reviewed SHA equals the current head.
2. A **local Fresh Eyes review** (the fresh-eyes skill's `review` mode, run against
   the working tree at the PR's current head) has been run and its findings driven to
   zero. This is specifically the LOCAL review, NOT the CI Fresh Eyes check-run. The
   CI check-run is a separate thing that gates only if the ruleset requires it (see
   condition 3) and commonly returns a `requires_human_approval` routing object that
   explicitly did not assess the code — that routing object does NOT satisfy this
   condition. The point of condition 2 is that a local Fresh Eyes review actually ran
   on the head and caught what Gerold structurally doesn't. A green (or routing) CI
   check is not that review. Run it locally, on the head, and address the findings.
3. **The required status checks are passing — read the ruleset to learn which those
   are.** Don't infer it:

       gh api repos/<org>/<repo>/rules/branches/main --jq \
         '[.[] | select(.type=="required_status_checks")
               | .parameters.required_status_checks]'

   On one repo this returned exactly ONE context (`buildkite/<repo>` — the build that
   compiles and runs the suite) while twelve other check-runs existed and gated
   nothing. Both obvious substitutes for reading the ruleset are wrong, in opposite
   directions: a count floor (`total >= 11`) is under-strict and is satisfied by a set
   missing a required member; set-equality against `main` is over-strict and blocks on
   checks with no authority. One API call settles it, and hardcoded expectations go
   stale — this repo's check count changed twice in a single day when a new scanner
   was added.

   Two further traps on this surface:
   - `/status` and `/check-runs` can be **disjoint**. On the repo above, the build
     appeared only in `/status` while twelve security and review runs appeared only in
     `/check-runs`, zero overlap. Scoring one is not scoring CI.
   - Never read `/status`'s rollup `.state`. A top-level `failure` can be an unchecked
     human checkbox while the real build is still pending. Read the per-context states.
   - An absent check-run name is not evidence of anything until you know whether that
     check is required. And "nothing is pending" does NOT mean "everything has
     registered" — a check has been observed registering hours after every other
     check on that head went terminal.
4. Zero unaddressed PR comments — verified by a set difference on `in_reply_to_id`
   (root comment ids minus replied-to ids), never by a raw count. A count match can
   hide an unanswered finding when two replies land on one comment and none on
   another. **Count the population unfiltered first**: a filtered zero cannot
   distinguish "nothing matched" from "no surface exists to match against."
5. `main` is an ancestor of the PR's head (`git merge-base --is-ancestor origin/main
   <head>`), so merging stays a fast-forward or clean rebase and history stays
   linear. GitHub's `mergeable: true` does NOT establish this — `mergeable` only means
   "no textual conflicts"; `mergeStateStatus` (`mergeable_state`) can independently
   report `BLOCKED` (branch protection refusing) even while `mergeable` is true. Don't
   infer `mergeStateStatus` from `mergeable` — check it directly.
6. **One approving review on the current head.** This is a native GitHub requirement
   (`required_approving_review_count`), not a team convention, and a gate that omits
   it reports PRs as "ready to merge" that GitHub will refuse. **A bot approval
   satisfies it** — an auto-approving review bot counts, and a doc-only PR can close
   this condition with no human involved at all. Read `reviewDecision`; don't predict
   which you'll get from what other PRs received, since the tier is decided per-PR.

**Two ruleset flags that change how you sequence work.** Read them once and remember
them: `dismiss_stale_reviews_on_push` and `require_last_push_approval`. With these on,
**any push destroys an existing approval — including a pure-replay rebase that a
patch-id proves changed nothing.** GitHub does not consult patch-ids. So once a PR
holds an approval, a rebase you could have skipped costs a re-approval; if a PR is
approved and behind, ask before rebasing.

**Any change to what commit the head points to invalidates conditions 1 and 2.**
This includes rewrites (amend, rebase, squash, force-push) and simply appending a new
commit — the old head still existing in history doesn't matter, because it is no
longer THE head. Both reviews must re-run on the new head before the PR can be
called ready again.

**Don't economize re-review.** More review runs are never a cost to minimize. Do not
sequence work to avoid triggering re-invalidation (e.g. holding off rebasing PR A so
it doesn't re-invalidate PR B's reviews later) — an invalidated review may have
already found and fixed real issues, and a fresh run after any head change may find
more. When a PR's readiness goes stale because another PR merged and moved `main`,
that is the gate working correctly, not a problem to route around.

**Process-verification is not review.** Verifying a PR's machinery — SHA bindings
match, findings are threaded and answered, a verdict exists — is a claim about
process, not about the change. The five-condition gate is necessary but not
sufficient; it does not substitute for someone having actually read the diff for
pattern compliance and correctness.
