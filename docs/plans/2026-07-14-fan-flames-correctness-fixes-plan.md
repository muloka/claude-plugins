# Fan-Flames Correctness Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Do NOT use workspace-jj:fan-flames for this plan** — Tasks 2, 3, and 4 all modify `plugins/workspace-jj/skills/fan-flames.md`, so the overlap graph collapses to one task per wave. Fan-flames' own Parallelism Threshold rule (<40% parallel) directs you to sequential execution here. Inline execution is correct.

**Goal:** Fix eight defects in `workspace-jj:fan-flames` found by running it end-to-end (findings #2–#9 of the 2026-07-14 test run), and add a lint that prevents finding #1's class from recurring.

**Architecture:** Five files across four stacked changes. Two changes carry code (a script + its tests, and a new lint); two are prose corrections to the skill. Each change is independently revertable. The lint lands last so it lands green.

**Tech Stack:** Bash, awk, Markdown. jj for VCS.

**Spec:** `docs/specs/2026-07-14-fan-flames-correctness-fixes-design.md` — read it for the *why* behind each fix. This plan is the *how*.

## Global Constraints

- **No raw git commands anywhere** — jj equivalents only. The only exceptions are `jj git` subcommands and the `gh` CLI.
- **Non-interactive jj forms only** — always pass `-m` to describe/commit/squash. Never run bare `jj describe`, `jj resolve`, `jj diffedit`, or `jj split` without paths.
- **Commit convention:** conventional commits, `jj describe -m "…"` then `jj new`.
- **Prose edits are surgical.** Replace exactly the quoted text. Do not restructure surrounding sections, rewrite adjacent prose, or "improve" text the task did not name.
- **This repo has no Rust and no `cargo`.** Do not add a `cargo` example anywhere.
- **Attribution:** Cluster E's lint/eval distinction draws on `netresearch/jujutsu-workflow-skill` (MIT AND CC-BY-SA-4.0). Write all text in this repo's own words — do not copy their prose verbatim.
- **Test count baseline:** `plugins/workspace-jj/tests/test-fan-flames-scripts.sh` currently reports `15 passed, 0 failed`. It must never report fewer passing than that.

---

### Task 1: Self-contained task briefs

**Files:**
- Modify: `plugins/workspace-jj/scripts/fan-flames-task-brief`
- Modify: `plugins/workspace-jj/tests/test-fan-flames-scripts.sh` (fixture ~line 39; new cases after line 92)
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (Prepare Artifacts, ~line 293)

**Interfaces:**
- Consumes: nothing.
- Produces: briefs that contain the plan preamble followed by `---` followed by the task text. No later task depends on this.

**Why:** `fan-flames-task-brief` extracts only the task section, so Global Constraints and shared definitions never reach the implementer — while the dispatch template tells the agent the brief "is your requirements." In the test run every brief said *"all four drift criteria in 'What drift means' above"* with no "above". The repo's own `docs/plans/2026-07-13-jj-agent-safety-plan.md` has a Task 1 that dangles identically.

> **Revision (2026-07-14, during implementation):** the steps below produce a **doubled horizontal rule** on every real plan in this repo. Each one closes its preamble with `---` before the first task — it is the writing-plans convention — so prepending our own separator yields two. The fixture could not catch it: its preamble does not end in a rule, which is how the plan came to be written from the fixture rather than from the plans it actually runs against.
>
> The shipped script therefore drops a trailing `---` from the preamble before adding its own, and two cases were added covering a preamble that ends in a rule. Test count is **22**, not the 20 these steps predict. The code is authoritative; the steps below are left as executed.

- [ ] **Step 1: Add a fenced decoy to the test fixture's preamble**

The existing fixture has a preamble ("Intro text that belongs to no task.") but its only fenced decoy sits inside Task 2, which tests the *task* extractor. The *preamble* extractor needs its own decoy, or fence-awareness goes untested.

In `plugins/workspace-jj/tests/test-fan-flames-scripts.sh`, replace:

```bash
cat > "$repo/plan.md" <<'EOF'
# Example Plan

## Overview

Intro text that belongs to no task.

### Task 1: First thing
```

with:

```bash
cat > "$repo/plan.md" <<'EOF'
# Example Plan

## Overview

Intro text that belongs to no task.

```markdown
### Task 8: preamble decoy inside a code fence
this fenced heading must not terminate the preamble
```

Global rule: the preamble continues past the fence.

### Task 1: First thing
```

Leave the rest of the fixture (Tasks 1–3 and the Task 9 decoy inside Task 2) exactly as it is.

- [ ] **Step 2: Write the failing tests**

In the same file, immediately after this existing line:

```bash
check_fails "brief excludes Task 3" 1 grep -q 'Third thing' "$brief"
```

insert:

```bash
# --- preamble is prepended (findings #2) ---
check "brief contains the plan preamble" \
  grep -q 'Intro text that belongs to no task' "$brief"
check "brief separates preamble from task" grep -qx -- '---' "$brief"
check "fenced Task heading does not terminate the preamble" \
  grep -q 'Global rule: the preamble continues past the fence' "$brief"

# A plan whose first line is already a task heading has no preamble, and
# must not get a stray leading separator.
cat > "$repo/plan-nopreamble.md" <<'EOF'
### Task 1: Only thing

**Files:** `z.ts`
EOF
"$SCRIPTS/fan-flames-task-brief" plan-nopreamble.md 1 "$tmp/nopre.md" >/dev/null
check "no-preamble plan still yields the task" grep -q 'Only thing' "$tmp/nopre.md"
check_fails "no-preamble plan yields no separator" 1 grep -qx -- '---' "$tmp/nopre.md"
```

- [ ] **Step 3: Run the tests and verify they fail**

Run: `bash plugins/workspace-jj/tests/test-fan-flames-scripts.sh`

Expected: FAIL. Specifically `brief contains the plan preamble`, `brief separates preamble from task`, and `fenced Task heading does not terminate the preamble` all report `FAIL`, because the script does not yet emit a preamble. The final line reports a non-zero failure count and the script exits non-zero.

(`no-preamble plan yields no separator` will *pass* already — it is a regression guard, not a new behavior. That is expected.)

- [ ] **Step 4: Implement the preamble pass**

In `plugins/workspace-jj/scripts/fan-flames-task-brief`, replace everything from the `# Extract one task's...` header comment through the end of the file with:

```bash
# Extract one task's full text from an implementation plan into a file the
# implementer reads in one call, so the task text never has to be pasted
# through the orchestrator's context.
#
# A task starts at a markdown heading matching "Task N" (any heading level)
# and ends at the next task heading. Headings inside code fences are ignored.
#
# The plan's preamble — everything before the first task heading — holds the
# Global Constraints and shared definitions that task text references but does
# not repeat. It is prepended to every brief, because the skill tells
# implementers the brief IS their requirements, and without the preamble that
# claim is false.
#
# Usage: fan-flames-task-brief PLAN_FILE TASK_NUMBER [OUTFILE]
# Default OUTFILE: <artifacts-dir>/task-<N>-brief.md
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: fan-flames-task-brief PLAN_FILE TASK_NUMBER [OUTFILE]" >&2
  exit 2
fi

plan=$1
n=$2
[ -f "$plan" ] || { echo "no such plan file: $plan" >&2; exit 2; }

if [ $# -eq 3 ]; then
  out=$3
else
  dir=$("$(cd "$(dirname "$0")" && pwd)/fan-flames-artifacts")
  out="$dir/task-${n}-brief.md"
fi

task=$(awk -v n="$n" '
  /^```/ { infence = !infence }
  !infence && /^#+[ \t]+Task[ \t]+[0-9]+/ {
    intask = ($0 ~ ("^#+[ \t]+Task[ \t]+" n "([^0-9]|$)"))
  }
  intask { print }
