---
name: desk-research
description: Builds or refreshes a client project's map in Ode's Context Store (Notion, General › Context Store › Project Maps › <project>) by sweeping every source the team uses — Notion (including Quarterdeck's nightly pages), Slack, Google Drive and Docs, Gmail, Granola, Fellow, and GitHub — reading what's new, and writing a curated, link-first index that follows "Spec | Context Store" and "Spec | Project maps". Use when the user asks to "build the project map", "refresh/update the map for <project>", "do desk research on <project>", "sweep the sources for <project>", or invokes /desk-research. Not for one-off questions about a project (answer those directly) and not for writing a single learning into a map (that's the update skill).
---

# Desk research

Sweeps a project's sources and writes its project map. The map is an index, not an archive: every entry names a topic and points at the canonical source. The rules for what a map contains live in the specs, not here, so the specs can change without editing this skill.

## Prerequisites

The session needs connectors for Notion and Slack at minimum, plus Google Drive, Gmail, Granola, and Fellow for a full sweep, and the `gh` CLI for GitHub. Load deferred tools with ToolSearch before calling them, e.g.:

- `select:mcp__claude_ai_Notion__notion-search,mcp__claude_ai_Notion__notion-fetch,mcp__claude_ai_Notion__notion-create-pages,mcp__claude_ai_Notion__notion-update-page,mcp__claude_ai_Notion__notion-query-data-sources`

A missing connector is not fatal: sweep what's reachable, and list the unreachable sources in the report and the map log.

## Step 1: Load the spec and find the map

1. Search Notion for the **"Context Store"** page (root of the General teamspace) and its child **"Project Maps"**. Each links its spec as a child page at the top: **"Spec | Context Store"** holds the principles for every page, and **"Spec | Project maps"** adds the map's sections, entry format, confidence labels, and confidentiality rules. Fetch both specs and **follow them as the source of truth.** If either conflicts with anything below, the spec wins. Never assume page IDs; search every time.
2. Find the project's page among Project Maps' children.
   - Page exists with a map log → **refresh mode**. Read the map log's per-source high-water marks.
   - Page exists as a placeholder, or doesn't exist → **build mode**. Create the page under Project Maps if needed, titled with the project's short name.

## Step 2: Inventory the sources

Find every place the project's material lives, and record each one with a link. Start from the project's entry in the Notion Project Database (search the project name): its properties and Quick Links usually name the Slack channel, Drive folder, Fellow channel, Granola folder, SOW, and repos. Then confirm and extend:

| Source | How to find it |
|---|---|
| Notion | Project Database entry and its children (Meetings, Project Docs, trackers, concept DBs); Quarterdeck's Briefings, Daily Logs, Risk Register, Decision Log, Key People, and Glossary under the project page; team members' personal pages that link back |
| Slack | Channel named in the project entry; `slack_search_channels` for the project name (include private); group DMs the user is in that discuss the project |
| Google Drive / Docs | The project folder from the project entry; walk its subfolders with `search_files` on `parentId` |
| Gmail | Threads with the client's domain and the project's group alias |
| Granola | `list_meeting_folders` for a folder named for the project; `search_meetings` on the client name |
| Fellow | `list_channels` with the client name; that channel's meetings |
| GitHub | Repos named in the project entry or Tech Transition doc; `gh search repos <project> --owner <org>` |

If a source the project clearly uses can't be found or reached (for example a client portal), note it as a gap; don't guess. Ask the user only if a whole source family is missing and they're likely to know where it is.

## Step 3: Sweep

In build mode, sweep everything. In refresh mode, sweep only what is newer than each source's high-water mark.

Fan out one subagent per source family, in parallel, in a single message (Notion with Quarterdeck; Slack; Drive and Docs; Gmail; Granola and Fellow; GitHub). Brief each with `references/sweep-brief.md`, filled in with the project, the source locations from Step 2, the high-water marks, and the current map's section list. Each returns structured findings, not prose. Subagents are read-only.

Small projects or narrow refreshes can be swept inline instead; the brief's rules still apply.

## Step 4: Hand the findings to the map writer

Merge the subagents' findings into one list, keeping each finding's fields from the sweep brief, and call the **project-map-writer** agent. It is the single writer for project maps: it applies the specs, the confidentiality test, the security rules, deduplication, conflict handling, the write itself, and the map log entry. Don't repeat those rules here, and don't write the map yourself.

Brief it with:

- `project` and `mode` (`build` or `refresh`);
- the merged `findings`;
- the new per-source high-water marks, or "unreachable: <reason>" for each source family you couldn't reach;
- `ran_by` (the user) and `caller: desk-research`.

Pass it findings as data. Don't pass your own conclusions about what is confidential; the writer decides.

## Step 5: Verify the write

The writer has no shell and can't always re-read a large map: `notion-fetch` saves a long page to a file as one line. You verify. Fetch the map before Step 4 in refresh mode and after the writer returns, and extract the text from each saved file with `jq`. Check the shape first (`.text` at the top level, or an array whose first element's `.text` is itself JSON). Then confirm:

- every section heading from before is still there, and none the writer was told not to touch has changed;
- the new map log entry is present;
- the page's size before and after, which you measure (the writer reports none it didn't measure);
- none of the writer's reported pointer-only entries has its substance inline, by searching for the specific terms you know were confidential.

If a check fails, tell the user what you found instead of reporting success.

## Step 6: Report

Tell the user, briefly, from the writer's report and your verification: build or refresh; sections added or changed; notable new entries; entries reduced to a pointer; conflicts recorded; stale candidates the writer left alone; the page's size before and after; sources unreachable and what that hides. Link the map. Don't paste the map into chat.

## Gotchas

- **Fellow and Granola overlap.** The same meeting is often in both. Granola transcripts are usually fuller; Fellow has calls Granola missed. Dedupe by date and title.
- **Large Gmail threads overflow tool output.** The result is saved to a file; extract senders, dates, and bodies with `jq` rather than reading it whole, and strip quoted history.
- **Quarterdeck pages regenerate nightly.** Link the index pages (Briefings, Decision Log), not a single day's briefing, unless an entry depends on that day.
- **Slack threads hide content.** A channel read shows thread parents only; read threads whose replies matter.
- **Never copy a secret.** Credential documents get a pointer to their access-controlled location and nothing else.
