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

**Ceiling: three unmerged PRs with dependencies between them.** Past that, if the
anchor can't find genuinely non-conflicting work to hand the pair, THE PAIR IS
BLOCKED. Say so plainly — to the anchor, and let the anchor decide what's next —
rather than inventing more stacked work to stay busy or quietly sitting idle without
reporting it. Being blocked and saying so is the correct outcome at the ceiling; it
is not a failure to route around.

**Rebasing is expected, not exceptional.** Don't avoid a rebase because it's
friction. A pair pushes its own rebases as part of normal PR maintenance (see
`/pivotal`'s Worktree isolation for the mechanics of a pair managing its own branch).

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
merge, a push, or a scope change. The line that actually needs the human is
reversibility, not scale or importance — irreversible or outward-facing actions
(merges, closing PRs, changing this policy itself, and design decisions a pair
escalates because it can't resolve them) still need the human; deciding who works on
what next does not. Checking "does this conflict with anything in flight" is the
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

Five conditions, all required:

1. The Gerold-reviewed SHA equals the current head.
2. The local-Fresh-Eyes-reviewed SHA equals the current head.
3. Buildkite is passing on the current head.
4. Zero unaddressed PR comments — verified by a set difference on `in_reply_to_id`
   (root comment ids minus replied-to ids), never by a raw count. A count match can
   hide an unanswered finding when two replies land on one comment and none on
   another.
5. `main` is an ancestor of the PR's head (`git merge-base --is-ancestor origin/main
   <head>`), so merging stays a fast-forward or clean rebase and history stays
   linear. GitHub's `mergeable: true` does NOT establish this — `mergeable` only means
   "no textual conflicts"; `mergeStateStatus` (`mergeable_state`) can independently
   report `BLOCKED` (branch protection refusing) even while `mergeable` is true. Don't
   infer `mergeStateStatus` from `mergeable` — check it directly.

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
