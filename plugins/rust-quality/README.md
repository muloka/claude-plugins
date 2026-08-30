# rust-quality

Rust code-quality specialist for [peer-review-jj](../peer-review-jj/). Ships
a generic `rust` specialist that peer-review-jj's `/peer-review --deep rust`
dispatches to the files and line ranges the generalist flagged.

## What it catches

- Needless `.clone()` where a borrow, `Cow`, or restructured ownership suffices
- `unwrap()`/`expect()` and panicking indexing in library code
- Premature `.collect()` — collecting into a `Vec` only to iterate again
- Stringly-typed keys crossing boundaries where a newtype exists (including
  `as_str()` leaks past newtype barriers)

## Override model

Specialist discovery is first-match-wins: a project-local
`.claude/peer-review/specialists/rust.md` (or a user-global one under
`~/.claude/peer-review/specialists/`) **replaces** this plugin's specialist
entirely. Use that to encode project-specific rules (crate boundaries,
domain newtypes, dependency-specific traps) — start by copying this
plugin's `specialists/rust.md` and extending it.

## Requirements

- peer-review-jj ≥ 0.7.0 (the release whose specialist discovery includes
  installed plugins' `specialists/` directories)
