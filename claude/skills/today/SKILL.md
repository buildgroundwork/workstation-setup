---
name: today
description: Produces a daily orientation from Adam's Threads and Big Ideas databases in Notion — what's active, what's stale, what's blocked, what's the one question worth answering today, and what ideas might be worth revisiting. Use when the user asks "what's on my plate", "show me my threads", "what should I work on today", "any big ideas to revisit?", or invokes /today explicitly. Also supports capturing new Big Ideas ("save this as a Big Idea: …") and new Threads ("save this as a thread: …" / "save X to Threads in Notion").
---

# Today

Daily orientation reader for Adam's personal Threads and Big Ideas databases. Replaces the morning ritual of opening Notion to figure out what's active, what's stale, and what positions are worth revisiting.

## When to invoke

- User types `/today` or asks something like "what's on my plate?", "what should I work on today?", "show me my threads", "what's been sitting too long?", "what's blocked right now?", or "any big ideas to revisit?"
- User says "save this as a Big Idea: ..." or "capture this as a Big Idea" — the skill creates a new Big Ideas entry.
- User says "save this as a thread: ...", "capture this as a thread", or "save X to Threads in Notion" — the skill creates a new Threads entry.
- User invokes this skill explicitly via the Skill tool.

Don't invoke proactively without a request.

## What it does

Two modes:

1. **Orientation mode** (default, invoked by /today or similar): reads the Threads and Big Ideas databases via the `notiongusto` MCP and produces a concise daily orientation.
2. **Capture mode** (invoked by "save this as a Big Idea: …" or "save this as a thread: …"): creates a new row in the corresponding database with frictionless capture — infer the structured properties from content, confirm with user, save. The Big Ideas DB and the Threads DB each have their own capture variant.

## Prerequisites

The `notiongusto` MCP must be available in the session. If it isn't, surface that as an error: "The Notion MCP isn't available. This skill needs `notiongusto` to read the Threads and Big Ideas databases."

---

## Orientation mode

### Step 1 — Query the Threads database

Use `mcp__notiongusto__notion-query-data-sources` with:

```
data_source_urls: ["collection://3c070288-9d81-488e-ae21-1cf9cfc9a92a"]
query: 'SELECT url, "Title", "Status", "Priority", "Category", "Next action", "Waiting on", "userDefined:URL" AS link, "date:Last touched:start" AS last_touched, "Parent", "Children", "Depends on" FROM "collection://3c070288-9d81-488e-ae21-1cf9cfc9a92a" WHERE "Status" IN ("Active", "Watching", "Blocked")'
```

The result includes the self-referencing hierarchy and dependency relations: `Parent`, `Children`, `Depends on`. Each is a JSON array of thread URLs (or null).

### Step 2 — Query the Big Ideas database

Use `mcp__notiongusto__notion-query-data-sources` with:

```
data_source_urls: ["collection://3ccb78dc-a961-4b93-ad1e-4f64d4a93587"]
query: 'SELECT url, "Title", "Status", "Stance", "Topic", "Threads", "Next step", "date:Last revisited:start" AS last_revisited, "date:Next step updated:start" AS next_step_updated, "First surfaced" AS first_surfaced FROM "collection://3ccb78dc-a961-4b93-ad1e-4f64d4a93587" WHERE "Status" IN ("Germinating", "Crystallized")'
```

Notes on the new fields:
- `Threads` is a JSON array of Thread URLs (or null). A non-empty `Threads` means the Big Idea is being acted on via concrete work; the linked Thread's `Next action` is the de facto next step.
- `Next step` is rich text describing what would move the user's thinking on this idea forward. It's not an action commitment — it's an observation criterion or a thought-development cue. Set for Big Ideas that the user is *not* committing to action on yet (germinating).
- `next_step_updated` is the date the `Next step` text was last changed.

If either query fails, report the error and skip that section. Don't fabricate content.

### Step 3 — Categorize threads

From the Threads query results, build three lists:

- **Hot:** Status=Active AND Priority in (Now, This week). Sort by Priority (Now first), then by last_touched ascending (oldest = staler = more urgent). Up to 5 items.
- **Watching:** Status=Watching. Include the "Waiting on" field. Up to 5 items.
- **Blocked:** Status=Blocked. Include the "Waiting on" field. Up to 3 items.

