---
name: ruby-style
description: Adam's Ruby, RSpec, and Sorbet conventions, plus Rails environment and RuboCop rules. Use whenever writing, editing, reviewing, or discussing Ruby code, `.rb` or `_spec.rb` files, RSpec specs, RuboCop config, Sorbet sigs, or Rails environment config.
---

# Ruby / RSpec / Sorbet

Adam's RSpec style is specific and consistently held.

## RSpec

- **Implied `subject` only** — never named (`subject(:foo)`). One subject per `describe`; never redefine `subject` in a nested `context`.
- The SUT is fixed by the outermost `describe`; don't nest `describe` to shift focus onto an artifact — use a custom matcher instead.
- **Mirror the structure of the code under test:** the spec file path mirrors the lib path (`lib/foo/bar.rb` → `spec/foo/bar_spec.rb`); top-level `describe` for the class, one nested `describe` per method, `context` for precondition variation only. `describe` names the SUT/method and nothing else; `context` names the situation ("when…", "with…", "without…").
- **Low bar for custom matchers.** When asserting on a complex return value would mean reaching into its internals in the example (`subject.collect { … }`, `subject.first[:x]`), write a chainable custom matcher instead (`build_relationship(:member).from_subject("u-1")`). The matcher absorbs the plumbing; the example states intent. This is what lets the implied-subject rule and the one-assertion rule both hold at once.
- **Operator matchers** (`==`, `<`, `>`, `=~`) over named equivalents (`eq`, `be <`, `match`). Prefer one-liner `should`/`its(...)` over multi-line `it` blocks.
- **CQS subject shape:** lambda subjects for commands (assert effects), value subjects for queries (assert state). This shape is a design probe: a command that must *return* load-bearing state, or a query that mutates, is a CQS violation the spec form exposes before the code is written — surface it rather than working around it.
- **One assertion per example.** Each `expect` gets its own example, set up by its `context`. No `it` with two `expect`s.
- **Every example lives in a named `context`** that establishes its own preconditions — no bare `it`s relying on implicit defaults. A top-level `before` must match the nested context's premise, not contradict it.
- **Specs exercise the public interface only.** Don't expose internal state for testability — either the behavior is invisible (skip the test) or the interface is wrong (fix it).
- **Never use factories.** They wreck suite performance (each `create` persists a graph of mostly-irrelevant objects) and let a poorly-modeled domain hide behind cheap implicit construction. Build minimal plain-Ruby objects per example. If a test needs more than 2–3 objects, the SUT likely has too many dependencies.

## Ruby idioms

- `class << self` over repeated `def self.` for class methods — it groups them and, crucially, makes `private` actually apply (a `private` keyword does nothing to `def self.` singleton methods; they stay public). A stateless operation-set is a legitimate module with `class << self` (like `JSON`/`Base64`); reach for an instantiable class only when there's instance state to encapsulate.
- Duck typing over `is_a?` / `kind_of?` type checks — let interfaces define what callers can pass.
- Endless method syntax (`def foo = expr`) for single-expression bodies.
- Never block-form `unless` — use modifier form, an early return, or restructure.
- Public methods read as intent by delegating to named private methods ("sergeant methods"); extract for readability, not just DRY. Suffix `!` for methods that raise.
- **Prefer decomposing a condition into a named predicate method over an early return.** When a method guards on a condition, extracting the condition into its own `?`-named method (`return value if uuid?(value)`) is preferred over inlining the check, even when the inline version is shorter. The named predicate reads as intent and gives any error-handling the check needs (e.g. a `rescue`) a tightly-scoped home. This is the same instinct as sergeant methods, applied to conditionals specifically: extract for readability, not just DRY.
- **Three Rails environments only**: development, test, production. Every deployed environment (staging, demo, QA) runs as `production` and differs by config, not by a distinct `Rails.env` — 12-factor. Use `Rails.env.local?` for "local box" (dev or test), not `!Rails.env.production?` or a `%w[development test]` allowlist. There is no `staging?`; staging *is* production. A deployed environment that needs local-only behavior gets an explicit opt-in flag, never a `Rails.env` branch.
- **Resolve a RuboCop `:disable` rather than carry it.** A disable is a signal you're working around a cop instead of fixing the code; nearly always there's a clean fix that satisfies the cop on its merits (extract a sergeant method for a metrics cop, rename a boolean method to a `?` predicate for a naming cop, a constant/set membership for an unsafe `NumericPredicate`). Disable a cop in config (not inline) only when it genuinely conflicts with a stronger held convention — and prefer to first restructure so nothing trips it (e.g. custom matchers eliminate `RSpec/NamedSubject`).

## Sorbet

Adam's pragmatic stance, which may diverge from a team's default.

- Sorbet earns its keep on public value-class boundaries and catching real bugs; don't spread sigs everywhere by default.
- Value-object `==`: type the arg as `Object` (not `BasicObject`, so `is_a?` is callable), `!!`-coerce to Boolean, compare via canonical form rather than protected ivars.
- Sorbet rejects splats (`Method.call(*array)`) — destructure first (`a, b = array; Method.call(a, b)`).
