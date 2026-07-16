# CI Test Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Do NOT use workspace-jj:kaisen for this plan.** It has one task and one file. There is nothing
> to parallelise, and kaisen's own Parallelism Threshold rule directs you to sequential execution
> below 40%. Inline execution is correct.

**Goal:** Make CI run the seven shell test suites that have never executed in it.

**Architecture:** One workflow, one job, one step that globs for suites and runs each. No new test
code — the 193 assertions already exist and already pass locally. The only new thing is that
something finally executes them.

**Tech Stack:** GitHub Actions, bash, jj (Jujutsu), Homebrew.

## Global Constraints

- **jj, never git.** This repo uses Jujutsu. Use `jj` for all VCS operations. The only exceptions
  are `jj git` subcommands and the `gh` CLI. Raw `git` is blocked by a PreToolUse hook.
- **The workflow MUST NOT hardcode the suite count.** No `[ "$count" -ne 7 ]`, no expected-count
  check. `7` is what the glob finds today, not a requirement. A hardcoded count is a hardcoded list
  wearing a disguise and fails the same way. The only count rule is `count > 0`.
- **No `paths:` filter.** A `paths:`-gated workflow that never triggers is indistinguishable from
  one that passes — that is #82, and this workflow exists partly to not repeat it.
- **Glob discovery, never a hardcoded list of suites.**
- **Preserve the deliberate shell details.** `failed=$((failed + 1))` not `((failed++))` (the
  latter returns 1 when incrementing from 0 and trips Actions' `bash -e`); `if bash "$t"` is
  errexit-exempt so a failing suite is caught rather than aborting the step; `while IFS= read -r`
  not `for t in $suites`. These look like nits and are not.
- **Verify by reading the log, not the green tick.** A green run that found fewer suites than exist
  is the exact failure being fixed.
- Spec: `docs/specs/2026-07-16-ci-test-runner-design.md`

---

### Task 1: Add the test runner workflow

The only task. It creates one file, verifies the shell logic locally before pushing, and commits.

**Files:**
- Create: `.github/workflows/test.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: a `test` job on every PR. No later task depends on it; the PR verification section
  below is how it is proven.

- [ ] **Step 1: Confirm the gap is real before fixing it**

```bash
cd /Users/muloka/projects/sonder-hale/tools/claude-plugins
ls .github/workflows/
grep -rn "tests/" .github/workflows/ || echo "NO WORKFLOW RUNS THE SUITES"
```

Expected: `close-external-prs.yml` and `validate-frontmatter.yml` only, then
`NO WORKFLOW RUNS THE SUITES`. If a workflow already runs them, stop — this plan's premise is
gone.

- [ ] **Step 2: Confirm all seven suites pass locally**

```bash
for t in plugins/*/tests/test-*.sh; do
  printf "%-42s %s\n" "$(basename $t)" "$(bash "$t" 2>&1 | tail -1)"
done
```

Expected: seven lines, every one reporting `0 failed` or `ALL PASSED`. This is the baseline — if a
suite is already red locally, fix that first or the first CI run's red tells you nothing new.

- [ ] **Step 3: Create the workflow**

Create `.github/workflows/test.yml` with exactly this content:

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

- [ ] **Step 4: Verify the YAML parses**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/test.yml')); print('valid YAML')" 2>/dev/null \
  || ruby -ryaml -e "YAML.load_file('.github/workflows/test.yml'); puts 'valid YAML'"
```

Expected: `valid YAML`. If neither interpreter has a YAML module available, skip — Step 7's real CI
run is the authoritative parse, and a malformed workflow simply never triggers.

- [ ] **Step 5: Run the step's shell logic locally, under Actions' shell**

GitHub Actions runs `run:` blocks as `bash -e {0}`. Reproduce that exactly:

```bash
bash -e -c '
suites=$(find plugins -path "*/tests/test-*.sh" | sort)
count=$(printf "%s" "$suites" | grep -c . || true)
if [ "$count" -eq 0 ]; then echo "::error::no test suites found"; exit 1; fi
echo "found $count suite(s)"
failed=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  if bash "$t" >/dev/null 2>&1; then echo "  PASS $(basename $t)"; else echo "  FAIL $(basename $t)"; failed=$((failed + 1)); fi
done <<< "$suites"
echo "$((count - failed))/$count suites passed"
[ "$failed" -eq 0 ]
'
echo "exit: $?"
```

Expected: `found 7 suite(s)`, seven `PASS` lines, `7/7 suites passed`, `exit: 0`.

- [ ] **Step 6: Verify the zero-suites guard fails loudly**

The guard is the whole anti-#82 point. A guard that has never been seen firing has not been shown
to work.

```bash
bash -e -c '
suites=$(find /nonexistent -path "*/tests/test-*.sh" 2>/dev/null | sort)
count=$(printf "%s" "$suites" | grep -c . || true)
if [ "$count" -eq 0 ]; then echo "::error::no test suites found — the glob is broken, not the repo clean"; exit 1; fi
echo "SHOULD NOT REACH HERE"
'
echo "exit: $?"
```

Expected: the `::error::` line, then `exit: 1`. `SHOULD NOT REACH HERE` must not appear.

- [ ] **Step 7: Commit**

```bash
jj commit -m "ci: run the seven shell test suites on every PR

CI ran zero tests. Seven suites (193 assertions, including
permission-gateway's 133) had never executed in CI; they passed only
because a human ran them by hand. Any PR could have broken every one of
them and CI would have been green.

test-skill-paths.sh was added in #85 specifically to catch rules that
nothing executes — and nothing executed it.

Discovery is a glob, never a hardcoded list: a list goes stale silently
when a suite is added, which is #82's failure inside the precondition
for fixing #82. Zero suites found fails loudly, for the same reason.

No paths: filter — a workflow that never triggers is indistinguishable
from one that passes.

JJ_USER/JJ_EMAIL are load-bearing, not defensive: the suites rely on the
developer's ~/.config/jj/config.toml for an identity and never mention
it. Measured against a clean HOME, test-statusline-jj.sh fails 6/8
without them and passes 8/8 with them.

macos-latest for now: statusline-jj.sh is macOS-only and degrades
silently on Linux (#88).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## PR verification

The steps above prove the shell logic on a developer laptop. They do **not** prove the workflow —
that needs GitHub to parse it, trigger it, install jj, and run the suites on a machine that has
never seen this repo. Every landmine in the spec was invisible locally.

- [ ] **Step 1: Push and open the PR**

```bash
jj git push --change @-
gh pr create --base main --head <bookmark-from-push> \
  --title "ci: run the seven shell test suites on every PR" \
  --body "See docs/specs/2026-07-16-ci-test-runner-design.md. Closes no issue; precondition for #82, #84, #86."
```

- [ ] **Step 2: Confirm it triggered at all**

```bash
gh pr checks <PR>
```

Expected: a `test` check appears. It has no `paths:` filter, so it must run on a PR that touches
only `.github/`. **If no `test` check appears, that is #82 happening again, live** — the workflow
did not trigger and its absence looks identical to success.

- [ ] **Step 3: Read the log — do not trust the tick**

```bash
gh run view <run-id> --log | grep -E "found [0-9]+ suite|PASS plugins|FAIL plugins|suites passed"
```

Expected: `found 7 suite(s)`, seven `PASS plugins/...` lines naming each suite, and
`7/7 suites passed`. Compare the seven names against `find plugins -path '*/tests/test-*.sh'`.

**A green tick is not the check.** A run that found five suites and passed all five is green and
wrong. The list is the check.

- [ ] **Step 4: Prove it can go red**

If any suite failed in Step 3, that is the proof — skip to Step 5. If all seven passed, force it:

```bash
jj new -m "TEMP: prove CI goes red — do not merge"
printf '\nexit 1  # TEMP: prove CI goes red\n' >> plugins/workspace-jj/tests/test-skill-paths.sh
jj git push --change @
```

`exit 1`, not a fabricated assertion call. The suite's helper is `bad()`, not `fail()`, and the
script's last line is already `test "$FAIL" -eq 0` — an appended `fail "..."` exits 127
(`command not found`) and turns the suite red *by accident*, blaming a missing command rather than
a failed check. Verified 2026-07-16: `exit 1` → exit 1; `fail "..."` → exit 127.

`test-skill-paths.sh` is the target because it is the fastest suite, has no external dependencies,
and is the one this workflow exists to finally execute.

Expected on the run: the `test` job goes **red**; the log shows `::error::FAIL` naming
`plugins/workspace-jj/tests/test-skill-paths.sh`; `6/7 suites passed`; and the **other six suites
still appear in the log**, proving non-fail-fast.

- [ ] **Step 5: Remove the proof commit**

```bash
jj abandon @
jj git push --change @-
jj log -r 'main::@' --no-graph -T 'change_id.short(8) ++ " " ++ description.first_line() ++ "\n"'
```

Expected: no `TEMP:` change in the output. It must not reach main.

- [ ] **Step 6: Confirm green again, then merge**

```bash
gh pr checks <PR>
gh pr merge <PR> --squash
```

Expected: `test` passes. Merge without `--delete-branch` — it fails in this jj-colocated repo.
Clean up with `jj git fetch`, then `jj bookmark delete <name>`, `jj git push --deleted`.

## What this does not prove

- **That the suites pass on Linux.** Deferred to #88; `statusline-jj.sh` is macOS-only and degrades
  silently rather than failing.
- **That the suites are good tests.** This plan makes existing assertions run. Whether they assert
  the right things is #79's question.
