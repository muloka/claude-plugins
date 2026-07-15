# fan-flames correctness fixes (design)

**Date:** 2026-07-14
**Status:** Approved, not yet implemented.

> **Provenance:** every fix below was found by *running* fan-flames end-to-end against the #64/#65 changes (a five-task plugin README audit, one wave, five parallel workspaces). None came from reading the skill. The run's ledger and artifacts are the evidence; the findings are numbered as reported there. Finding #1 shipped separately during the same session and is out of scope here.

## Goal

Correct eight defects in `workspace-jj:fan-flames` that only surface when the skill is executed: dangling brief context, an integrity check that misfires on Wave 1 and never re-runs after fixes, a test gate that assumes Rust and cannot express "no test can validate this wave", and two commands whose documented form is subtly wrong.

The unifying property: **every one of these is invisible to review and visible on the first run.** #1 — the bug that opened this thread — survived three PRs of human review of the diff, then took minutes to find by dispatching one agent. This design does not fix that gap (see Non-Goals), but it is the reason the gap is worth naming.

## Root causes, not findings

The eight findings collapse into four causes. Fixing causes rather than symptoms is what makes this three changes instead of eight.

| Cluster | Findings | Root cause |
|---|---|---|
| **A. Rust assumption** | #5, #6, #7 | The skill assumes a test suite exists and that it is `cargo test` |
| **B. Integrity model** | #3, #4 | The check is one-shot, and its Wave 1 baseline assumes an empty `@` |
| **C. Brief not self-contained** | #2 | `fan-flames-task-brief` extracts only the task section |
| **D. Wrong commands** | #8, #9 | `evolog --limit 2` and `resolve --list` are both subtly wrong |
| **E. Nothing executes prose** | #1's *class* | No mechanism asserts that skill text states the rules correctly |

Cluster E is not one of the numbered findings. It is why #1 existed, and it is the only cluster that prevents a recurrence rather than fixing an instance.

## Architecture

Five files. Clusters C and E carry code; the rest is prose in the skill.

| File | Nature | Clusters |
|---|---|---|
| `plugins/workspace-jj/scripts/fan-flames-task-brief` | code | C |
| `plugins/workspace-jj/tests/test-fan-flames-scripts.sh` | code | C |
| `plugins/workspace-jj/tests/test-model-selection-lint.sh` | **new**, code | E |
| `plugins/workspace-jj/skills/fan-flames.md` | prose | A, B, C, D |
| `plugins/workspace-jj/skills/fan-flames-wave-reviewer.md` | prose | A, E |

---

## Cluster C — self-contained briefs

**The defect.** `fan-flames-task-brief` extracts from `### Task N` to the next task heading. Plan-level sections — Global Constraints, shared definitions, Tech Stack — are silently dropped. The dispatch template then tells the agent the brief "is your requirements, with the exact values to use verbatim." It isn't. In the test run, every brief contained the phrase *"all four drift criteria in 'What drift means' above"* with no "above" present.

This is not an artifact of the test plan. `docs/plans/2026-07-13-jj-agent-safety-plan.md` — the plan that produced #64 — has Task 1 declaring *"Produces: the canonical conflict-resolution wording (see Global Constraints)"*. That brief dangles identically.

**The skill also contradicts itself on the remedy.** The dispatch template offers a slot for "decisions the brief cannot know," while the dispatch rules forbid pasting "task text, plan excerpts, or prior-wave summaries" into the prompt. Global Constraints are a plan excerpt. Filling the slot breaks the rule; obeying the rule leaves the agent underspecified. There is no compliant path.

**The fix.** The script prepends the plan's preamble — everything before the first task heading — to each brief, separated by `---`. The brief becomes what the skill already claims it is.

```
## <plan preamble: Goal, Global Constraints, shared definitions>

---

### Task 3: peer-review-jj README audit
...
```

**Rejected: point agents at the plan file path.** This cannot work and the run proved it. Wave 1 workspaces are pinned to `@-`, and the plan document typically lives in `@` — so the file is absent from the workspace. This was discovered live, when the orchestrator's ad-hoc `plan-context.md` had to go in `/tmp` for exactly this reason.

**Rejected: orchestrator writes a shared `plan-context.md`.** Workable (it is what the run did as a stopgap), but it adds an artifact type and requires every dispatch to remember a second path. One file the agent reads is better than two it must be told about.

**Edges the tests must pin:**

1. Plan **with** a preamble → brief carries preamble, separator, task.
2. Plan **without** a preamble → brief is the task alone, no leading separator.
3. Task not found → still exits 3 (regression).
4. Preamble extraction is fence-aware, matching the existing task extractor: a `### Task 1` inside a code fence must not terminate the preamble.