**Filter umbrella threads.** A thread is an "umbrella" if its `Children` field is a non-empty JSON array. Filter umbrella threads out of all three lists before applying the size cap. Rationale: orientation is for action, and you act on leaves, not navigation nodes. The umbrella's status/priority is rolled up from its children; surfacing it alongside its children clutters the view without adding information.

**Resolve `Depends on` for Blocked items.** For each thread in the Blocked list, if its `Depends on` field is a non-empty JSON array, look up each linked thread by URL in the original query result set (no second query needed — the original `WHERE "Status" IN ("Active", "Watching", "Blocked")` returned them all if they're in scope). For each found dependency, capture its Title, Status, Priority, and Next action — these will be rendered inline beneath the blocked item in Step 5. If a `Depends on` URL doesn't resolve in the result set (because the linked thread is Done, On hold, Abandoned, or otherwise out of scope), skip it silently — don't fetch it separately.

### Step 4 — Pick Big Ideas to surface

From the Big Ideas query results, build one list:

- **Ideas worth revisiting:** Status in (Germinating, Crystallized) where any of:
  - `last_revisited` is null OR more than 30 days ago, OR
  - the Big Idea has no linked Threads AND no `Next step` set (it's drifting — neither in action nor in deliberate germination), OR
  - the Big Idea has no linked Threads AND `next_step_updated` is null OR more than 60 days ago (the recorded thinking has gone stale).

  Sort by: stale next-step first (oldest `next_step_updated` ascending), then drifting (no Thread + no Next step), then by `last_revisited` ascending (oldest = most overdue), then by `first_surfaced` ascending. Up to 3 items. Include Stance for context.

**Resolve `Threads` for each surfaced Big Idea.** For each Big Idea in the list with a non-empty `Threads` array, look up the linked thread(s) by URL in the Threads query result set (from Step 1). For each found thread, capture its Title, Status, Priority, and Next action — these will be rendered inline beneath the Big Idea in Step 5. If a linked thread doesn't resolve (it's Done / On hold / Abandoned / out of scope), skip it silently.

Skip the Big Ideas section entirely if the database has no rows matching, or if all entries are fresh (recently revisited *and* have an active next step or linked Thread). Don't force content where there isn't any.

### Step 5 — Produce the orientation

Output a single document. Maximum ~250 words total (slightly more than the previous 200 to accommodate the Big Ideas section). Use this shape:

```
## 🔥 Hot today

- **[Title]** — [Next action]. _(last touched [N] days ago)_
- ...

## 👀 Watching

- **[Title]** — waiting on [Waiting on field]
- ...

## 🚧 Blocked

- **[Title]** — blocked on [Waiting on field]
  - _Unblock by:_ **[Depends-on thread title](url)** — [its Status / Priority] — [its Next action]
- ...

## 💭 Ideas worth revisiting

- **[Title]** _([Stance])_ — [next-line rendering depends on the Big Idea's state, see below]
- ...

Rendering rule for the second line of each Big Idea:

- **If linked Thread exists** (resolved from Step 4): `_next: see [Thread title](url) — [Status / Priority]_`. The linked Thread is doing the work; the Big Idea is being acted on.
- **Elif `Next step` is set:** `_next: [Next step text]_  _(updated [N] days ago)_`. If `next_step_updated` is null or more than 60 days ago, append `— **stale; still right?**`
- **Else:** `_no next step recorded — drifting_`. This Big Idea has neither action nor recorded thinking-criterion. Surface it more loudly.

Append the last-revisited parenthetical at the end of the second line: `last revisited [N] days ago` or `never revisited`.

## The one question

[Given the above, what's the most important thing the user would be sad not to make progress on today? Phrase as a direct question to the user, one sentence, no hedging. The question can be about a Thread *or* a Big Idea — whichever has the most momentum at risk.]
```

For each thread and Big Idea, include a markdown link to its Notion page (use the page URL from the query result `url` field) so the user can click through.

If `last_touched` or `last_revisited` is null, omit the parenthetical or say "never revisited." Don't make up dates.

### Step 6 — Don't add commentary

The orientation is the document. Don't preface it with "Here's your orientation:" or follow it with "Let me know if you want more detail." The user will ask if they want more.

---

## Capture mode

Capture has two variants — one for Big Ideas, one for Threads. They follow the same shape (parse → infer → confirm → save) but with different inferred properties. Route by the trigger phrase:

- "save this as a Big Idea: …" / "capture this as a Big Idea" → **Big Ideas capture**
- "save this as a thread: …" / "capture this as a thread" / "save X to Threads in Notion" → **Threads capture**

If the trigger phrase is ambiguous (e.g. "save this to Notion"), ask which DB before proceeding. Don't guess.

---

### Big Ideas capture

When the user says "save this as a Big Idea: [content]" or similar:

#### Step 1 — Parse the content

The user provides a short statement, a paragraph, or a longer thought. Treat whatever follows "Big Idea:" (or the equivalent phrasing) as the content.

#### Step 2 — Infer properties

- **Title:** generate a one-line summary, max ~80 chars, capturing the essence of the idea. This will be the row's Title. Always show the user the suggested Title before saving.
- **Stance:** infer from the content shape:
  - "X should be Y" / "X is the right/wrong Z" → **Position**
  - "X cannot do Y because Z" / "Here's what's actually happening" → **Diagnosis**
  - "Whenever X, then Y" / "This recurring pattern" → **Pattern**
  - "I notice that X" / "It seems X" → **Observation**
  - "What if X?" / "How do we Z?" → **Open question**
  - When ambiguous, ask the user.
- **Topic:** keyword-match the content against the closed Topic vocabulary (see Database reference). Surface the inferred topics to the user; let them adjust.
- **Status:** default to `Germinating` for new entries.
- **Next step:** propose a sentence that describes *what would move thinking on this idea forward* — not a task commitment, an observation criterion. Examples:
  - For a Position: *"watch for the next decision in domain X and see whether the predicted dynamic plays out"*
  - For a Diagnosis: *"check whether the named cause is still the root cause in 30 days"*
  - For an Open question: *"look for an example where the question would have to be answered, then revisit"*
  - When unclear, leave blank and ask the user whether this idea is being acted on now (link a Thread) or left to germinate (set a Next step) or neither (leave both blank — but the orientation will flag it as drifting).

#### Step 3 — Confirm with the user

Show the proposed Title, Stance, Topics, and Next step in a single concise message. Ask the user to confirm or adjust. Example:

> Saving as a Big Idea:
> **Title:** [proposed title]
> **Stance:** [Position / Diagnosis / Pattern / Observation / Open question]
> **Topics:** [Topic1, Topic2]
> **Next step:** [proposed next step, or "(none — let it germinate)"]
>
> Is this idea also active work? (If yes, I'll suggest a linked Thread.)
>
> Confirm or adjust?

#### Step 4 — Save

Once confirmed, use `mcp__notiongusto__notion-create-pages`:

```
parent: { "type": "data_source_id", "data_source_id": "3ccb78dc-a961-4b93-ad1e-4f64d4a93587" }
pages: [{
  "properties": {
    "Title": "<confirmed title>",
    "Status": "Germinating",
    "Stance": "<confirmed stance>",
    "Topic": "<JSON array of confirmed topics>",
    "Next step": "<confirmed next step, or omit if none>",
    "date:Next step updated:start": "<today's date in YYYY-MM-DD if Next step is set, else omit>",
    "date:Next step updated:is_datetime": 0
  },
  "content": "<the full content the user provided, as page body>"
}]
```

Report back with the URL of the new entry.

#### Step 5 — Don't auto-cross-reference

Cross-references to Threads, Writing, or Field Stones are valuable but the user should set them — keyword matching is too noisy here. After saving, if there are obvious candidates from active Threads, suggest them as a follow-up: "Want to link this to [existing thread]?" but never auto-link.

---

### Threads capture

When the user says "save this as a thread: [content]", "capture this as a thread", or "save X to Threads in Notion":

#### Step 1 — Parse the content

Treat whatever follows the trigger phrase as the content. The content typically describes a piece of work, a relationship dynamic, a decision to make, or a hygiene item. Often a paragraph or two; can be a single sentence.

#### Step 2 — Infer properties

- **Title:** generate a one-line summary, max ~80 chars, capturing the work to be done (not the situation). Prefer imperative form ("Land ADR 644", "Respond to Stephan's 1:1 offer"). Always show before saving.
- **Status:** default to `Active` for new captures. Use `Watching` only if the content explicitly describes waiting on something external (e.g., "waiting for X to respond"). Use `Blocked` only if the content explicitly names a prerequisite thread.
- **Priority:** infer from urgency language in the content:
  - "now", "today", "urgent", "before EOD" → **Now**
  - "this week", "by Friday", "soon" → **This week**
  - "this month", "by end of Q*", "in the next few weeks" → **This month**
  - "eventually", "someday", "low priority" → **Eventually**
  - "back burner", "if I get to it" → **Back burner**
  - When ambiguous, default to **This week** and flag for user confirmation.
- **Category:** infer from content shape:
  - Implementation work, coding, ADRs being filed, tech specs → **Active work**
  - People dynamics, 1:1s, replies to messages → **Relationship**
  - "Decide X", "figure out whether Y", facilitating a contested ADR → **Decision**
  - Cleanups, database hygiene, archival, dedupes → **Database hygiene**
  - Long-term positioning, role decisions, organizational concerns → **Strategic**
  - Otherwise → **Other**
- **Topic:** keyword-match against the closed Topic vocabulary. Surface the inferred topics; let the user adjust.
- **Next action:** extract or synthesize a single concrete next action from the content. Imperative form. If the content doesn't suggest one clearly, ask the user.
- **Waiting on, Parent, Depends on:** don't infer these. Leave null. The user can set them later if needed.

#### Step 3 — Confirm with the user

Show the proposed properties in a single concise message. Ask the user to confirm or adjust. Example:

> Saving as a Thread:
> **Title:** [proposed title]
> **Status:** Active
> **Priority:** [Now / This week / This month / Eventually / Back burner]
> **Category:** [Active work / Relationship / Decision / Database hygiene / Strategic / Other]
> **Topic:** [Topic1, Topic2]
> **Next action:** [proposed next action]
>
> Confirm or adjust?

If any property was ambiguous and you defaulted, call it out: *"(defaulted Priority to This week — adjust if wrong)"*.

#### Step 4 — Save

Once confirmed, use `mcp__notiongusto__notion-create-pages`:

```
parent: { "type": "data_source_id", "data_source_id": "3c070288-9d81-488e-ae21-1cf9cfc9a92a" }
pages: [{
  "properties": {
    "Title": "<confirmed title>",
    "Status": "<confirmed status>",
    "Priority": "<confirmed priority>",
    "Category": "<confirmed category>",
    "Topic": "<JSON array of confirmed topics>",
    "Next action": "<confirmed next action>"
  },
  "content": "<the full content the user provided, as page body>"
}]
```

Report back with the URL of the new entry.

#### Step 5 — Don't auto-link

Don't infer Parent, Depends on, or other relations from content. The user sets those. If the content mentions another thread by title, you can suggest the link as a follow-up question ("Want to link this to [existing thread] as a Parent / Depends on?") but never auto-link.

---

## Guardrails

- **One source of truth.** Don't pull from anywhere except the Threads and Big Ideas databases. Don't synthesize content from conversation history.
- **Stay under ~250 words** for orientation mode. The orientation's value is concision. If there are more than 5 hot items, list 5 and add "and N more in 'This week'" line.
- **The one question must be specific.** Bad: "What's most important?" Good: "Have you decided whether to send the deferral to Stephan?" Pick the one item where momentum is most at risk.
- **Don't recommend abandoning work.** The user decides what to abandon, not the skill.
- **Don't include Done, Abandoned, Superseded, or Written up entries** in orientation mode.
- **Filter umbrella threads from all sections.** A thread with non-empty `Children` is a navigation node, not action. Surface only leaves.
- **Surface `Depends on` for Blocked items only.** Don't try to surface dependencies for Active or Watching items — it's noise. Blocked is where the dependency context matters.
- **Don't infer dependencies from `Waiting on` text.** Only use the structured `Depends on` relation. `Waiting on` is free text; treating it as a typed link would be Jira reinvention.
- **Capture mode requires user confirmation.** Don't save silently — always show the proposed properties first. Applies to both Big Ideas and Threads capture.
- **Don't auto-cross-reference captures with other databases.** Suggest, don't link. Applies to both variants.
- **Threads capture: don't infer commitment-shaped fields silently.** Priority and Category are commitments. The confirm step exists so you correct bad inferences before they're saved. Always default to **This week** for Priority when ambiguous and flag the default in the confirm message.
- **Big Ideas: `Next step updated` must move with `Next step`.** Any time the skill writes to `Next step` (on create, or when the user updates it via conversational request), also write today's date to `Next step updated`. The staleness signal depends on this — if `Next step updated` falls behind, /today will incorrectly flag fresh thinking as stale.
- **Big Ideas: linked Thread takes precedence over `Next step`.** When a Big Idea has both, the linked Thread is the source of truth for what's next. `Next step` is only used when no Thread is linked. Don't surface both in orientation.

---

## Database reference

### Threads database

- **URL:** `https://www.notion.so/bd8aaf0510274df183bfa2d7d75b10ef`
- **Data source:** `collection://3c070288-9d81-488e-ae21-1cf9cfc9a92a`

Schema:

- **Title** (title)
- **Status** (select): `Active` | `Blocked` | `Watching` | `On hold` | `Done` | `Abandoned`
- **Priority** (select): `Now` | `This week` | `This month` | `Eventually` | `Back burner`
- **Category** (select): `Active work` | `Relationship` | `Decision` | `Database hygiene` | `Strategic` | `Other`
- **Topic** (multi-select) — shared vocabulary
- **Next action** (rich text)
- **Waiting on** (rich text) — free-text annotation describing the wait. May refer to an external thing (a person, a date, an event). Not a typed link — see `Depends on` for that.
- **userDefined:URL** (URL)
- **Last touched** (date)
- **Notes** (rich text)
- **Parent** (self-relation, dual with `Children`) — umbrella thread this leaf belongs to.
- **Children** (self-relation, dual with `Parent`) — auto-populated when other threads set this as their `Parent`. Non-empty `Children` marks this thread as an umbrella; orientation filters umbrellas out.
- **Depends on** (self-relation, dual with `Blocks`) — other threads in this DB that must finish before this one can proceed. Surfaced inline under Blocked items in orientation.
- **Blocks** (self-relation, dual with `Depends on`) — auto-populated when other threads set this as a `Depends on`. Notion keeps the two sides synchronized server-side; updating one updates the other.

### Big Ideas database

- **URL:** `https://www.notion.so/9daed6da0e75404db59215db751c0e2d`
- **Data source:** `collection://3ccb78dc-a961-4b93-ad1e-4f64d4a93587`

Schema:

- **Title** (title)
- **Status** (select): `Germinating` | `Crystallized` | `Written up` | `Superseded` | `Abandoned`
- **Stance** (select): `Position` | `Diagnosis` | `Pattern` | `Observation` | `Open question`
- **Topic** (multi-select) — shared vocabulary
- **First surfaced** (created time, read-only)
- **Last revisited** (date)
- **Next step** (rich text) — what would move thinking on this idea forward. Not a task commitment. Set for Big Ideas that the user is *not* acting on yet but wants to revisit deliberately. Leave empty when the Big Idea has a linked Thread (the Thread carries the action) or when the idea is in pure germination with no active criterion.
- **Next step updated** (date) — set when `Next step` text changes. Used to surface stale next-steps that haven't been touched in 60+ days.
- **Threads** (relation to Threads database) — Big Ideas being acted on via concrete work link here. The linked Thread's `Next action` becomes the de facto next step.
- **Writing** (relation to Writing database)
- **Source stones** (relation to Field Stones database)
- **Notes** (rich text) — short summary; full content lives in the page body

### Shared Topic vocabulary

`Inverse Conway / Org Design` | `Distributed Systems` | `Domain-Driven Design` | `Eventing & Kafka` | `Privacy & PII` | `AuthN/AuthZ & ReBAC` | `Interservice Communication` | `Service Extraction` | `Career & Strategy` | `AI / LLM Tooling` | `Engineering Culture & Process` | `Industry Patterns` | `Domain: Payroll / Tax` | `Domain: Benefits / Retirement` | `Domain: Identity / Entity` | `Gusto Pro Strategy` | `Uncategorized`

---

## Future

This skill is the interim before the planned reading/writing/stones plugin grows similar capabilities. The Big Ideas integration is intentionally personal to Adam and is not part of the generalizable plugin's design. See `https://www.notion.so/361ad673c6c2811ca717f7a551adc22c` for the plugin design.
