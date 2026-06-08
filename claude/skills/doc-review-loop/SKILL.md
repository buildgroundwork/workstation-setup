---
name: doc-review-loop
description: Adam's document-writing workflow — draft in Markdown, mirror to a Google Doc as the canonical shareable copy, then run a review loop where Adam reviews in the Doc and Claude edits the Markdown and maintains an import-safe changelog. Use when Adam says "start a doc", "draft a doc for review", "set up the doc review loop", "new doc for the writing log", or is writing a shareable document (design doc, proposal, review, enablement note, position paper) that will live in Google Docs. Also handles the iterative review phase: "here are my comments", "update the doc", "make these changes" on a doc already in the loop.
---

# Doc Review Loop

Adam's standard workflow for any shareable document. The Markdown file is the editing surface (Claude edits MD well; Doc edits poorly); the **Google Doc is the canonical, shareable copy** (referenced in his Writing Log); and a **changelog file** carries edits back from MD into the Doc.

This skill is personal to Adam. It encodes conventions learned the hard way — follow them exactly.

## The loop, end to end

1. **Draft** the document in Markdown (Claude).
2. **Review-readiness passes** (Claude, before Adam reads) — run whatever review agents fit the doc, so Adam's review isn't spent catching what automation would.
3. **Create the canonical Google Doc** — an **empty, title-only** Doc (Claude), so it has a stable ID/URL to reference. **Adam imports the MD himself** and pastes content in (this preserves his formatting — see Formatting below).
4. **Link** the Doc in the Writing Log (Claude).
5. **Review** — Adam reviews/comments in the Doc; Claude applies edits to the **MD file**; Claude writes/updates a **changelog** Adam uses to apply the same edits to the Doc.
6. **Iterate** step 5 until done.
7. **Disposition** the MD (see below).

## Formatting — the load-bearing rule

**NEVER create the canonical Doc with `create_doc_from_markdown` (or `update_doc_from_markdown`).** That MCP converter produces different vertical spacing, font sizes, and weights than Google Docs' own native Markdown import — which is what Adam uses. The divergence is in the converters' baked-in styling and cannot be fixed by adjusting the fed Markdown.

**Instead:** create a **title-only** Doc with the plain `mcp__claude_ai_Gdrive_Gusto__create_file` tool (a Google Doc with just the title, no body — so even the title doesn't pick up the wrong converter styling). Adam then does File → Import / paste-as-markdown himself and pastes the body. Claude owns *doc identity* (create + link); Adam owns *doc formatting* (his import).

When creating the title-only Doc, name it to match the document title. Report the Doc URL back so it can go in the Writing Log.

## Location — propose by project, always confirm

Don't drop new Docs in Drive root (it has become a dumping ground). **Suggest a target folder based on the document's project/workstream, then always ask Adam to confirm or redirect before creating.** Never create without confirming the location.

Adam's work documents are organized **by project/workstream**, not by document type. The hub is `projects/domain-architects/`, with one subfolder per workstream (e.g. `domain-mapping`, `authn-authz-work-stream`, `cofounder`, `pii-architecture`, `kafka-eventing`, `ai-readiness`, `computation-performance`, `conway-analysis`, ...). Path shape: `projects/domain-architects/<workstream>/`.

(`writing/` is for *personal* writing projects and is almost never the right place for work docs. Don't default there.)

To propose:
1. Infer the workstream from the doc's subject (e.g. a domain-interview note → `domain-mapping`; an agent-authz design → `authn-authz-work-stream`).
2. Resolve the current folder IDs with `list_folder` (root → `projects` → `domain-architects` → the workstream). Don't hardcode IDs — they can change.
3. Present it: "I'll create this in `projects/domain-architects/domain-mapping/` — confirm or point me elsewhere?"
4. On confirm, pass that folder's ID as `parentFolderId` to `create_file`.

If the right workstream folder doesn't exist yet, propose the path and offer to create it (`create_folder`) before proceeding. If the subject doesn't clearly map to a workstream, ask rather than guess.

## Changelog conventions (must import cleanly into Google Docs)

When Adam reviews in the Doc and asks for changes, edit the MD **and** maintain a changelog file (`<doc-name>-changelog.md`) so he can apply the same edits to the Doc. The changelog:

- **No code blocks or quote blocks.** They render badly on Google Docs import. Quoted before/after text goes in plain paragraphs.
- **Use real Markdown emphasis** (`**bold**`, `*italic*`) — Google Docs renders it on import. Bold the field labels: **Section:**, **Reason:**, **Original text:**, **Revised text:**.
- **Reproduce the document's own emphasis** inside quoted passages, so the before/after matches the source.
- Each entry: the **section** it falls in, a one-line **reason**, the **original text**, and the **revised text**. For additions (no prior text), say so and quote the new text.
- Date entries.

## Hard rules during review

- **Never re-pbcopy Adam's own edits.** When Adam pastes his edited version of a draft, the canonical copy is already where he put it — acknowledge and move on; don't copy it back.
- **pbcopy uses a quoted heredoc:** `pbcopy <<'EOF' ... EOF`, never `cat`/`echo` piped into pbcopy.
- When Adam wants a single passage to paste, pbcopy it. When there are multiple changes, write them to the changelog instead.

## Disposition of the MD file

Ask (or infer) which kind of doc this is:

- **Google-Doc-canonical** (most of Adam's docs — proposals, reviews, enablement notes, position papers): the MD is a draft. Once it's imported into the Doc and the loop is done, **delete the MD** — the Doc is canonical. Do not track it in a repo. Per the "no position papers in the ZP repo" rule, strategy/critique/position docs never go in a code repo regardless.
- **Repo-doc-with-Doc-mirror** (e.g. an architecture design that legitimately lives in `docs/`): the MD stays tracked; the Doc is a shareable mirror. Keep both in sync.

If unsure, ask which before deleting anything.

## Writing Log

The canonical Doc gets an entry in Adam's Writing database.
- **Data source:** `collection://aa860749-821a-4bd9-a1cb-c165fe8ffa85` (under Adam's Hub).
- Set: **Title**, **Type** (ADR / Tech spec / Proposal / Architectural review / Note / Essay / Talk / Other), **Status** (Idea / Drafting / In Review / Accepted / Rejected / Published / Archived), **Audience** (Domain Architects / Privacy Engineering / Pro Leadership / Engineering at Large / External / Public / Personal / Mixed), **Topic** (multi-select, shared vocabulary), **userDefined:URL** (the Doc), **date:Started:start**, optionally **Big Ideas** (relation) to link the relevant hub Big Idea.
- Initial status when the entry is created: **Drafting**. **When the review loop closes (Adam says he's done reviewing), bump the entry to "In Review"** — authoring is done, it's out for others to comment. Don't use "Accepted"/"Published" prematurely.

## Steps in practice

1. Draft the MD (in a sensible working location; if Google-Doc-canonical, it's a temp draft, not a repo file).
2. Run fit-appropriate review passes; apply fixes.
3. Create the title-only Doc via `create_file`; capture its URL.
4. Add a Writing Log entry with the URL; link the relevant Big Idea if there is one.
5. Tell Adam the Doc is ready for his import/paste.
6. On his comments: edit MD, update changelog, pbcopy single passages on request.
7. On completion (Adam says he's done reviewing): bump the Writing Log entry to **In Review**, then disposition the MD.