' "$plan")

if [ -z "$task" ]; then
  echo "task ${n} not found in ${plan} (no heading matching 'Task ${n}')" >&2
  exit 3
fi

# Everything before the first task heading. Same fence awareness as the task
# pass above — otherwise the two halves of this script would disagree about
# where the first task begins.
preamble=$(awk '
  /^```/ { infence = !infence }
  !infence && /^#+[ \t]+Task[ \t]+[0-9]+/ { exit }
  { print }
' "$plan")

{
  if [ -n "$(printf '%s' "$preamble" | tr -d '[:space:]')" ]; then
    printf '%s\n\n---\n\n' "$preamble"
  fi
  printf '%s\n' "$task"
} > "$out"

echo "wrote ${out}: $(wc -l < "$out" | tr -d ' ') lines"
```

Note the not-found check now tests `$task` rather than the output file's size, because the file would be non-empty from the preamble alone. Exit code 3 is unchanged.

- [ ] **Step 5: Run the tests and verify they pass**

Run: `bash plugins/workspace-jj/tests/test-fan-flames-scripts.sh`

Expected: PASS. The final line reports `22 passed, 0 failed` (15 existing + 7 new) and the script exits 0. If any pre-existing case now fails, the preamble pass broke the task pass — fix before continuing.

- [ ] **Step 6: Update the skill's Prepare Artifacts note**

In `plugins/workspace-jj/skills/fan-flames.md`, replace:

```markdown
   - **Plan document input:** `../scripts/fan-flames-task-brief <plan-file> <N>`
     for each task — the script extracts the task's full text without it
     passing through your context again
```

with:

```markdown
   - **Plan document input:** `../scripts/fan-flames-task-brief <plan-file> <N>`
     for each task — the script extracts the task's full text without it
     passing through your context again, and prepends the plan's preamble
     (Global Constraints, shared definitions) so the brief stands alone
```

- [ ] **Step 7: Verify**

```bash
bash plugins/workspace-jj/tests/test-fan-flames-scripts.sh | tail -1
grep -c "prepends the plan's preamble" plugins/workspace-jj/skills/fan-flames.md
```

Expected: `22 passed, 0 failed`; the grep returns `1`.

- [ ] **Step 8: Commit**

```bash
jj describe -m "fix(fan-flames): self-contained task briefs

fan-flames-task-brief extracted only the task section, so a plan's Global
Constraints and shared definitions never reached the implementer — while
the dispatch template told the agent the brief IS its requirements. Every
brief in the 2026-07-14 test run referenced 'the four drift criteria above'
with no above; docs/plans/2026-07-13-jj-agent-safety-plan.md dangles the
same way.

The script now prepends the plan preamble, fence-aware to match the task
pass, so the brief is complete on its own.

Found by: fan-flames test run 2026-07-14 (finding #2)"
jj new
```

---

### Task 2: De-Rust the test gate and handle waves with no test surface

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (phase diagram ~line 34; REVIEW Step 1 ~lines 564–578; Fix Loop item 2 ~lines 639–643)
- Modify: `plugins/workspace-jj/skills/fan-flames-wave-reviewer.md` (Your Job ~line 61)

**Interfaces:**
- Consumes: nothing.
- Produces: the ledger event `wave <W>: no-test-surface`, added to the event-lines list by Task 3. Task 3 depends on this event's exact spelling.

**Why:** `cargo test` is asserted in three places in a repo with no Rust — every reviewer in the test run was told a suite passed that doesn't exist. Worse, Fix Loop item 2 *hard-requires* covering tests before re-review, so a docs-only fix loop can never advance. The run hit that wall and had to deviate.

- [ ] **Step 1: De-Rust the phase diagram**

In `plugins/workspace-jj/skills/fan-flames.md`, replace:

```
  ║  REVIEW ── cargo test (spec gate)            ║
```

with:

```
  ║  REVIEW ── test suite (spec gate)            ║
```

`test suite` and `cargo test` are both 10 characters, so the box border stays aligned. Do not adjust surrounding whitespace.

- [ ] **Step 2: De-Rust the test gate and add the no-test-surface branch**

In the same file, replace:

````markdown
```bash
# For each task in the wave:
(cd /tmp/jj-workspaces/<repo>/<task-name> && cargo test)  # or the project's equivalent test command
```

If tests fail, dispatch fix subagents to the relevant workspace(s) and re-run. Escalate to user after 2 failed attempts.
````

with:

````markdown
```bash
# For each task in the wave:
(cd /tmp/jj-workspaces/<repo>/<task-name> && <the project's test command>)
```

If tests fail, dispatch fix subagents to the relevant workspace(s) and re-run. Escalate to user after 2 failed attempts.

**If the wave has no test surface** — its changes are documentation, prose, or
config that no test in the project reads — say so and move on. Record
`wave <W>: no-test-surface` in the ledger, tell the reviewers no automated
check has validated this wave, and rely on review. Do not invent a test, and
do not run an unrelated suite and report its pass as this wave's gate: a
suite that cannot fail on these changes has verified nothing, and reporting
it as a pass is worse than reporting no gate at all.
````

- [ ] **Step 3: Give Fix Loop item 2 the matching escape**

In the same file, replace:

```markdown
2. Fix subagent uses the same implementer protocol (DONE / BLOCKED /
   NEEDS_CONTEXT) and appends its fix report to the task's existing
   `<artifacts>/task-N-report.md`. The report must contain the covering
   tests, the command run, and the output — confirm all three are present
   before re-dispatching the reviewer
```

with:

```markdown
2. Fix subagent uses the same implementer protocol (DONE / BLOCKED /
   NEEDS_CONTEXT) and appends its fix report to the task's existing
   `<artifacts>/task-N-report.md`. The report must contain the covering
   tests, the command run, and the output — confirm all three are present
   before re-dispatching the reviewer. If no test covers the change (a
   docs or config fix), the report must say that explicitly and state what
   was verified instead; a fix subagent must never fabricate a test command
   to satisfy this gate
```

- [ ] **Step 4: De-Rust the reviewer template**

In `plugins/workspace-jj/skills/fan-flames-wave-reviewer.md`, replace:

```
    cargo test already passes — don't re-verify test values.
    Focus on what tests CAN'T catch.
```

with:

```
    The wave's test gate has already run — don't re-verify test values.
    If the orchestrator told you this wave has no test surface, then no
    automated check has validated this work at all; review accordingly.
    Focus on what tests CAN'T catch.
```

- [ ] **Step 5: Verify**

```bash
grep -rn "cargo" plugins/workspace-jj/skills/
grep -c "no-test-surface" plugins/workspace-jj/skills/fan-flames.md
grep -c "never fabricate a test command" plugins/workspace-jj/skills/fan-flames.md
awk 'NR>=21 && NR<=45 && /║/' plugins/workspace-jj/skills/fan-flames.md | awk '{print length($0)}' | sort -u | wc -l
```

Expected, in order: the first grep returns **only** `- Formatting: run the project's formatter/linter (e.g., cargo fmt, prettier, ruff) …` (an honest multi-language example that stays — no other `cargo` hits, and none in `fan-flames-wave-reviewer.md`); then `1`; then `1`.

> **Revision (2026-07-15, during implementation):** the fourth check as originally written — `awk '{print length($0)}' | sort -u | wc -l`, expecting `1` — is wrong twice over and was dropped. `awk` counts **bytes**, and the box-drawing characters are multi-byte UTF-8, so it returns `4` on a perfectly aligned diagram. Counting characters (`perl -CSD`) returns `2`, because line 41 (`(only review-approved tasks)`) carries one extra space — a pre-existing misalignment present on `main`, untouched here per the surgical-edits constraint. The line this task edits is 50 characters before and after (`cargo test` and `test suite` are both 10), so alignment is unchanged. Verify by that fact, not by a length histogram.

- [ ] **Step 6: Commit**

```bash
jj describe -m "fix(fan-flames): de-Rust the test gate, handle waves with no test surface

Three places asserted cargo test in a repo with no Rust, and the reviewer
template told every reviewer a suite had passed that does not exist. Worse,
Fix Loop item 2 hard-required covering tests before re-review, so a
docs-only fix loop could never advance — the 2026-07-14 test run hit that
wall and had to deviate to proceed.

REVIEW Step 1 now names the no-test-surface case and forbids reporting a
vacuous pass; Fix Loop item 2 takes the matching escape.

Found by: fan-flames test run 2026-07-14 (findings #5, #6, #7)"
jj new
```

---

### Task 3: Correct the integrity model and the fix-delta commands

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (ledger example ~line 129; event lines ~lines 139–142; ledger init ~line 304; dispatch template ~line 417; integrity check ~lines 499–503; COLLECT ~after line 532; Fix Loop items 1 and 3 ~lines 632–648; FAN IN conflict check ~line 789)

**Interfaces:**
- Consumes: the `wave <W>: no-test-surface` event spelling from Task 2.
- Produces: the ledger event `task N: fixing from=<commit-id>`.

**Why:** Four separate defects, all observed. The Wave 1 integrity baseline assumes an empty `@` that nothing requires — in the test run it produced a false `WORKSPACE_LEAK` on the plan document. The check never re-runs after the fix loop, which is exactly where a fix subagent leaked into `@` (it self-caught; the skill would not have). `evolog --limit 2` counts evolution steps, not "the fix" — `jj describe` consumed a window slot in three of four fixes. And `jj resolve --list` exits 2 when there are no conflicts.

- [ ] **Step 1: Fix the Wave 1 integrity baseline**

In `plugins/workspace-jj/skills/fan-flames.md`, replace:

```markdown
The expected baseline is wave-aware: in Wave 1, `@` should show no changes;
from Wave 2 on, `@` legitimately contains all prior waves' merged content, so
compare against the stat recorded after the previous FAN IN (record
`jj diff -r @ --stat` after every FAN IN to refresh the baseline). If `@`
differs from its baseline, at least one agent failed to `cd` to its workspace.
```

with:

```markdown
Compare against the **recorded baseline**, never against zero. `@` is not
required to be empty — it routinely holds the plan document, or work in
progress the run builds on. PLAN records `jj diff -r @ --stat` as the run's
baseline; every FAN IN re-records it, so from Wave 2 on the baseline includes
all prior waves' merged content. If `@` differs from the current baseline, at
least one agent failed to `cd` to its workspace.
```

- [ ] **Step 2: Record the baseline at PLAN**

In the same file, replace:

```markdown
3. Initialize the ledger — write the header and wave plan to
   `<artifacts>/progress.md`:
```

with:

```markdown
3. Record the integrity baseline: run `jj diff -r @ --stat` and keep the
   result. It is what every Workspace Integrity Check compares against — `@`
   may legitimately be non-empty at PLAN, and comparing against zero would
   report the run's own starting content as a leak.
4. Initialize the ledger — write the header and wave plan to
   `<artifacts>/progress.md`:
```

- [ ] **Step 3: Re-run the integrity check after each fix-loop round**

In the same file, replace:

```markdown
4. Repeat until no critical/important findings remain
5. Escalate to user after 2 failed fix attempts — present the findings and ask how to proceed
```

with:

```markdown
4. Re-run the Workspace Integrity Check (Phase 3) against the recorded
   baseline. Fix subagents reach their workspace by `cd`, exactly as
   implementers do, and are exactly as able to miss it — a check that runs
   only after COLLECT does not cover an agent dispatched after COLLECT
5. Repeat until no critical/important findings remain
6. Escalate to user after 2 failed fix attempts — present the findings and ask how to proceed
```

- [ ] **Step 4: Record the pre-fix commit ID at dispatch**

In the same file, replace:

```markdown
   to work in the existing workspace directory path, and name the test files
   covering the change — a small fix doesn't need the whole suite
```

with:

```markdown
   to work in the existing workspace directory path, and name the test files
   covering the change — a small fix doesn't need the whole suite. Before
   dispatching, record the change's current commit ID —
   `jj log -r <change-id> --no-graph -T 'commit_id.short()'` — to the ledger
   as `task N: fixing from=<commit-id>`. This is the only moment the fix's
   starting point is unambiguous; step 3 needs it
```

- [ ] **Step 5: Point re-reviews at the exact fix delta**

In the same file, replace:

```markdown
3. Re-dispatch reviewer scoped to the fix delta: fix subagents amend in
   place, so `jj evolog -r <change-id> -p --limit 2` shows exactly what the
   fix changed. Name that command in the re-review prompt as the reviewer's
   primary view (with the original findings for context) — re-reviews judge
   the amendment, not the whole task again
```

with:

```markdown
3. Re-dispatch reviewer scoped to the fix delta. Fix subagents amend in
   place, so the delta is exactly `jj diff --from <the commit-id recorded in
   step 1> --to <change-id>`. Name that command in the re-review prompt as
   the reviewer's primary view (with the original findings for context) —
   re-reviews judge the amendment, not the whole task again. Do not derive
   the delta from `jj evolog --limit N`: that counts evolution steps, not
   "the fix", and a `jj describe` or a second snapshot silently shifts the
   window — a truncated delta is indistinguishable from a small one
```

- [ ] **Step 6: Fix the FAN IN conflict check**

In the same file, replace:

````markdown
2. **Check for conflicts:**

```bash
jj resolve --list
```
````

with:

````markdown
2. **Check for conflicts:**

```bash
jj log -r 'conflicts()' --no-graph -T 'change_id.short() ++ "\n"'
```

Empty output means clean. Use this rather than `jj resolve --list` as the
check: `resolve --list` exits 2 when there are *no* conflicts, so any scripted
use reads the clean case as a failure. `jj resolve --list` is still the right
way to show a human which files conflict, once you know some do.
````

- [ ] **Step 7: Make the recovery convention real**

In the same file, replace:

```markdown
    Before reporting back, capture your change ID and workspace name:
    jj log -r @ --no-graph -T 'change_id'
    basename "$PWD"
```

with:

```markdown
    Before reporting back, describe your change so it can be recovered if
    you die before reporting, then capture your change ID and workspace name:
    jj describe -m "Task N: <short description>"
    jj log -r @ --no-graph -T 'change_id'
    basename "$PWD"
```

- [ ] **Step 8: Note that empty changes are legitimate**

In the same file, immediately after this line:

```markdown
If multiple matches, use the most recent. If no matches, the subagent likely never created any changes — treat as BLOCKED.
```

insert:

```markdown
### Empty Changes Are a Valid Outcome

A task can correctly produce no change — an audit that finds nothing, a
check that confirms the code is already right. An empty change is a result,
not a failure: review it like any other (the claim "there was nothing to do"
is exactly as verifiable as a diff, just against the source rather than
against a patch), and fan it in normally. `jj squash` abandons an empty
source silently, which is the correct no-op. Distinguish this from a subagent
that produced nothing because it failed — the report and the ledger say which.
```

- [ ] **Step 9: Add both new events to the ledger schema**

In the same file, replace:

```markdown
Event lines: `dispatched workspace=…`, `done change=… files=…`,
`done-with-concerns change=… files=…`, `blocked reason=…`, `needs-context`,
`workspace-leak`, `review-passed`, `review-failed findings=<n>c,<n>i`,
`squashed`, `wave <W>: fanned-in`, `run: complete`.
```

with:

```markdown
Event lines: `dispatched workspace=…`, `done change=… files=…`,
`done-with-concerns change=… files=…`, `blocked reason=…`, `needs-context`,
`workspace-leak`, `review-passed`, `review-failed findings=<n>c,<n>i`,
`fixing from=<commit-id>`, `squashed`, `wave <W>: no-test-surface`,
`wave <W>: fanned-in`, `run: complete`.
```

- [ ] **Step 10: Verify**

```bash
grep -c "recorded baseline" plugins/workspace-jj/skills/fan-flames.md
grep -c "fixing from=" plugins/workspace-jj/skills/fan-flames.md
grep -c "no-test-surface" plugins/workspace-jj/skills/fan-flames.md
grep -n "jj evolog" plugins/workspace-jj/skills/fan-flames.md
grep -n "jj resolve --list" plugins/workspace-jj/skills/fan-flames.md
grep -c "Empty Changes Are a Valid Outcome" plugins/workspace-jj/skills/fan-flames.md
```

Expected, in order: `recorded baseline` ≥ 2; `fixing from=` returns 2 (Fix Loop step 1 + the event list); `no-test-surface` returns 2 (Task 2's REVIEW branch + the event list — if this returns 1, Task 2's event spelling and this list have drifted); `jj evolog` returns 1 (only the Fix Loop's "do not derive the delta from" warning); `Empty Changes` returns 1.

> **Revision (2026-07-15, during implementation):** two of these were wrong, both caught by dry-running the edits against a scratch copy before applying them.
>
> **`recorded baseline` originally expected ≥ 2 and returns 1.** Step 3's replacement text wrapped the phrase across a line break (`against the recorded` / `baseline.`), and `grep` is line-based, so it never matched. The text was correct; the check could not see it. Step 3 above is reflowed to keep the phrase on one line. It returns 3 as shipped — Step 2's text references it too.
>
> **`jj resolve --list` originally expected "only where human-facing" and returns 6.** That expectation is unusable: four sites are agent-facing *verify-after-resolve* usages (`edit the markers, then verify with jj resolve --list`), which are correct — they read output rather than branching on exit code, and #64 established that wording deliberately. Step 6's own explanation adds two more while explaining why not to use it as the check. Replace that grep with the check that means something:
>
> ```bash
> awk '/^2\. \*\*Check for conflicts/,/^Empty output means clean/' plugins/workspace-jj/skills/fan-flames.md | grep -c '^jj resolve --list$'
> ```
>
> Expected: `0` — the conflict check itself no longer uses it. That is the whole finding; the other sites are not in scope.

- [ ] **Step 11: Commit**

```bash
jj describe -m "fix(fan-flames): correct the integrity model and fix-delta commands

Four defects, all observed in the 2026-07-14 test run:

- Wave 1's integrity baseline assumed an empty @, which no prerequisite
  requires. The run's plan document tripped it: a false WORKSPACE_LEAK.
  PLAN now records the baseline and every check compares against it, which
  also collapses the Wave 1 and Wave 2+ rules into one.
- The check never re-ran after the fix loop — precisely where a fix
  subagent leaked into @ during the run. It self-caught; the skill would
  not have. It now re-runs each round.
- evolog --limit 2 counts evolution steps, not the fix. jj describe ate a
  window slot in three of four fixes; one more jj call would have truncated
  the delta invisibly. The orchestrator now records the pre-fix commit ID at
  dispatch and re-reviews diff --from/--to it.
- jj resolve --list exits 2 when clean, inverting any scripted check.

Also: the dispatch template now sets the change description that COLLECT's
recovery path already assumed, and empty changes are documented as a valid
outcome.

Found by: fan-flames test run 2026-07-14 (findings #3, #4, #8, #9)"
jj new
```

---

### Task 4: Lint model-selection directives in skill files

**Files:**
- Create: `plugins/workspace-jj/tests/test-model-selection-lint.sh`
- Modify: `plugins/workspace-jj/skills/fan-flames-wave-reviewer.md` (model directive, ~line 16)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

**Why:** Finding #1 — a `model:` directive offering `opus/session`, the exact inheritance PR #65 removed — sat in the template the skill dispatches every reviewer from, and survived three PRs. Nothing caught it because nothing executes prose: source, cache, and installed copy all agreed at `dbcf4e3`, so no staleness check could fire. A lint is deterministic and needs no model call. An eval (netresearch's format) tests model *behavior* and would pass whenever the model happened to choose `opus` anyway — the wrong instrument for a silent, bill-only failure.

> **Revision (2026-07-15, during implementation):** rule 1 as written below was **line-based** (`grep -rnE '^[[:space:]]*model:.*[Ss]ession'`) and could not fire. The directive it must catch spans three lines, with `session` on the third — so Step 2's "verify it FAILS" was impossible, Step 3's tightening was unmotivated, and rule 1 would have shipped having never fired on anything.
>
> The error entered at the spec, which quoted the three-line directive as a one-line code span with an ellipsis and then reasoned about the quotation: *"which mentions `session` on a `model:` line"*. The spec's **rule** ("no `model:` **directive** mentions session") was right; its justification prose was not, and this plan implemented the prose. The Known-gaps entry then rationalized the mismatch instead of noticing it.
>
> The shipped lint reads the whole directive (`model:` line through the next `key:` or blank line). Every step below then holds as written: the lint fails on the current text, tightening fixes it, and Step 5 confirms both rules fire on the exact `opus/session` string. The spec has been corrected.

- [ ] **Step 1: Write the lint**

Create `plugins/workspace-jj/tests/test-model-selection-lint.sh`:

```bash
#!/usr/bin/env bash
# Lints model-selection directives across every plugin's markdown.
#
# Why this exists: fan-flames' Model Selection table is restated in the
# dispatch templates that actually get used. PR #65 fixed the table and
# missed fan-flames-wave-reviewer.md, which went on offering
# "opus/session" — session-model inheritance — for three more PRs. Nothing
# caught it: every layer (source, cache, installed copy) agreed, because
# they agreed on the unfixed text. Prose is not executed, so it is not
# checked. This checks the one rule class where being wrong is silent and
# only shows up on the bill.
#
# Usage: test-model-selection-lint.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PLUGINS="$ROOT/plugins"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); shift; printf '%s\n' "$@" | sed 's/^/    /'; }

# --- Rule 1: no model: directive may offer session-model inheritance ---
# An omitted or inherited model silently uses the session's model, which is
# usually the most capable and most expensive. Every dispatch names its tier.
hits=$(grep -rnE '^[[:space:]]*model:.*[Ss]ession' "$PLUGINS" --include='*.md' || true)
if [ -z "$hits" ]; then
  ok "no model: directive mentions session"
else
  bad "a model: directive offers session-model inheritance" "$hits"
fi

# --- Rule 2: the exact #1 shape, anywhere in a file ---
hits=$(grep -rnE '(opus|sonnet|haiku)/session' "$PLUGINS" --include='*.md' || true)
if [ -z "$hits" ]; then
  ok "no file offers <tier>/session"
else
  bad "found <tier>/session — the PR #65 regression" "$hits"
fi

# --- Rule 3: every dispatch block names a model ---
# 'Agent tool:' marks a dispatch example. Each must carry a model: line
# within the block, or the example teaches omission by demonstration.
while IFS=: read -r file line _; do
  [ -n "$file" ] || continue
  block=$(sed -n "${line},$((line + 8))p" "$file")
  if printf '%s' "$block" | grep -qE '^[[:space:]]*model:'; then
    ok "dispatch block at $(basename "$file"):$line names a model"
  else
    bad "dispatch block at $(basename "$file"):$line has no model: line" "$block"
  fi
done < <(grep -rn 'Agent tool:' "$PLUGINS" --include='*.md' || true)

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
```

- [ ] **Step 2: Run the lint and verify it FAILS**

Run: `bash plugins/workspace-jj/tests/test-model-selection-lint.sh`

Expected: FAIL, exit non-zero, with `FAIL: a model: directive offers session-model inheritance` naming `fan-flames-wave-reviewer.md:16`.

This failure is the point. The current directive reads:

```
  model: <per the skill's Model Selection — sonnet floor; opus for risky or final
         waves. Always specify explicitly — an omitted model silently inherits
         the session's model>
```

That text is *correct guidance* but it states the rule on the directive line, where rule 1 cannot distinguish a warning about session inheritance from an offer of it. **A lint that has never failed is a lint nobody has verified** — observe this failure before making it pass.

- [ ] **Step 3: Tighten the directive so the lint passes**

In `plugins/workspace-jj/skills/fan-flames-wave-reviewer.md`, replace:

```
  model: <per the skill's Model Selection — sonnet floor; opus for risky or final
         waves. Always specify explicitly — an omitted model silently inherits
         the session's model>
```

with:

```
  model: <per the skill's Model Selection — sonnet floor; opus for risky or
         final waves. Always explicit; never omitted>
```

The directive does not need to explain *why*: the skill's Model Selection section already states that an omitted `model` inherits the session's model. The directive's job is to be unambiguous about what to write.

- [ ] **Step 4: Run the lint and verify it passes**

Run: `bash plugins/workspace-jj/tests/test-model-selection-lint.sh`

Expected: PASS, exit 0, `4 passed, 0 failed` — rules 1 and 2 plus one case per `Agent tool:` block (`fan-flames.md:348` and `fan-flames-wave-reviewer.md:14`, both of which already carry a `model:` line).

- [ ] **Step 5: Prove the lint catches the original bug**

Verify the lint fails on the exact text that shipped, rather than trusting that it would:

```bash
cp plugins/workspace-jj/skills/fan-flames-wave-reviewer.md /tmp/wr-backup.md
sed -i '' 's|model: <per the skill.s Model Selection — sonnet floor; opus for risky or|model: <per the skill'"'"'s Model Selection — sonnet floor; opus/session for risky or|' plugins/workspace-jj/skills/fan-flames-wave-reviewer.md
bash plugins/workspace-jj/tests/test-model-selection-lint.sh; echo "exit: $?"
cp /tmp/wr-backup.md plugins/workspace-jj/skills/fan-flames-wave-reviewer.md
rm /tmp/wr-backup.md
bash plugins/workspace-jj/tests/test-model-selection-lint.sh | tail -1
```

Expected: the middle run FAILS on both rule 1 and rule 2 with a non-zero exit; after restoring, the final line reads `4 passed, 0 failed`. Confirm `jj diff --stat` shows `fan-flames-wave-reviewer.md` back to just the Step 3 edit before committing.

- [ ] **Step 6: Verify**

```bash
bash plugins/workspace-jj/tests/test-model-selection-lint.sh | tail -1
bash plugins/workspace-jj/tests/test-fan-flames-scripts.sh | tail -1
test -x plugins/workspace-jj/tests/test-model-selection-lint.sh && echo "executable" || chmod +x plugins/workspace-jj/tests/test-model-selection-lint.sh
```

Expected: `4 passed, 0 failed`; `22 passed, 0 failed`; the lint is executable (match the mode of the sibling test scripts).

- [ ] **Step 7: Commit**

```bash
jj describe -m "test(workspace-jj): lint model-selection directives in skill files

PR #65 removed session-model inheritance from fan-flames.md's Model
Selection table and missed fan-flames-wave-reviewer.md — the template the
skill dispatches every reviewer from — which went on offering opus/session
for three more PRs. No staleness check could catch it: source, cache, and
installed copy all agreed at dbcf4e3, on the unfixed text. Nothing executes
prose, so nothing checked it.

Three deterministic rules over plugins/**/*.md: no model: directive mentions
session, no file offers <tier>/session, every 'Agent tool:' block names a
model. Verified by observing it fail on the text that actually shipped.

An eval would test model behavior and pass whenever the model happened to
pick opus anyway — the wrong instrument for a failure that is silent and
only visible on the bill. The behavioral eval suite stays parked; the
lint/eval split is recorded in the design doc.

Scope is deliberately one rule class. Other skill rules are equally
unexecuted and each needs its own false-positive analysis.

Found by: fan-flames test run 2026-07-14 (finding #1's class)"
jj new
```

---

## Verification (whole plan)

1. `bash plugins/workspace-jj/tests/test-fan-flames-scripts.sh` → `22 passed, 0 failed`
2. `bash plugins/workspace-jj/tests/test-model-selection-lint.sh` → `4 passed, 0 failed`
3. `grep -rn "cargo" plugins/workspace-jj/skills/` → exactly one hit, the `(e.g., cargo fmt, prettier, ruff)` formatter example
4. `grep -rnE '(opus|sonnet|haiku)/session' plugins/` → no hits
5. `grep -c "no-test-surface" plugins/workspace-jj/skills/fan-flames.md` → 2 (the REVIEW branch and the event list agree)
6. `grep -c "fixing from=" plugins/workspace-jj/skills/fan-flames.md` → 2 (Fix Loop and the event list agree)
7. `jj log -r 'trunk()..@' --no-graph -T 'description.first_line() ++ "\n"'` → the four changes, in order
8. Read the edited regions of `fan-flames.md` once for coherence. Growth from all four tasks should stay under ~50 lines.

## Known gaps (accepted, per the spec)

- **Tasks 2 and 3 have no automated test.** Their verification is greps and reading. This is the design's weakest point and is deliberate: the lint closes one rule class (model directives), not the skill's prose in general.
- **The lint's rule 1 ends a directive at the next `key:` or blank line.** A continuation line that happens to start with `word:` would end the span early. No directive in the repo does, and rule 2 catches the specific `<tier>/session` shape anywhere in a file regardless. (An earlier version of this plan shipped rule 1 as a line-based grep and accepted a much larger gap — that it could not see continuation lines at all. See Task 4's Revision.)
- **No end-to-end re-run validates these changes.** Deferred by decision — the next genuine fan-flames use is the test. A prose regression surfaces there, not before.