Edge 4 is not hypothetical. `docs/plans/2026-07-12-fan-flames-context-economics-plan.md` contains **three `### Task N` headings inside code fences**. A non-fence-aware preamble extractor terminates at the first one and silently truncates the preamble. The existing task extractor is already fence-aware; the preamble pass must match it, or the two halves of the same script will disagree about where the first task begins.

**Ad-hoc input is unaffected** — the orchestrator writes those briefs itself and can include whatever it needs.

---

## Cluster A — de-Rust, and name the vacuous gate

**The defect, part one (cosmetic).** `cargo test` appears in three places that assume Rust: the phase diagram (`fan-flames.md:34`, a flat assertion), the test gate (`:575`, hedged with "or the project's equivalent"), and the reviewer template (`fan-flames-wave-reviewer.md:61`, unhedged — *"cargo test already passes — don't re-verify test values"*). This repo contains no Rust. Every reviewer dispatched during the test run was told a suite passed that does not exist.

`fan-flames.md:393` reads `(e.g., cargo fmt, prettier, ruff)`. That is an honest multi-language example and **stays**.

**The defect, part two (blocking).** REVIEW Step 1 calls the test suite "the primary spec compliance gate." Fix Loop step 2 goes further: *"The report must contain the covering tests, the command run, and the output — confirm all three are present before re-dispatching the reviewer."*

For a wave that changes only documentation, no test can reach the changes. Taken literally, that gate can never be satisfied and **the fix loop can never advance**. The test run hit this wall and had to deviate to proceed.

**The fix.** REVIEW Step 1 gains an explicit branch: if the wave's changes have no test surface, record `wave W: no-test-surface` and rely on review — do not fabricate a test, and do not report a vacuous pass as a pass. Fix Loop step 2 gains the matching escape: if no test covers the change, the report must say so explicitly and state what was verified instead.

**Why not a general "Verification Gate" rewrite.** Considered and cut. Reframing Step 1 as "whatever verification the project affords" is more conceptually correct and more future-proof, but it churns text that works today for waves that do have tests. The narrow fix addresses the actual block. Revisit if a third case appears.

---

## Cluster B — fix the integrity model

**The defect, part one.** The Workspace Integrity Check says: *"in Wave 1, `@` should show no changes… If `@` differs from its baseline, at least one agent failed to `cd`."* Nothing in the Prerequisites requires `@` to be empty — prerequisite 3 asks only for "a description and be a sensible parent."

In the test run, `@` held the plan document (169 insertions), written before PLAN. By the letter of the skill this was a `WORKSPACE_LEAK` and should have been escalated to the user. It was a false positive. Any run started from a non-empty `@` — plan doc in the working copy, or building on WIP — trips this.

The Wave 2+ rule is **already correct**: "compare against the stat recorded after the previous FAN IN." Wave 1 is the odd one out.

**The fix.** PLAN records `jj diff -r @ --stat` as the run's baseline. Wave 1 compares against that recorded baseline rather than against zero. This makes Wave 1 and Wave 2+ the same rule, stated once.

**The defect, part two.** The integrity check runs after COLLECT and never again. Fix subagents `cd` into workspaces exactly as implementers do, and are exactly as exposed.

**This is not hypothetical.** In the test run, task 5's fix subagent edited the orchestrator's workspace instead of its own — *"my first edit attempt accidentally landed on the default workspace… because Bash cwd resets between calls."* It self-caught and reverted. Had it not, the leak would have reached FAN IN unchecked, because the skill never looks again.

**The fix.** The integrity check re-runs after each fix-loop round, against the same recorded baseline. A control that fires once cannot cover an agent dispatched later.

---

## Cluster D — correct the commands

### #8 — the fix delta

**The defect.** Fix Loop step 3 prescribes `jj evolog -r <change-id> -p --limit 2` as showing "exactly what the fix changed." `--limit 2` counts *evolution steps*, not "the fix." A `jj describe` is an evolution step: in the test run, describes consumed a window slot in three of four fixes. The windows happened to remain complete because each fix was a single snapshot.

One extra `jj` invocation between edits — an agent running `jj diff` to check itself mid-fix — yields `[describe][snapshot-2]` and **silently truncates the delta**. A partial fix delta looks exactly like a complete small one; the reviewer cannot detect the truncation.

To be precise: **this did not bite in the test run.** All four windows were verified complete. It is latent, not observed.

