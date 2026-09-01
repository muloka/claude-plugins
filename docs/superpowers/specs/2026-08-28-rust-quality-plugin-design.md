# rust-quality Plugin — Design

**Date:** 2026-08-28
**Status:** Approved design, Phase 1 scoped for implementation

## Goal

Give Rust projects a specialist reviewer that catches the recurring failure
modes generic reviewers miss, delivered through peer-review-jj's existing
specialist dispatch rather than new review machinery. First consumer is
tokotoko; jjp and any future Rust project get it for free.

This is the first non-jj plugin in the marketplace. The marketplace is
muloka's plugins, not a jj-themed collection — the jj focus was incidental,
and the marketplace description changes to reflect that.

## Background

- A March 2026 review of tokotoko produced a concrete inventory of Rust
  failure modes ("the March list"): needless `.clone()`, `unwrap()` in
  library code, premature `.collect()` into a `Vec` followed by immediate
  re-iteration, stringly-typed keys where newtypes enforce invariants, and
  petgraph `NodeIndex` invalidation traps.
- The list splits cleanly into **generic Rust** items (first four) and
  **tokotoko-specific** items (petgraph patterns, `TokenPath` newtype
  boundaries, no-unwrap-in-toko-core). The generic layer belongs in a
  plugin; the specifics belong in tokotoko's own project specialist.
- peer-review-jj already defines specialist discovery
  (receiving-change-review SKILL.md, step 9): project
  `.claude/peer-review/specialists/` → user-global
  `~/.claude/peer-review/specialists/` → plugin built-in
  (`peer-review-jj/agents/`). First match for a concern type wins — no
  merge, no inheritance. A sibling plugin's specialists are currently
  invisible to that walk; extending it is the only peer-review-jj change
  this design needs.

## Phase 1 deliverables (this spec's scope)

### 1. New plugin: `plugins/rust-quality/`

```
plugins/rust-quality/
  .claude-plugin/plugin.json     # name, description, version 0.1.0; no hooks
  README.md
  specialists/
    rust.md                      # generic Rust specialist prompt
  tests/
    test-rust-quality.sh         # CI auto-discovered
```

`specialists/rust.md` follows the specialist template peer-review-jj
seeds for emergent specialists (frontmatter `name`, `description`,
`model: sonnet`; sections Role / Patterns / Relevant Guidelines / Review
Focus / Proposed Refinements). Its concern type is the file basename:
`rust`. Content covers the generic March-list items only:

- Needless `.clone()` — especially on hot paths and where a borrow or
  `Cow` suffices.
- `unwrap()`/`expect()` in library code — panics belong at binary
  boundaries, libraries return `Result`.
- Premature `.collect()` — collecting into `Vec` only to iterate again;
  prefer chaining.
- Stringly-typed keys — raw `String`/`&str` crossing a boundary where the
  codebase has (or obviously wants) a newtype; includes `as_str()` leaks
  past newtype barriers.

Tokotoko-specific patterns are explicitly **out**: they live in tokotoko's
`.claude/peer-review/specialists/rust.md`, which shadows this file by
first-match-wins. That project file is created in the tokotoko repo, not
here (noted as follow-up, out of this repo's scope).

### 2. peer-review-jj discovery-order extension

Step 9's discovery order gains one tier, between user-global and
peer-review-jj's built-ins:

1. project `.claude/peer-review/specialists/`
2. user-global `~/.claude/peer-review/specialists/`
3. **installed plugins' `specialists/` directories** — resolved via the
   version-sorted cache glob (same pattern the SDD shim resolver uses):
   `ls ~/.claude/plugins/cache/*/<plugin>/*/specialists/<concern>.md`,
   latest version wins; a local checkout of this repo has them at
   `plugins/<plugin>/specialists/` instead
4. plugin built-in `peer-review-jj/agents/`

First-match-wins semantics unchanged. No generalist changes: dispatch
still happens via `/peer-review --deep rust` or via the generalist's own
`specialist_recommendations`.

This is a contract change to peer-review-jj → version bump (0.6.3 → 0.7.0)
per the version-bump-on-diff invariant.

### 3. Marketplace changes

- Add `rust-quality` entry to `.claude-plugin/marketplace.json`.
- Reword the marketplace `description` to drop the jj-only framing, e.g.
  "muloka's Claude Code plugins — jj (Jujutsu) workflows, code review,
  and Rust code quality".

### 4. Tests

CI (macOS, bash 3.2 — no globstar, no associative arrays) auto-discovers
`plugins/rust-quality/tests/test-*.sh`. Assertions:

- `specialists/rust.md` exists, frontmatter parses, `name: rust` matches
  the basename (concern-type contract).
- `plugin.json` is valid JSON with required fields.
- `marketplace.json` contains the `rust-quality` entry.
- peer-review-jj's receiving-change-review SKILL.md mentions the plugin
  `specialists/` tier (doc-consistency guard, same style as existing
  invariant lints).

## Phase 2 — writing-time skills (roadmap, not in scope)

Same plugin grows `skills/` with module-splitting and refactor-guidance
skills generalized from tokotoko's `docs/references/` playbooks
(re-export patterns, async boundaries, split thresholds). Deferred until
Phase 1 has been exercised, because the source material is
tokotoko-flavored and generalizing it is real editorial work.

## Phase 3 — inventory-time debt surface (deliberately not built)

peer-review-jj's review-history + specialist-emergence mechanism already
accumulates repeated findings. Per the organic-over-speculative rule, no
debt-query tool is built until Phase 1's findings history demonstrates
what such a tool would need to answer.

## Error handling & edge cases

- **No plugin cache present** (local checkout, plugin not installed): the
  discovery prose covers the `plugins/<plugin>/specialists/` fallback;
  if neither exists the tier is simply empty and the walk continues.
- **Concern-type collision**: a project or user-global `rust.md` shadows
  the plugin's — by design; that is the override model.
- **Stale cache**: cache is keyed by version — a content change without a
  version bump never ships. The version-bump lint already enforces this
  repo-wide.

## Out of scope

- tokotoko's project-local specialist file (lives in the tokotoko repo).
- Any change to the generalist reviewer or the findings schema.
- Rust toolchain integration (clippy config, cargo lints) — the
  specialist is prompt-only.
