# Global preferences (Adam Milligan)

Standing, cross-project preferences. These apply on this machine in every session, regardless of working directory. Project-specific facts and any candid internal/political notes stay in per-repo memory (`~/.claude/projects/*/memory/`) and deliberately do **not** live here — this file is version-controlled in a shared dotfiles repo.

The toolchain sections (Git, Ruby/RSpec/Sorbet) only apply when working in that toolchain; ignore them otherwise.

## Working style (all sessions)

- **Use first-person pronouns naturally** ("I", "me") in user-facing text. Don't strip them in the name of terseness.
- **Don't expand the scope of destructive actions.** When deleting or closing something, do exactly what was asked — no "while we're at it" additions. Surface adjacent cleanups as a separate suggestion, don't bundle them in.
- **Match the existing style of a file** before imposing a convention (matcher forms, syntax, naming). Consistency within the file wins over personal preference.
- **Declarative ordering**: define the thing first. Public methods before private, the subject-under-test before its inputs, high-level before helpers.
- **Verify an AI agent's actual registered tool surface** (in running code) before claiming what it can or cannot do. Don't infer capability from adjacent scaffolding.

## Drafting & documents

- **Clipboard:** copy to the macOS clipboard with a direct heredoc into `pbcopy`, never piped through `cat`/`echo`:

  ```
  pbcopy <<'EOF'
  ...content...
  EOF
  ```

  Not `cat <<'EOF' | pbcopy`. `pbcopy` already reads stdin; the pipe adds a useless process. Quote the delimiter (`'EOF'`) so `$`, backticks, etc. aren't expanded. Generalize this to any stdin-reading tool (`gh pr comment --body-file -`, `jq`) — prefer a direct heredoc over `cat | tool`.

- **Don't re-`pbcopy` Adam's own edits.** When Adam pastes his edited version of something I drafted, the canonical copy already lives wherever he put it (Slack, a doc). Copying it back creates a stale duplicate. Treat the paste as "here's what I'm using" and respond to the substance. `pbcopy` is for *my* drafts he hasn't yet placed somewhere; once edited and placed, copying adds nothing. If unsure, ask.

- **Don't edit Google Docs directly** (no MCP doc-edit tools that mutate the canonical copy). Draft in Markdown, show Adam the diff, and let him apply changes to the Google Doc himself — the Doc is the canonical shareable copy and he controls what lands in it.

- **Changelog / markdown formatting:** leave prose content as live (unfenced) Markdown so it renders. Only fence actual code blocks — don't fence before/after content blocks.

## Communication register (Slack, doc comments, PR replies)

- **Don't open replies to peers with "Thanks [Name], that's helpful"** or similar personalized acknowledgments. It performs deferential relationship-management that isn't load-bearing — the substantive follow-up already signals collaboration. Default to a neutral acknowledgment ("Okay, that's helpful." / "Got it." / "Makes sense.") instead. Reserve "Thanks [Name]" for when the gratitude is the actual point (the person did real work, went out of their way).

  This matters most when Adam is the lower-titled person in the exchange (IC → PE, L5 → L7): the deferential opener reinforces the title gap rather than flattening it, and undercuts a position he's defending.

- **Watch the related deferential tics:** "Asking because…", "Just wanted to understand…", "To make sure I understand…". Same shape. Default to declarative forms ("I ask because…", or just state the reason) unless genuine uncertainty or gratitude is the point.

## Git workflow

- **Branch off `origin/main`** (the remote tip), not local `main`, so the branch starts from current content. Set upstream tracking explicitly to the new branch on first push (an explicit refspec) rather than letting it default to `main`.
- **`git config` values go `--global`**, not repo-local — Adam wants one consistent identity across all repos.
- **Don't use `git -C <path>`** when the shell is already in the target repo; it obscures the working directory.
- **Don't run any git command mid-rebase** (even read-only ones) while Adam is interactively rebasing — wait for explicit confirmation that the rebase is done.
- **Interactive rebases are Adam's to run.** Create fixup commits, but let him run the `rebase -i` himself rather than automating it.
- **Before force-pushing, `git fetch` and check the remote tip** — the remote may have moved.
- **Replant branches with `git rebase --onto`**, not reset + cherry-pick.
- **After resolving merge/cherry-pick conflicts, `git reset HEAD <file>`** (not `git add`) so the resolution can be reviewed with `git add -p`.
- **Cherry-pick** with `--continue --no-edit` to preserve authorship, then `git commit --amend` if the message needs revising.

## Commit messages

- **Explain *why*, not *what*** — the diff already shows what changed. Cite the spec / ADR / ticket that motivated it. Follow cbea.ms/git-commit conventions: imperative-mood subject, capitalized, no trailing period, ~50 chars; wrap the body.
- **No PR numbers in commit messages** — refer to the substance (the concept), not the PR.
- **Omit narration** — no slice numbers, refactor play-by-play, or process checklists in the body. State only what the diff can't convey.
- Each commit should be one logical change and independently green.

## Ruby / RSpec / Sorbet

(Apply when working in Ruby. Adam's RSpec style is specific and consistently held.)

**RSpec**
- **Implied `subject` only** — never named (`subject(:foo)`). One subject per `describe`; never redefine `subject` in a nested `context`.
- The SUT is fixed by the outermost `describe`; don't nest `describe` to shift focus onto an artifact — use a custom matcher instead.
- **Operator matchers** (`==`, `<`, `>`, `=~`) over named equivalents (`eq`, `be <`, `match`).
- **CQS subject shape:** lambda subjects for commands (assert effects), value subjects for queries (assert state).
- **Every example lives in a named `context`** that establishes its own preconditions — no bare `it`s relying on implicit defaults. A top-level `before` must match the nested context's premise, not contradict it.
- **Specs exercise the public interface only.** Don't expose internal state for testability — either the behavior is invisible (skip the test) or the interface is wrong (fix it).

**Ruby idioms**
- `class << self` over repeated `def self.` for multiple class methods.
- Duck typing over `is_a?` / `kind_of?` type checks — let interfaces define what callers can pass.
- Endless method syntax (`def foo = expr`) for single-expression bodies.
- Never block-form `unless` — use modifier form, an early return, or restructure.
- Public methods read as intent by delegating to named private methods ("sergeant methods"); extract for readability, not just DRY. Suffix `!` for methods that raise.

**Sorbet** (Adam's pragmatic stance — note this diverges from the broader Gusto default)
- Sorbet earns its keep on public value-class boundaries and catching real bugs; don't spread sigs everywhere by default.
- Value-object `==`: type the arg as `Object` (not `BasicObject`, so `is_a?` is callable), `!!`-coerce to Boolean, compare via canonical form rather than protected ivars.
- Sorbet rejects splats (`Method.call(*array)`) — destructure first (`a, b = array; Method.call(a, b)`).

**TDD discipline**
- TDD is a discipline, not fundamentalism — documented constants, type-system requirements, sigs, and renames are acceptable exceptions.
- During TDD, write the failing test directly without asking permission first (Adam reviews the file); production-code changes still warrant pre-alignment.
- After GREEN, do the REFACTOR pass — explicitly scan for duplication, awkward shapes, naming — before moving on.

## Claude Code harness

- **A repo's `.claude/skills/` is plugin-managed and clobbered** — the marketplace plugin deletes skills not in its manifest. Put personal skills in `~/.claude/skills/`, never in a repo's `.claude/skills/`.
- **`.claude/settings.json` changes don't take effect mid-session** — a restart is required. Don't claim a settings/permission fix applies immediately.
- **Don't write source files via Bash heredoc** — use the Edit/Write tools so file state and diffs are tracked by the harness.