**The fix.** Stop discovering the boundary retroactively; record it prospectively. Before dispatching a fix subagent, the orchestrator captures the change's current commit ID to the ledger:

```
task 4: fixing from=1f67fa9cefa8
```

The re-review then uses the exact delta:

```
jj diff --from 1f67fa9cefa8 --to <change-id>
```

**Verified during the run:** hidden commits remain diffable by commit ID even after the change is squashed and abandoned — `jj diff --from e3c35569 --to cd9441a9` returned task 1's fix precisely. The mechanism is sound.

The same session demonstrated why retroactive discovery fails: an attempt to guess task 4's pre-fix boundary from its five evolog entries picked the wrong pair and returned `0 files changed`. The orchestrator knows the boundary unambiguously at exactly one moment — immediately before it dispatches the fix. Record it there.

### #9 — the conflict check

**The defect.** FAN IN step 2 presents `jj resolve --list` as a bash conflict check. On a clean revision it prints `Error: No conflicts found at this revision` and **exits 2**. Any scripted use (`set -euo pipefail`, or `if jj resolve --list; then`) reads the clean case as a failure — inverted.

**The fix.** Use `jj log -r 'conflicts()'` — exit 0, empty output when clean. This matches the repo's own `jjconflicts` helper (exit 0 = clean, 1 = conflicts). `jj resolve --list` remains useful for a human reading which files conflict; it is not a check.

---

---

## Cluster E — a lint for the rule class

**The defect.** #1 was a `model:` directive offering `opus/session` — the exact session-model inheritance PR #65 set out to remove — sitting in the template the skill dispatches every reviewer from. It survived three PRs of review. Nothing caught it because **nothing executes prose**: source, cache, and installed copy all agreed at `dbcf4e3`, so no staleness check could fire, and no test reads a skill file.

**Why an eval is the wrong instrument here.** The eval-suite idea (adapted from `netresearch/jujutsu-workflow-skill`, whose `evals/evals.json` runs prompt-plus-assertion cases like `describe-noninteractive` and `pager-hang-avoidance`) tests *model behavior* given a prompt. #1 is a defect in *file text*. An orchestrator reading `opus/session` may well still pick `opus` — the eval passes green while the bug persists. Since #1's failure mode is silent and only visible on the bill, a probabilistic instrument is the wrong shape for it.

A lint is deterministic, needs no model call, and cannot flake. Note that netresearch runs both: `evals/` alongside `.markdownlint-cli2.jsonc` and `tests/smoke_test.sh`. The two instruments cover two different gaps:

| Gap | Instrument | Catches #1? |
|---|---|---|
| Skill text asserts something wrong | **Lint** | Yes — deterministically |
| Skill text leads the model to act wrong | **Eval** | Unreliably — passes if the model guesses right |

**The fix.** A new `plugins/workspace-jj/tests/test-model-selection-lint.sh` scanning `plugins/**/*.md`, asserting two rules:

1. **No `model:` directive mentions `session`.** The regression guard for #1 — it fails on the exact text that shipped.
2. **Every agent-dispatch block carries a `model:` line.** The omission guard, which is #65's actual concern: an omitted `model` is what silently inherits.

**Deliberately not a rule: "must name an explicit tier."** `fan-flames.md:350` reads `model: <per Model Selection — always specify explicitly>`, which names no tier and is entirely correct — it points at the table. A tier rule would flag good text, and a lint that cries wolf gets deleted.

**Rule 1 forces a rewording of #1's own fix.** The shipped text is a directive spanning three lines:

```
  model: <per the skill's Model Selection — sonnet floor; opus for risky or final
         waves. Always specify explicitly — an omitted model silently inherits
         the session's model>
```

`session` sits on the **third** line, not the `model:` line — so rule 1 must read the whole directive (`model:` line through the next `key:` or blank line), not a single line. A line-based check cannot see this, and would ship green while the rule it claims to enforce goes unenforced.

The template does not need to explain *why* an omitted model is expensive — the skill's Model Selection section already does, and stating the policy inside the directive is what made the rule unstatable. It tightens to `<… Always explicit; never omitted>`. The lint improving the fix that prompted it is the point.

**Location.** `workspace-jj/tests/` despite scanning repo-wide, because workspace-jj owns the Model Selection rule and the repo has no top-level test convention (verified: every test lives under `plugins/*/tests/`, and there is no root runner). If a second repo-wide lint ever appears, that convention deserves revisiting — one lint does not justify inventing it.

---

## Minors folded in

