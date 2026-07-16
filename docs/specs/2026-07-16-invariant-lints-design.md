# Invariant Lints: #82 and #86

**Date:** 2026-07-16
**Status:** Approved, pending implementation
**Depends on:** #89 (the CI test runner — these lints are only useful because something now runs them)
**Closes:** #82, #86

## Summary

Two static lints, each enforcing a rule the repo states but nothing checks:

- **#82** — every glob a validation workflow relies on must match ≥1 file. A glob that silently
  stops matching (like `**/skills/*/SKILL.md` did before #81, matching zero for months) fails
  loudly instead.
- **#86** — the `project-setup-jj` CLAUDE.md template's `hash:` marker must equal the hash of its
  own body. A stale marker silently skips every downstream update (as it did in this repo for four
  months, #87).

Both are picked up and run by #89's test runner. #84 (version-bump-on-diff) is deliberately not
here — it needs the PR diff, not a static check, and is a genuinely different mechanism.

## Why these are lints, not one gate

The three issues share a theme — *a stated rule nothing enforces* — but not a mechanism. #82 and
#86 are pure static checks: they read the repo as it is and assert an invariant. #84 needs to
compare a PR against its base. This spec covers only the two static ones. Calling all three "one
gate" was the framing #89's spec already corrected.

## #86: template hash lint

**File:** `plugins/project-setup-jj/tests/test-template-hash.sh` (the runner's `plugins/*/tests/`
glob finds it with no change).

**Checks:** the `hash:<hex>` in the template's start marker equals the recomputed hash of the body
between the markers.

```
declared   = hash from `<!-- jj-project-setup:start hash:XXXX -->`
recomputed = md5( body between the markers, exclusive )  |> first 8 hex
assert declared == recomputed
```

The recipe is the one documented in `commands/project-setup.md` and used by #85/#87 — this lint
makes that recipe executable rather than advisory.

**Portability:** `md5` on macOS, `md5sum` on Linux. A helper tries `md5` then falls back to
`md5sum`, so the lint runs on either (the runner is macOS-only today, but a developer runs it
locally too).

**Must fail loudly, never silently pass** — the #82 disease applied to itself:
- marker line absent → fail (`no start marker found`)
- `hash:` missing or unparseable → fail (`marker has no parseable hash`)
- both markers must be present for the body extraction to be meaningful → fail if end marker absent

**Verified now:** declared `fe023f83` == recomputed `fe023f83`. The lint passes today; its value is
the next time someone edits the template body and forgets the hash.

## #82: workflow-glob lint

**File:** `.github/tests/test-workflow-globs.sh`.

It checks a **repo-level** concern (the CI config), so it does not belong under any plugin. It
**cannot** live inside `validate-frontmatter.yml`: that workflow only triggers on the very globs it
would check, so a glob matching nothing means the workflow does not run means the check does not
run — #82's exact circularity. It must run unconditionally, which #89's runner does (no `paths:`
filter).

**Checks:** every glob under `paths:` in `validate-frontmatter.yml` matches ≥1 file in the repo.

**Globs are extracted from the workflow, never hardcoded.** Hardcoding the list is the #82 failure
in the lint itself — add a fourth `paths:` entry, forget the lint's copy, and the new glob goes
unchecked. The lint parses the workflow's `paths:` block.

```
globs = paths: entries parsed from validate-frontmatter.yml
for each glob:
    assert (bash globstar expansion of glob) is non-empty
```

**Evaluation:** `shopt -s globstar nullglob`, then `matches=( $glob )`. Verified under bash
(the lint's `#!/usr/bin/env bash` shebang matters — the interactive shell here is zsh, where
`shopt` does not exist; the lint must be tested with `bash`, not sourced).

**Must fail loudly, never silently pass:**
- zero globs extracted → fail (`no paths: globs found — the parser or the workflow changed`). This
  is the lint's own anti-#82 guard: a glob-checker that checks no globs is the bug.
- any glob matching zero files → fail, naming the glob.

**Verified now:** the three globs extract cleanly and match 1 / 3 / 24 files. Note
`**/skills/*/SKILL.md` matches **3** today and matched **0** before #81 — this lint would have
caught #77 at its source.

## Runner change

`#89`'s discovery glob currently finds only `plugins/*/tests/`. Extend it to also find
`.github/tests/`:

```diff
- suites=$(find plugins -path '*/tests/test-*.sh' | sort)
+ suites=$(find plugins .github -path '*/tests/test-*.sh' | sort)
```

`find plugins .github -path '*/tests/test-*.sh'` matches both roots — verified. This keeps
glob-discovery (no hardcoded list) and lets any future repo-level lint be found for free. The
count rule stays `> 0`; no count is hardcoded.

After this change the runner finds 9 suites (7 existing + the 2 new lints).

## Verification

Each lint is TDD: **written to fail first**, exactly as `test-skill-paths.sh` was (#85), because a
lint that passes on its first run has proved nothing.

- **#86 lint:** temporarily corrupt the template's `hash:` marker → lint fails naming the mismatch;
  restore → passes.
- **#82 lint:** temporarily point it at a workflow with a glob that matches nothing (or add a junk
  glob) → fails naming the glob; restore → passes.
- **Runner extension:** the CI run on the PR reports `found 9 suite(s)` and lists both new lints by
  path in the log. Read the log, not the tick.
- **Whole-suite:** all 9 pass locally under `bash -e`, and the PR's `test` job is green with 9 in
  the log.

## What this does not do

- **Does not touch #84.** Different mechanism (needs the diff).
- **Does not fix `validate-frontmatter.yml`'s own `paths:` gate.** #82's lint *detects* a dead glob;
  it does not change how the frontmatter workflow triggers. If a glob is found dead, the fix is a
  human decision (correct the glob vs. correct the layout), which is the #77 pattern.
- **Does not enforce the hash on write.** The lint catches a stale hash in CI; it does not
  auto-recompute. Auto-recompute would hide the very edit the maintainer should be conscious of.

## Related

- #82, #86 — closed by this
- #84 — the remaining member of the family; needs a diff-aware check
- #89 — the runner that executes these
- #85 — `test-skill-paths.sh`, the house model for a fail-loudly-on-nothing lint
- #77 — the dead-glob incident #82's lint would have caught
- #87 — the stale-hash incident #86's lint would have caught
