---
name: doc-review-loop
description: Adam's document-writing workflow — draft toward a canonical shareable copy (a Google Doc, or a Notion page for docs that accompany other Notion content), then run a review loop where Adam reviews in the canonical copy and Claude applies edits there. Use when Adam says "start a doc", "draft a doc for review", "set up the doc review loop", "new doc for the writing log", or is writing a shareable document (design doc, proposal, review, enablement note, position paper) that will live in Google Docs or Notion. Also handles the iterative review phase: "here are my comments", "update the doc", "make these changes" on a doc already in the loop.
---

# Doc Review Loop

Adam's standard workflow for any shareable document. The **canonical, shareable copy** (referenced in his Writing Log) is either a **Google Doc** or a **Notion page**, chosen per document. For the Google Docs track, a Markdown file is the editing surface (Claude edits MD well; hand-editing a Google Doc is worse) and stays in sync with the Doc via a changelog. For the Notion track, there is no separate Markdown file — Claude edits the Notion page directly, since Claude can do that precisely and Notion's own Markdown import doesn't mangle formatting the way Google's does.

This skill is personal to Adam. It encodes conventions learned the hard way — follow them exactly.

## Choosing the canonical target

Two tracks, chosen per document — default to Google Docs; use Notion when the doc is a companion to something that already lives in Notion (e.g. a review sitting next to the design doc it reviews, or any doc that belongs alongside an existing Notion page/database entry). If it's not obviously one or the other, ask.

The tracks diverge fundamentally in where the editing surface lives and how review state is tracked. **Google Docs track:** the MD file is the editing surface, a changelog carries edits to the Doc, and the MD is disposed of at close. **Notion track:** there is no separate MD file at all — the Notion page IS the editing surface, Claude edits it directly, and review state is tracked with an in-page color marker instead of a changelog. Everything else in this skill (review-readiness passes, propose-location-and-confirm, the Writing Log fields and status lifecycle) is shared.

## The loop, end to end

**Google Docs track:**
1. **Draft** the document in Markdown (Claude).
2. **Review-readiness passes** (Claude, before Adam reads) — run whatever review agents fit the doc, so Adam's review isn't spent catching what automation would.
3. **Create the canonical Doc** (Claude) — see Formatting below.
4. **Link** the Doc in the Writing Log (Claude).
5. **Review** — Adam reviews/comments in the Doc; Claude applies edits to the **MD file** and maintains a changelog Adam pastes from.
6. **Iterate** step 5 until done.
7. **Disposition** the MD (see below).

**Notion track:**
1. **Draft directly on the Notion page** (Claude) — no separate MD file; the page is the editing surface from the start.
2. **Review-readiness passes** (Claude, before Adam reads) — same as the GDoc track.
3. **Create the page with full content** (Claude) — see Formatting below. Every block Claude writes carries the unreviewed marker (see Review-state tracking below).
4. **Link** the page in the Writing Log (Claude).
5. **Review** — Adam clears the unreviewed marker on blocks as he reviews them (in the Notion UI); Claude edits the page directly for any changes and re-marks only the blocks it touches.
6. **Iterate** step 5 until every block's marker is cleared.
7. Nothing to dispose — there is no MD file.

## Formatting — the load-bearing rule

This is where the two tracks genuinely diverge, in opposite directions — each rule below exists because of a specific converter's failure mode, so don't carry either rule over to the other track.

### Google Docs track

**NEVER create the canonical Doc with `create_doc_from_markdown` (or `update_doc_from_markdown`).** That MCP converter produces different vertical spacing, font sizes, and weights than Google Docs' own native Markdown import — which is what Adam uses. The divergence is in the converters' baked-in styling and cannot be fixed by adjusting the fed Markdown.