**Recovery depends on an unestablished convention.** COLLECT's "Recovery: Missing Change IDs" recovers a crashed agent's work via `jj log -r 'description("Task N: …")'`. Nothing in the dispatch template tells implementers to describe their change. The safety net presumes a convention the skill never sets. The dispatch template gains `jj describe -m "Task N: <short description>"`.

**Empty changes are legitimate.** A task can correctly produce no change — task 3 audited `peer-review-jj`, found no drift, and returned an empty change. The reviewer independently verified that negative claim and it held. The skill has no branch for this. `jj squash` handles it gracefully (it abandons the empty source, silently), so this is documentation only: COLLECT notes that an empty change may be a valid outcome, not a failure.

## Ledger schema additions

Two new event lines. Both must be added to the event-lines list in Durable Progress — that list is the ledger's schema, and a resume that encounters an undocumented event is a resume that guesses.

| Event | Written at |
|---|---|
| `wave W: no-test-surface` | REVIEW Step 1, when no test can reach the wave's changes |
| `task N: fixing from=<commit-id>` | Fix Loop step 1, before dispatching the fix subagent |

## Delivery

A stack of four changes:

1. **`fix(fan-flames): self-contained task briefs`** — script + tests + skill note.
2. **`fix(fan-flames): de-Rust the test gate, handle waves with no test surface`** — spans both prose files.
3. **`fix(fan-flames): correct the integrity model and fix-delta commands`** — Clusters B + D, plus the minors and ledger events.
4. **`test(workspace-jj): lint model-selection directives in skill files`** — Cluster E, plus the rule-1 rewording of #1's text.

Each is independently revertable. Stacking is free in jj.

**Change 4 goes last on purpose.** It codifies the rule the earlier changes must satisfy, so it lands green rather than red. No intermediate change fails a lint that does not exist yet at its point in the stack; the lint passes at HEAD.

## Testing

**Clusters C and E are genuinely tested.** `test-fan-flames-scripts.sh` grows from 15 cases to 22, covering the brief edges. `test-model-selection-lint.sh` is itself a test (4 cases: two rules plus one per `Agent tool:` block), and must be verified by observation — a lint that has never failed is a lint nobody has verified. It is run against the pre-fix `opus/session` text and watched to fail before being trusted.

**Clusters A, B, and D have no automated test.** Verification is sentinel greps plus reading the edited regions. This is stated plainly because it remains the design's weakest point. Greps confirm text is present; they cannot confirm it is right. Cluster E closes exactly one rule class — the model directives — and nothing more. The rest of the skill's prose is still unexecuted.

**The only real test is another run.** Deliberately deferred: rather than burn a synthetic run now, the next genuine fan-flames use validates these changes. Accepted risk — a prose regression here surfaces on that run, not before it.

## Non-Goals

- **A general Verification Gate rewrite** (see Cluster A) — revisit if a third case appears.
- **An eval suite for skill prose.** Still parked, where the `2026-07-13` plan put it ("Eval suite (`claude plugin eval` cases) — right long-term practice, separate initiative"). Cluster E takes the deterministic half of that idea at a fraction of the cost; the behavioral half remains a real initiative and a real gap. Adopting netresearch's `evals.json` format is the obvious starting point when it happens.
- **Generalizing the lint beyond model directives.** Many other skill rules are equally unexecuted (the non-interactive-forms rule, the artifact path handoffs). Each would need its own assertion and its own false-positive analysis. One rule class, proven, first.
- **Re-auditing #64's other changes.** Swept during the test run and clean: #64's interactive-forms verification grep still passes, and the `opus/session` miss was confirmed bounded to one file. The other `model`/`session` hits across the plugins are pinned frontmatter (`change-reviewer.md:17`, `receiving-change-review.md:118`) and a coincidental `SessionState` example.

## Why the staleness model missed #1

Worth recording, because it generalizes. The three-layer model (source → cache → installed copy) checks whether the layers *agree*. For #1 they agreed perfectly, all at `dbcf4e3`, including the installed copy — they agreed on the **unfixed text**. A currency check cannot find a fix that was never written.

The generalization: when a PR fixes a rule stated in one file, check every file that *restates* the rule. `fan-flames.md` holds the Model Selection table; `fan-flames-wave-reviewer.md` restated it and drifted. Skills that dispatch from templates have two copies of every rule, and only one of them gets reviewed.

Cluster E is that generalization made mechanical, for one rule class. A human remembering to check restatements is a practice; a lint asserting no restatement offers session inheritance is a guarantee. The practice is still worth holding — the lint covers model directives and nothing else — but it is worth noticing that the rule most worth remembering is the one now enforced without anyone remembering it.
