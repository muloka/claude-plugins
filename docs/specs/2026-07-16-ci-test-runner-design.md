# CI Test Runner: Making the Suites Actually Run

**Date:** 2026-07-16
**Status:** Approved, pending implementation
**Precondition for:** #82, #84, #86

## Summary

**CI runs zero tests.** Seven shell suites — **185 counted assertions** — have never executed in
CI. They pass only because a human runs them by hand. Any PR could break every one of them and CI
would be green.

This spec covers the precondition: a workflow that runs the existing suites. It closes no issue on
its own. It is what makes #82/#84/#86's lint-based fixes possible, because a lint added today
would never execute.

## The gap

`.github/workflows/` contains exactly two workflows:

| Workflow | What it does |
|---|---|
| `close-external-prs.yml` | membership check — not a test |
| `validate-frontmatter.yml` | frontmatter of changed agent/skill/command `.md` only |

Nothing runs (counts measured 2026-07-16; all seven pass locally):

| Suite | Assertions |
|---|---|
| `permission-gateway/tests/test-permission-gate.sh` | 133 |
| `workspace-jj/tests/test-kaisen-scripts.sh` | 22 |
| `agent-helpers-jj/tests/test-agent-helpers-install.sh` | 15 |
| `agent-helpers-jj/tests/test-jj-agent-helpers.sh` | 8 |
| `workspace-jj/tests/test-model-selection-lint.sh` | 4 |
| `workspace-jj/tests/test-skill-paths.sh` | 3 |
| `project-setup-jj/tests/test-statusline-jj.sh` | 8 |
| **Total** | **193** |

`test-statusline-jj.sh` uses a different output format from the other six — it prints
`Results: 8/8 passed` followed by `ALL PASSED`, where the others print `N passed, M failed`. The
runner does not parse these numbers (it keys on exit status), so the inconsistency is harmless
here; it would matter to any future "assertion count" metric.

**This count has been wrong twice, both times by looking at too little output.** The first draft
said 162, having summed four of the seven suites. The correction said 185, having read each suite's
output with `tail -1` — which showed `ALL PASSED` and hid the `Results: 8/8 passed` line directly
above it. The number is 193. A spec whose thesis is *quiet miscounting* miscounted quietly, twice,
and the second time was the same truncation error that let an over-broad `jj abandon` swallow an
unrelated four-month-old change earlier the same day (its `and 8 more` was on a line `tail -1` did
not show). **Read the whole output, not its last line.**