**Instead:** create a **title-only** Doc with the plain `mcp__claude_ai_Gdrive_Gusto__create_file` tool (a Google Doc with just the title, no body — so even the title doesn't pick up the wrong converter styling). Adam then does File → Import / paste-as-markdown himself and pastes the body. Claude owns *doc identity* (create + link); Adam owns *doc formatting* (his import).

When creating the title-only Doc, name it to match the document title. Report the Doc URL back so it can go in the Writing Log.

During review: Claude edits the MD and maintains a changelog (see Changelog conventions below); Adam applies the same edits to the Doc himself by pasting from the changelog.

### Notion track

Notion doesn't have the Google converter's failure mode — `notion-create-pages` takes Notion-flavored Markdown and renders it cleanly, and Claude can edit a Notion page directly and precisely with `notion-update-page` (targeted search/replace on real content). So the discipline inverts fully: **there is no separate MD file in this track.** The Notion page is both the canonical copy and Claude's editing surface — one artifact, not two kept in sync.

**Claude creates the page WITH full content directly**, via `notion-create-pages`. Skip the title-only-then-import dance entirely — it exists only to route around Google's converter, and there's nothing to route around here.

**Claude edits the page directly for the rest of the loop too**, via `notion-update-page`. There is no MD draft to edit instead, and no changelog — see Review-state tracking below for how Adam knows what changed since he last looked.

A lighter alternative exists — title-only page, Adam pastes the initial content himself — but Notion's paste-from-markdown is clunkier than Google's, so it's more friction for no real benefit. Default to Claude-creates-and-maintains; only fall back to the lighter form if Adam specifically wants to own the page body himself.

### Review-state tracking (Notion track only) — self-clearing yellow background

The changelog's job in the GDoc track — "what changed since Adam last reviewed, so he knows what to re-review" — is solved differently here, with a marker that leaves no residue once review is done:

- **Unreviewed or changed-since-last-review = the block carries a yellow background** (`{color="yellow_bg"}` on the block, per the enhanced-markdown spec), set via `notion-update-page`.
- **Every block Claude writes or edits starts with `yellow_bg`.** New content is unreviewed by definition.
- **Adam reviews a block by removing the yellow himself, in the Notion UI.** Clearing the mark IS the review action — there's no separate "mark as reviewed" step for him to remember.
- **When Claude edits an already-reviewed block, Claude re-applies `yellow_bg` to exactly the block(s) it changed** — flagging "re-review this." Never touch the color on blocks Adam has already cleared and Claude hasn't since edited.
- **End state: no color anywhere.** When every block is cleared, review is complete and the page is already in its final, mark-free form — no cleanup pass, unlike an in-page changelog or status tags, which leave editing residue behind.

**Granularity is the block Claude actually edited** — a paragraph, a list item, a heading — not a sub-sentence span and not a whole multi-block section when only one paragraph of it changed. The colored block(s) are the diff Adam reads; paragraph-level context is what he needs to re-review, not just the changed sentence in isolation.

**Never color content Adam authored himself** (e.g. the Author/Status front matter below) — it's reviewed by definition, and coloring it would wrongly flag his own content as needing his review. Only color content Claude wrote or edited.

**Use `yellow_bg` specifically**, not another background color.

### Author/Status front matter (Notion track only)

Every Notion-canonical doc starts with two front-matter lines at the very top of the page body, above the doc's own intro:

- **Author** line: `**Author:**` followed by a real Notion person-mention of the author (`mention-user`), not a plain-text name — it renders as an @-chip.
- **Status** line: a `**Status:**` label, then a real bulleted list (proper `- ` list blocks) with one dated entry per status transition, oldest first, each date a real Notion date-mention (`mention-date`), not plain text:
  ```
  **Author:** <mention-user url="user://...">
  **Status:**
  - <mention-date start="YYYY-MM-DD">: Draft
  - <mention-date start="YYYY-MM-DD">: In Review
  ```

Seed the log with `Draft` dated the creation date when the page is created; append a new dated bullet on each transition (Draft → In Review on loop close, then Accepted/Published/Archived later) — a running history, not an overwritten value. This mirrors the Writing Log's Status field but lives visibly in the doc, the way the Google Docs track's own inline status convention does.

Use real list blocks and real mentions, not a `<br>`-joined plain-text approximation — the fake version renders as one plain-text block, not a bulleted list with live chips. This front matter is Adam's own authored content, so per Review-state tracking above, never color it `yellow_bg`.

## Location — propose by project, always confirm

**Google Docs track.** Don't drop new Docs in Drive root (it has become a dumping ground). **Suggest a target folder based on the document's project/workstream, then always ask Adam to confirm or redirect before creating.** Never create without confirming the location.

Adam's work documents are organized **by project/workstream**, not by document type. The hub is `projects/domain-architects/`, with one subfolder per workstream (e.g. `domain-mapping`, `authn-authz-work-stream`, `cofounder`, `pii-architecture`, `kafka-eventing`, `ai-readiness`, `computation-performance`, `conway-analysis`, ...). Path shape: `projects/domain-architects/<workstream>/`.

(`writing/` is for *personal* writing projects and is almost never the right place for work docs. Don't default there.)

To propose:
1. Infer the workstream from the doc's subject (e.g. a domain-interview note → `domain-mapping`; an agent-authz design → `authn-authz-work-stream`).
2. Resolve the current folder IDs with `list_folder` (root → `projects` → `domain-architects` → the workstream). Don't hardcode IDs — they can change.
3. Present it: "I'll create this in `projects/domain-architects/domain-mapping/` — confirm or point me elsewhere?"
4. On confirm, pass that folder's ID as `parentFolderId` to `create_file`.

If the right workstream folder doesn't exist yet, propose the path and offer to create it (`create_folder`) before proceeding. If the subject doesn't clearly map to a workstream, ask rather than guess.

**Notion track.** Placement is by relationship to what the doc accompanies, not by workstream folder. Offer: (a) child of the page it accompanies, (b) a top-level sibling, or (c) a new shared parent holding both. Confirm before creating; don't guess.

## Changelog conventions (Google Docs track only — the Notion track has no changelog, see Review-state tracking above)

When Adam reviews in the Doc and asks for changes, edit the MD **and** maintain a changelog file (`<doc-name>-changelog.md`) so he can apply the same edits to the Doc. The changelog is a **copy/paste source**: Adam selects a quoted passage and pastes it straight into the Doc, so the quoted text must carry the styling it will have in the Doc. The changelog:

- **Fence each Original/Revised passage with distinctive marker lines, not `---`.** A horizontal rule is too subtle and collides with real section separators in the document. Use a line of non-standard characters that would never appear in actual prose, so the boundary is unmistakable and is trivially left out when Adam selects the passage between the markers. Convention:
  - `▼▼▼▼▼ ORIGINAL — paste-ready below ▼▼▼▼▼`
  - …the quoted original passage…
  - `▲▲▲▲▲ end original ▲▲▲▲▲`
  - `▼▼▼▼▼ REVISED — paste-ready below ▼▼▼▼▼`
  - …the quoted revised passage…
  - `▲▲▲▲▲ end revised ▲▲▲▲▲`
- **Always put a blank line between each sentinel marker and the quoted passage**, above and below. Without the blank line the marker sits on the line adjacent to the copy, and a triple-click or click-drag selection catches the sentinel text along with the passage — defeating the whole point of having an unmistakable boundary. The quoted passage must be isolated by whitespace on both sides so Adam can select it cleanly.
- **Reproduce the source's actual styling inside quoted passages, not just its emphasis.** If the quoted passage is (or contains) a heading, keep it as a Markdown heading (`##`) so it imports as a Doc heading and pastes in with the right style; keep `**bold**`/`*italic*` likewise. The quote should paste in looking like the Doc, because that is exactly what Adam does with it.
- **Code blocks are fine when the quoted content IS code; never let a code block reformat prose copy.** A quoted passage that is literal code (a schema, a permission expression, a snippet) belongs in a fenced code block in the changelog — it pastes into the Doc as a monospace block, which is correct. The rule is narrow: the code-block fence must wrap *only* the code, never bleed monospace styling onto surrounding prose that isn't code. (So: don't fence a mixed prose+code passage as one code block; split it. Headings inside quoted passages stay headings, per above.)
- **Use real Markdown emphasis** for the field labels, each on its own line: **Section:**, **Reason:**, **Original text:**, **Revised text:**. Never put the quoted text inline after the label — it makes the quote render as a run-on continuation of the bold label on Docs import.
- Each entry: the **section** it falls in, a one-line **reason**, the **original text**, and the **revised text**. For additions (no prior text), say so and quote the new text. When an entry also has small downstream edits in the same section that aren't worth full before/after blocks, summarize them in a short paragraph after the blocks.
- Date entries. Newest first.

## Hard rules during review (Google Docs track only)

- **Never re-pbcopy Adam's own edits.** When Adam pastes his edited version of a draft, the canonical copy is already where he put it — acknowledge and move on; don't copy it back.
- **pbcopy uses a quoted heredoc:** `pbcopy <<'EOF' ... EOF`, never `cat`/`echo` piped into pbcopy.
- When Adam wants a single passage to paste, pbcopy it. When there are multiple changes, write them to the changelog instead.

## Disposition of the MD file (Google Docs track only — the Notion track never has an MD file to dispose of)

Ask (or infer) which kind of doc this is:

- **Google-Doc-canonical** (most of Adam's docs — proposals, reviews, enablement notes, position papers): the MD is a draft. Once it's imported into the Doc and the loop is done, **delete the MD** — the Doc is canonical. Do not track it in a repo. Per the "no position papers in the ZP repo" rule, strategy/critique/position docs never go in a code repo regardless.
- **Repo-doc-with-Doc-mirror** (e.g. an architecture design that legitimately lives in `docs/`): the MD stays tracked; the Doc is a shareable mirror. Keep both in sync.

**Notion-Doc-canonical** is a disposition kind in name only, carried for symmetry with the Writing Log / Type framing — there's no MD file in the Notion track to apply it to. If a Notion-canonical doc happens to have been drafted at some path first (e.g. because the loop started before the target was chosen), delete that stray draft once the Notion page is the working surface; don't keep both.

If unsure, ask which before deleting anything.

## Writing Log

The canonical copy gets an entry in Adam's Writing database — same process regardless of track; **userDefined:URL** takes either a Google Doc URL or a Notion page URL.
- **Data source:** `collection://aa860749-821a-4bd9-a1cb-c165fe8ffa85` (under Adam's Hub).
- Set: **Title**, **Type** (ADR / Tech spec / Proposal / Architectural review / Note / Essay / Talk / Other), **Status** (Idea / Drafting / In Review / Accepted / Rejected / Published / Archived), **Audience** (Domain Architects / Privacy Engineering / Pro Leadership / Engineering at Large / External / Public / Personal / Mixed), **Topic** (multi-select, shared vocabulary — see gotcha below), **userDefined:URL** (the canonical copy's URL), **date:Started:start**, optionally **Big Ideas** (relation) to link the relevant hub Big Idea.
- Initial status when the entry is created: **Drafting**. **When the review loop closes (Adam says he's done reviewing), bump the entry to "In Review"** — authoring is done, it's out for others to comment. Don't use "Accepted"/"Published" prematurely.
- **Gotcha: `Topic` is a fixed multi-select vocabulary — never invent a value.** Pick from the existing set (check the data source for the current list; it evolves). A value not already in the vocabulary requires updating the data source first, not typing a new one into the property.

## Steps in practice

**Google Docs track:**
1. Draft the MD (in a sensible working location; if Google-Doc-canonical, it's a temp draft, not a repo file).
2. Run fit-appropriate review passes; apply fixes.
3. Create the title-only Doc via `create_file`; capture its URL.
4. Add a Writing Log entry with the URL; link the relevant Big Idea if there is one.
5. Tell Adam the Doc is ready for his import/paste.
6. On his comments: edit MD, update changelog, pbcopy single passages on request.
7. **Closing the loop** (Adam says he's done reviewing / "close the loop") is a single atomic checklist — do ALL of it, in order, before reporting the loop closed. Skipping the status bump leaves the entry showing HOT in `/today`, which is the tell that the close was half-done:
   1. Bump the Writing Log entry's **Status → "In Review"**. This is the step most easily forgotten because "close the loop" feels like a file operation — it is not done until the status is bumped.
   2. Clear or delete the changelog (it's spent scaffolding).
   3. Delete the MD (Google-Doc-canonical) or leave it tracked (repo-doc-with-mirror).

**Notion track:**
1. Draft directly on the Notion page via `notion-create-pages`, full content, placed per the confirmed location (no separate MD file).
2. Run fit-appropriate review passes on the drafted content before telling Adam it's ready; apply fixes directly on the page.
3. Every block written in steps 1–2 carries `yellow_bg` (see Review-state tracking above) — it's all unreviewed by definition.
4. Add a Writing Log entry with the page URL; link the relevant Big Idea if there is one.
5. Tell Adam the page is live and ready for his review.
6. Adam clears `yellow_bg` on blocks as he reviews them, in the Notion UI. On his comments: edit the page directly via `notion-update-page`, re-applying `yellow_bg` only to the block(s) actually touched.
7. **Closing the loop** (every block's `yellow_bg` is cleared, or Adam says he's done reviewing):
   1. Bump the Writing Log entry's **Status → "In Review"**.
   2. Append a dated `In Review` bullet to the page's own Author/Status front matter (see above) — the Writing Log and the in-page log both track this transition, independently.
   3. Confirm no block still carries `yellow_bg`. Nothing else to clean up — no changelog, no MD file.
