# sdd-review-package `--evolution-diff` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Give `sdd-review-package` an intra-change evolution mode so a fix round's "what did the fix change" diff is tool-generated instead of hand-rolled, without weakening the hidden-revision guard.

**Spec:** GitHub issue #172 plus its discoverability-contract comment (`gh issue view 172 --comments`). The design core, verbatim from the issue: hidden-provenance does NOT discriminate safe from dangerous — the discriminator is `change_id(BASE) == change_id(HEAD)`. Same change = deliberate evolution diff (safe); different change = the stale-package hazard (stays a hard error, flag or no flag).

**Tech stack:** bash (the script must stay bash-3.2-safe per repo CI: no globstar, no associative arrays, no `${var,,}`), jj revset/template queries, existing test suite conventions in `plugins/workspace-jj/tests/test-sdd-scripts.sh`.

## Global Constraints

- **jj, never git.** Commit = `jj describe -m "<msg>"` on the current change. The working copy is already on the task's change.
- **Version-bump invariant (CI-enforced):** workspace-jj is at **0.3.1**; this change bumps it to **0.4.0** (new script capability = minor).
- The script's existing behavior for default mode must be byte-for-byte preserved EXCEPT the one enriched error message specified below. Every existing test in `test-sdd-scripts.sh` must still pass unmodified.
- The suite's convention: every guard asserted in BOTH directions (fails-correctly + fixture-is-honest). Follow it for each new case.

---

### Task 1: `--evolution-diff` mode + error-path teach + tests

**Files:**
- Modify: `plugins/workspace-jj/scripts/sdd-review-package`
- Modify: `plugins/workspace-jj/tests/test-sdd-scripts.sh` (extend; do not restructure existing cases)
- Modify: `plugins/workspace-jj/.claude-plugin/plugin.json` (version 0.3.1 → 0.4.0)

**Requirements (from #172 + comment):**

1. **Flag parsing.** `--evolution-diff` accepted as the first argument: `sdd-review-package [--evolution-diff] PLAN_FILE BASE HEAD [OUTFILE]`. Update the usage line accordingly.

2. **Evolution mode semantics.** With the flag:
   - BASE resolving to a hidden revision is PERMITTED — that is the mode's purpose (BASE is typically the pre-fix commit id).
   - HARD ERROR (exit 2) if `change_id(BASE) != change_id(HEAD)`: the flag declares intent, it does not disable the guard. Error must state both change ids.
   - The commit-id-shaped warning is SUPPRESSED for BASE in this mode — a commit id is the expected currency here (it names one immutable pre-fix state).
   - SKIP the ancestral check — a predecessor is a rewrite of its successor, not a DAG ancestor; the check would reject every valid evolution pair.
   - Replace the `## Changes` section (revset ranges cannot list hidden commits) with a `## Evolution` section containing `jj evolog -r <head-change-id>` output (`--no-graph`, template matching the existing Changes template style: change_id.short, commit_id.short, description.first_line).
   - `## Files changed` and `## Diff` stay tree-to-tree comparisons of the two resolved commits, unchanged machinery.
   - Default output filename: `evolution-<headChange:0:8>-<baseCommit:0:8>..<headCommit:0:8>.diff` (change id for identity, both commit ids for the round — the standard name would self-collide across rounds since both change ids are identical).
   - HEAD hidden remains an error exactly as in default mode.

3. **Error-path teach (the load-bearing discoverability surface — #172 comment).** In DEFAULT mode, when BASE is hidden AND `change_id(BASE) == change_id(HEAD)`, the existing hidden-revision error must be replaced for that case by one that:
   - explains BASE is the pre-fix copy of HEAD's own change, and
   - emits the COMPLETE runnable rerun command with the caller's own arguments substituted verbatim, e.g. `sdd-review-package --evolution-diff <plan> <base> <head>` (include OUTFILE if the caller passed one; use the script's invoked name `$0` basename or the literal `sdd-review-package`).
   The other hidden case (different change ids) keeps the existing error text unchanged.

4. **Tests** (extend `test-sdd-scripts.sh`, following its both-directions convention; the suite already builds fixtures with captured pre-rewrite commit ids — reuse its pattern of describing a change to hide a commit):
   - fails-correctly: default mode, hidden BASE of the SAME change as HEAD → exit 2 AND stderr contains the runnable rerun command (assert on `--evolution-diff <plan-file>` plus the exact BASE token — the substituted-args contract, not just the flag name).
   - fixture-is-honest for the above: the BASE really is hidden (`jj log -r <base> -T 'if(hidden,...)'` says hidden) and really shares HEAD's change id.
   - fails-correctly: `--evolution-diff` with BASE and HEAD of DIFFERENT changes → exit 2, error names both change ids.
   - fixture-is-honest: those two really are different changes.
   - happy path: `--evolution-diff` with a hidden pre-rewrite commit as BASE and its evolved change as HEAD → exit 0; package contains `## Evolution` (not `## Changes`), an evolog line for the change, `## Diff` showing the content the rewrite changed; default filename starts with `evolution-` and embeds both commit prefixes.
   - happy path negative: the commit-id warning does NOT appear on stderr in evolution mode.
   - regression: the full existing suite passes unmodified.

5. **TDD order:** write the new test cases first, run the suite to see exactly the new cases fail (existing 32 stay green), implement, run the suite green, bump the version.

- [ ] Step 1: extend the test suite with the cases above; run `/bin/bash plugins/workspace-jj/tests/test-sdd-scripts.sh` — new cases fail, existing pass
- [ ] Step 2: implement the mode + enriched default-mode error in `sdd-review-package`
- [ ] Step 3: suite green: `/bin/bash plugins/workspace-jj/tests/test-sdd-scripts.sh`
- [ ] Step 4: bump workspace-jj plugin.json 0.3.1 → 0.4.0
- [ ] Step 5: run every workspace-jj suite: `for t in plugins/workspace-jj/tests/test-*.sh; do /bin/bash "$t" || exit 1; done`
- [ ] Step 6: commit: `jj describe -m "feat(workspace-jj): sdd-review-package --evolution-diff — tool-generated fix-round diffs, guard teaches the flag (#172)"` (do NOT run `jj new`; the controller owns the next step)

---

## Out of scope

- Any change to `sdd-artifacts`, the kaisen scripts, or upstream superpowers scripts.
- Auto-detecting evolution mode without the flag (intent stays declared).
