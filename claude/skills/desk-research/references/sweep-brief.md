# Sweep brief (template for desk-research subagents)

Fill in the bracketed fields and pass this as the subagent's prompt, one subagent per source family.

---

You are sweeping **[source family]** for the **[project]** project, read-only, to feed its project map in Ode's Context Store. You find and classify material; you do not write the map.

**Sources to sweep:** [locations from the source inventory: page IDs, channel IDs, folder IDs, Fellow channel ID, Granola folder, repos]

**Only items newer than:** [high-water mark, or "everything" in build mode]

**Map sections** (place each finding in one): [section list from the spec]

Load deferred tools with ToolSearch before calling them. Use the Read tool for local files, not shell viewers; for oversized tool output saved to a file, extract with `jq`.

**Rules**
- Read-only. Do not post, edit, create, delete, or react to anything anywhere.
- Never reproduce credentials, keys, or tokens, or say where their values are written.
- Distinguish what was decided, what was proposed, what was delivered, and what was only discussed. Date every finding and name its source.
- Apply the confidentiality test to every finding: could any of it be client confidential (or fall in the specs' never-inline list)? If there's any doubt, set `confidential: yes`, and flag topics whose name alone is sensitive. The writer will reduce it to a topic and a link. Still give enough of a summary for the writer to dedupe and place it; that summary is never published.

**Return** a list of findings, each with:
- `section`: one of the map sections
- `topic`: a short, non-confidential name for what this is about
- `summary`: one or two sentences (internal, for dedupe and placement only)
- `source`: title and URL or ID of the most canonical place it lives
- `date`: when the fact was established
- `confidence`: Confirmed, Reported, or Inferred, per the spec
- `confidential`: yes or no
- `supersedes`: the earlier finding or entry it replaces, if any

Then list: conflicts between sources (both sources each); sources you couldn't reach and why; and the new high-water mark per source (the timestamp or ID of the newest item you processed).
