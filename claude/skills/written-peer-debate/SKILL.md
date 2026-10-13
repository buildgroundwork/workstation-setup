---
name: written-peer-debate
description: Guidance for drafting written peer-facing technical responses (PR comments, ADR threads, doc comments) when defending a substantive position. Addresses a common conversational failure mode — sound technical positions undercut by how a reply is shaped or how it exits a stalled disagreement. Two-phase discipline: engage with layering, exit without diagnostic, plus test questions to catch register slips before posting. Use whenever drafting a reply in a written technical debate, especially on multi-round threads or when disengaging after several rounds.
---

# Written Peer Debate

Invoke this skill whenever drafting a written technical response defending a substantive position in a peer-facing forum: PR comments, ADR review threads, doc comments, or similar written debate. Applies to every round in such a thread, not just the exit.

## The core rule

This addresses a common conversational failure mode: holding a correct, well-argued position while still losing the room, because of how the reply is shaped rather than what it argues. Holding the position and refusing to concede on the merits is not the problem. What needs adjustment is how the reply is shaped: what it leads with, how it layers depth, and — most importantly — how it exits when engagement stalls.

This isn't a novel claim. It's a consolidation of well-established, independently-derived findings from negotiation research, social psychology, classic communication writing, and engineering-culture norms — see [References](#references). Four converge on the same shape:

- Carnegie observed decades ago that you cannot win an argument in the sense that matters: win it, and you've made the other party feel inferior and resentful; the only way to come out ahead is to avoid the argument itself and address the disagreement directly instead [[1]](#references).
- The Harvard Negotiation Project's *Difficult Conversations* model shows every hard conversation running on three layers at once — what happened, feelings, and identity. A diagnostic pass (naming someone's motives or pattern) drags the identity layer into a thread that should stay on the "what happened" layer, which is exactly what makes it land as a threat rather than a fact [[2]](#references).
- Social psychology's Fundamental Attribution Error explains why this backfires even when the diagnosis is accurate: people attribute their own behavior to circumstances but attribute others' behavior to character, and this bias persists even when the situational explanation is known and explicit. Naming someone's "pattern" reads as a character judgment no matter how measured the language [[3]](#references).
- Rosenberg's Nonviolent Communication makes the same distinction from the writing-craft side: an observation ("you've made this argument three times") and an evaluation ("you're not actually listening") are different speech acts, and mixing them causes the reader to hear criticism and get defensive, even when the underlying observation is fair [[4]](#references).

Two-phase discipline follows directly from this:

**Phase 1 — Engage with layering.** Lead with the surface-level version of the argument. Offer to go deeper if the interlocutor is curious. Do not lead with the third-click-deep version; it oversaturates readers who cannot follow and reads as flexing. This is a layering change, not a softening change — every substantive position remains, and nothing gets conceded. Only the ordering and depth change.

**Phase 2 — Exit without diagnostic.** When further rounds are not producing new information (usually after 2 to 3 rounds of the same objection re-framed by the same person), disengage. Disengage on the merits, not on the pattern. Do not name the interlocutor's psychology, motivation, or the shape of their argument across rounds. The record speaks for itself — trust readers to see what you saw.

## What the exit looks like

Correct exit: *"I've made the case for X, Y, and Z. If there's a substantive alternative — a different mechanism that solves the same problem — I'm interested. Otherwise the proposal stands on those merits."*

Incorrect exit (diagnostic pass): *"None of the objections here actually engage with each other — everyone's raising a different concern but treating it as if it were shared."*

Both hold the substantive positions and refuse to concede. The difference: the first targets the argument, the second targets the interlocutors. A hostile reader can characterize the second as emotional; they have nothing to grab in the first.

## Test questions before posting

Run each of these against the draft:

1. **Subject test.** For every sentence, ask: is the subject the argument or the interlocutor? If any sentence's subject is the interlocutor's motivation, pattern, resistance, or psychology, cut it. Even if the observation is accurate — this is the observation/evaluation distinction from Nonviolent Communication [[4]](#references): "you've raised the same objection three times" is an observation; "you're not actually engaging" is an evaluation wearing observation's clothing, and readers hear the evaluation.
2. **Diagnostic-move check.** Search for shapes like:
   - "You're each reacting to ..."
   - "What you're actually doing / defending / resisting is ..."
   - "Your objections / arguments are disjoint / have shifted / keep re-framing ..."
   - "This is what happens when ..."
   - A verbal shrug at the interlocutor's stated position ("just, you know, X-ing it")
   - Locating a real disagreement beneath the stated one

   Any hit → cut. The noticing may be true and worth having; it does not belong in the record.
3. **Depth-layering check.** Does the reply lead with surface, then offer depth? Or does it lead with the deepest argument? If the latter, re-order.
4. **Reader-trust check.** After several rounds, would a careful reader of the whole thread see the pattern without being told? If yes, don't tell them. Silence on the pattern is stronger than naming it.
5. **Exit-vs-escalation check.** If disengaging, does the close read as "I'm done here" or as "and here's what you were really doing"? Only the first is disengagement; the second is escalation dressed as an exit.

## What this rule is NOT

Explicitly not:

- **Softening substantive positions.** Every position holds. Nothing is conceded on the merits.
- **Adding hedges to sound less confident.** "For what it's worth," "I could be wrong," "just my two cents" — don't appear.
- **Rolling over.** "But maybe you're right," "you have a point," "let me reconsider" — don't appear unless the interlocutor has actually made a substantive point that warrants revision.
- **Being warm or ingratiating.** No "Thanks [Name]" openers or other deferential softeners at the start of a reply.
- **Refusing to disengage.** Disengaging when the loop is unproductive is correct. What changes is how the disengagement is written.

The rule holds substance and confidence; it changes only the shape of engagement and exit.

## Applying it by round

- **Fresh (round 1–2):** apply layering discipline. Lead with the surface argument. Offer depth. Cite corpus authority where relevant. Don't preempt objections the interlocutor hasn't raised.
- **Mid-thread (round 3–4):** keep engaging substantively if the interlocutor is producing new arguments or engaging with prior points. If the same objection is being re-framed without engaging your counterarguments, prepare to exit at round 3 or 4 rather than round 6.
- **Disengaging:** (1) state that the substantive case has been made — name the axes; (2) open the door narrowly for genuine substantive alternatives, not more of the same; (3) let the record stand on its own merits; (4) stop. No diagnostic pass. No naming the pattern. No verbal shrug.

## Why this matters

Written technical threads are read by many people who are not the interlocutor. A diagnostic pass in the record costs credibility with those other readers regardless of whether the diagnosis of the immediate interlocutor is accurate — and it gives a hostile reader a way to recast an otherwise-sound technical position as "emotional, not technical." Holding the substance while changing only the shape of the exit protects the position without weakening it. This tracks the classical idea of ethos: an audience's willingness to trust an argument rides on its assessment of the arguer's character, not only the argument's logic, so a move that reads as an attack on character costs credibility independent of whether the underlying point was right [[5]](#references). Long-running technical review communities converge on the same norm from the practitioner side — critique and criticism of the work are core to the process; the discipline is keeping that critique terse and pointed at the work itself rather than the person making it [[6]](#references).

## References

1. Dale Carnegie, *How to Win Friends and Influence People* (1936) — on avoiding arguments and respecting the other person's opinion rather than telling them they're wrong.
2. Douglas Stone, Bruce Patton, and Sheila Heen (Harvard Negotiation Project), *Difficult Conversations: How to Discuss What Matters Most* (1999) — the "three conversations" model (what happened, feelings, identity) and the distinction between impact and intent.
3. Lee Ross, "The Intuitive Psychologist and His Shortcomings: Distortions in the Attribution Process," *Advances in Experimental Social Psychology* (1977) — coined the fundamental attribution error; see also Jones & Harris (1967) on dispositional attribution persisting even when situational causes are known.
4. Marshall B. Rosenberg, *Nonviolent Communication: A Language of Life* (2003) — the observation/evaluation distinction and its effect on whether a listener hears fact or criticism.
5. Aristotle, *Rhetoric* — ethos (character-based credibility) as, in Aristotle's own assessment, the most persuasive of the three appeals (ethos, pathos, logos).
6. The Linux kernel community's mailing-list and patch-review norms — a large, long-running written-technical-review culture built explicitly around direct critique of the work paired with an expectation of basic respect for the person; see the kernel documentation project's submitting-patches guide and community etiquette notes.