**The recursion:** `test-skill-paths.sh` was added on 2026-07-15 (#85) specifically to catch rules
that nothing executes — and nothing executes it. A guard against unexecuted prose, left unexecuted.

## Why this is not one gate with #82/#84/#86

The working assumption when this was scoped was *"one CI job closes three issues."* Exploration
killed it. The three share a **theme** — a stated rule nothing enforces — but not a **mechanism**:

| Issue | Needs | Shape |
|---|---|---|
| #86 — hash ≠ body | nothing; pure static | a lint |
| #82 — glob matches zero files | nothing; pure static | a lint (assert each glob matches ≥1 file) |
| #84 — version not bumped | the PR diff vs base | a CI step |

Two static lints and one diff-aware check — **and both lints are inert until something runs
lints.** Hence: runner first, as its own PR.

## Design

One workflow, `.github/workflows/test.yml`, one job.

### Discovery: glob, never a list

Suites are found with `find plugins -path '*/tests/test-*.sh'`, not enumerated.

A hardcoded list goes stale silently: someone adds `test-foo.sh`, forgets the list, CI stays green
while checking nothing. **That is #82 verbatim** — it would reintroduce the bug inside the
precondition for fixing it.

### Zero suites found ⇒ fail

A glob has #82's *other* failure mode: matching nothing and passing by doing nothing. So the run
fails loudly if the glob returns zero. The repo has seven suites; zero means the glob rotted, not
that the repo is clean.

This is the same rule `test-skill-paths.sh` applies to itself, applied one level up.

### No `paths:` filter

`validate-frontmatter.yml` is `paths:`-gated, and #82 exists precisely because a workflow that
never triggers is indistinguishable from one that passes. This runs on every PR, unconditionally.

Fixing `validate-frontmatter.yml`'s own `paths:` gate is #82's business, not this spec's.

### Run all, don't fail-fast

Every suite runs; failures are collected and reported together. Fail-fast would surface one broken
suite per push.

### Platform: `macos-latest`

The suites have only ever run on macOS. `plugins/project-setup-jj/scripts/statusline-jj.sh` uses
macOS-only `stat -f` (lines 75, 134) and `date -j` (line 183) — GNU `stat -f` means
`--file-system`, something else entirely. Each call has a `|| echo "0"` fallback, so on Linux it
would degrade rather than crash, and whether `test-statusline-jj.sh` still passes there is
unknown.

Running on macOS gets all 185 assertions enforced today, on the platform where they are known to
work.
Linux portability is deferred to a separate issue — it is real (#79 calls it out: "everything has
only ever run in *this* repo"), but it is not this PR's job and would block it.

## Landmines

Three, found during exploration. All are properties of CI that the local environment hides.

### 1. No `.jj/` in a CI checkout

`.jj/` is gitignored (`.gitignore:3`), and `actions/checkout` produces a plain **git** checkout.
There is no jj repo in CI.

**Not a problem:** no suite calls `jj root`. The jj-dependent suites (`test-jj-agent-helpers.sh`,
`test-statusline-jj.sh`, `test-kaisen-scripts.sh`) each run `jj git init` in their own `mktemp`
directory. They never assume the checkout is a jj repo.

### 2. No jj identity in CI

**No suite sets one.** They silently rely on the developer's `~/.config/jj/config.toml` for
`user.name` / `user.email`. CI has no such file, and jj needs an author for the working-copy
commit.

**This is measured, not predicted.** Running `test-statusline-jj.sh` against a `mktemp` `$HOME`
(2026-07-16):

| Environment | Result |
|---|---|
| clean `$HOME`, no identity | `Results: 6/8 passed` — **FAILED** |
| clean `$HOME` + `JJ_USER`/`JJ_EMAIL` | `Results: 8/8 passed` — ALL PASSED |

So the job-level env block is **load-bearing**, not defensive: without it the first CI run is red,
and the cause — a config file the suites never mention — is not visible from the failure.

This dependency is worth naming for its own sake: the suites are not as self-contained as they
look, and every one of them passes locally *because of a file outside the repo*.

### 3. `jj` is not installed

`brew install jj`. `jq`, `bash`, and `python3` are preinstalled on GitHub's macOS images.

## The workflow

```yaml
name: Tests

on:
  pull_request:
  push:
    branches: [main]

jobs:
  test:
    runs-on: macos-latest
    # macOS runners bill at a 10x multiplier and the job default is 6 hours.
    # A hung suite should cost minutes, not a day's budget.
    timeout-minutes: 15
    env:
      # Load-bearing, not defensive: the suites rely on the developer's
      # ~/.config/jj/config.toml for an identity and never mention it. Without
      # this, test-statusline-jj.sh fails 6/8 (measured against a clean $HOME).
      JJ_USER: CI
      JJ_EMAIL: ci@example.invalid
    steps:
      - uses: actions/checkout@v4

      - name: Install jj
        run: brew install jj

      - name: Run all suites
        run: |
          # Glob, never a hardcoded list: a list goes stale silently when a
          # suite is added, and CI stays green while checking less. That is the
          # #82 failure inside the fix for #82.
          suites=$(find plugins -path '*/tests/test-*.sh' | sort)
          count=$(printf '%s' "$suites" | grep -c . || true)

          # A glob that matches nothing passes by doing nothing — #82's other
          # half. This repo has seven suites; zero means the glob rotted.
          if [ "$count" -eq 0 ]; then
            echo "::error::no test suites found — the glob is broken, not the repo clean"
            exit 1
          fi
          echo "found $count suite(s)"

          # `while read`, not `for t in $suites`: the latter word-splits on IFS
          # and glob-expands. Harmless for today's paths, but the failure mode
          # of an unquoted expansion is silent and wrong, not loud.
          failed=0
          while IFS= read -r t; do
            [ -n "$t" ] || continue
            echo "::group::$t"
            if bash "$t"; then
              echo "PASS $t"
            else
              echo "::error::FAIL $t"
              failed=$((failed + 1))
            fi
            echo "::endgroup::"
          done <<< "$suites"

          echo "---"
          echo "$((count - failed))/$count suites passed"
          [ "$failed" -eq 0 ]
```

Two shell details are deliberate and should survive review. `failed=$((failed + 1))` rather than
`((failed++))` — the latter returns 1 when incrementing from 0 and would trip Actions' `bash -e`.
And `if bash "$t"` is errexit-exempt, so a failing suite is caught rather than aborting the step.

## Verification

**The count is an observation, never an assertion.**

> The workflow MUST NOT hardcode the number of suites. No `[ "$count" -ne 7 ]`, no expected-count
> check, nothing that must be edited when a suite is added. `7` is what the glob finds on
> 2026-07-16 — it is a fact about today's repo, not a requirement. **A hardcoded count is a
> hardcoded list wearing a disguise**, and it fails the same way: someone adds a suite, CI goes red
> for a correct change, and the fix is to edit a number nobody remembers exists. The only count
> rule in the workflow is `count > 0`.

If a future run reports a number other than 7, that means a suite was added or removed. That is
information, not a failure. Verify against **the list of suites in the log**, not against 7.

**Mechanical:**

1. The workflow triggers on the PR that adds it — it has no `paths:` filter, so it must.
2. The run reports `found N suite(s)` where N equals `find plugins -path '*/tests/test-*.sh' | wc -l`
   in the merge commit. On 2026-07-16 that is 7.
3. **Every** suite present on disk appears as its own `::group::` section in the log — verify by
   **reading the log and comparing it to the filesystem**, not by the green tick and not by the
   number. A green run that silently found fewer suites is the failure being fixed.
4. `N/N suites passed`.

**The gate that proves it:** a runner that has never been observed failing has not been shown to
work. `test-skill-paths.sh` applies the same discipline — its first run had to fail before it was
trusted.

If any suite fails on the first run, that is the proof: a red CI naming the suite. If all suites
pass immediately, force the negative case explicitly, using this exact procedure:

```bash
# 1. Force the cheapest suite to fail (3 assertions, no deps, ~instant).
jj new -m "TEMP: prove CI goes red — do not merge"
printf '\nexit 1  # TEMP: prove CI goes red\n' \
  >> plugins/workspace-jj/tests/test-skill-paths.sh

# 2. Push to the SAME PR and read the run.
jj git push --change @
```

`exit 1`, not a fabricated assertion call. The suite's helper is `bad()`, not `fail()`, and its
last line is already `test "$FAIL" -eq 0` — so an appended `fail "..."` would exit 127
(`command not found`) and turn the suite red *by accident*, with a log that blames a missing
command rather than a failed check. Verified 2026-07-16: appending `exit 1` exits 1; appending
`fail "..."` exits 127. Both are red; only one is honest.

Expected: the `test` job goes **red**, the log names `plugins/workspace-jj/tests/test-skill-paths.sh`
under `::error::FAIL`, `N-1/N suites passed`, and — critically — the **other suites still appear in
the log**, proving non-fail-fast.

```bash
# 3. Remove the proof commit entirely; it must not reach main.
jj abandon @
jj git push --change @-
```

Confirm with `jj log -r 'main::@'` that the TEMP change is gone before merging.

`test-skill-paths.sh` is the designated target: it is the fastest suite, has no external
dependencies, and — fittingly — is the one this workflow exists to finally execute.

**Not verified by this PR:** that the suites pass on Linux. Deferred, see below.

## Follow-ups

- **File: statusline / Linux portability.** `statusline-jj.sh` is macOS-only (`stat -f`, `date -j`)
  and degrades silently rather than failing. Any Linux user's statusline is affected today, with
  no symptom. Related to #79's portability section.
- **#82, #84, #86** become implementable once this lands, as: two static lints picked up by the
  glob for free, plus one diff-aware CI step.

## Related

- #82 — a validation glob matching zero files passes silently
- #84 — a merge without a version bump never ships
- #86 — a stale template hash silently skips the update
- #79 — ~20 user-facing commands never executed; portability unmeasured
- #85 — added `test-skill-paths.sh`, which this workflow finally executes
