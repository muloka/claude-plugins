# Fan-Flames SDD Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use workspace-jj:fan-flames (per CLAUDE.md override of superpowers:subagent-driven-development) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Note: all four tasks modify `plugins/workspace-jj/skills/fan-flames.md`, so a fan-flames run would serialize into four waves — inline execution is the better fit.

**Goal:** Port the four remaining superpowers 6.x subagent-driven-development refinements into fan-flames: per-dispatch model selection (#3), reviewer hardening (#4), the fix-dispatch evidence contract (#5), and a pre-flight plan scan (#6).

**Architecture:** All four are prompt/process edits to the fan-flames skill and its wave-reviewer template — no scripts, no code. Model selection becomes a new top-level section plus `model:` lines in both dispatch templates; reviewer hardening adds a `cannot-verify` severity to the JSON findings contract plus anti-pre-judging rules for the orchestrator; the fix loop gains an evidence contract (covering tests + command + output before re-review); the PLAN phase gains a contradiction scan batched into the existing wave-confirmation interaction.

**Tech Stack:** Markdown only. jj for VCS.

**Background:** Items #1–#2 from the SDD comparison (file handoffs, durable ledger) landed in PR #57; four dry-run corrections landed in PR #58. This plan covers items #3–#6, adapted rather than copied: fan-flames reviewers return JSON (so SDD's prose "⚠️ cannot verify" channel becomes a severity value), and its reviewers read code via jj change IDs (so SDD's diff-file review mechanics are deliberately NOT ported).

## Global Constraints

- **No raw git commands anywhere** — jj equivalents only.
- **Terseness:** `fan-flames.md` is read in full by the orchestrator every run — each ported section must stay under ~25 lines. Do not copy SDD prose verbatim where a table or tighter wording works.
- **Model names:** use Claude Code Agent-tool tiers exactly as `haiku` (cheapest), `sonnet` (mid), `opus` (most capable); "session model" means omitting the `model` param. Never invent other names.
- **Severity enum after this plan:** `critical | important | suggestion | cannot-verify` — the same four values must appear in the template's JSON schema, the template's severity guide, and the skill's Handling Review Results table.
- **Commit convention:** conventional commits scoped `feat(fan-flames): …` / `docs: …`, committed with `jj describe -m "…"` then `jj new`.

---

### Task 1: Model selection per dispatch (#3)

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (new section after Durable Progress and Resume, currently ending near line 161; dispatch template at line 283; COLLECT table at line 408)
- Modify: `plugins/workspace-jj/skills/fan-flames-wave-reviewer.md` (Agent tool block at line 14)

**Interfaces:**
- Consumes: nothing.
- Produces: the section heading `## Model Selection` and the tier names `haiku`/`sonnet`/`opus`, referenced verbatim by Task 3's template edits and by both dispatch templates.

- [ ] **Step 1: Add the Model Selection section**

In `plugins/workspace-jj/skills/fan-flames.md`, insert immediately before `## Phase 1: PLAN — Validate Independence and Compute Waves` (currently line 163):

```markdown
## Model Selection

Parallel dispatch multiplies model cost: each wave fans the chosen model out
across N workspaces, then reviewers, then fix loops. Use the least capable
model that can handle each role, and specify it explicitly on every Agent
call — an omitted `model` silently inherits the session's model, often the
most capable and most expensive.

| Role | Model |
|------|-------|
| Implementer — brief contains the complete code to write (transcription + tests) | `haiku` |
| Implementer — prose spec, 1-2 files | `sonnet` |
| Implementer — multi-file integration or design judgment | session model (omit) |
| Reviewer — small mechanical wave | `sonnet` |
| Reviewer — subtle/risky changes, or the final wave (covers the combined result) | `opus` or session model |
| Fix subagent | same model as the task's implementer |

**Turn count beats token price.** Cost scales with how many turns a subagent
takes, and the cheapest models routinely take 2-3× the turns on multi-step
work — costing more overall. `sonnet` is the floor for reviewers and for
implementers working from prose descriptions.

```

- [ ] **Step 2: Add the model line to the implementer dispatch template**

In the same file, in the FAN OUT dispatch template (currently line 283), replace:

```
Agent tool:
  description: "Task N: <short description>"
  prompt: |
```

with:

```
Agent tool:
  description: "Task N: <short description>"
  model: <per Model Selection — always specify explicitly>
  prompt: |
```

- [ ] **Step 3: Add BLOCKED model escalation to COLLECT**

In the COLLECT status table (currently line 408), replace the row:

```markdown
| BLOCKED | Note failure, track workspace for sweep |
```

with:

```markdown
| BLOCKED | Assess the blocker: missing context → provide it and re-dispatch same model; needs more reasoning → re-dispatch with a more capable model; task too large or plan wrong → escalate to user. Otherwise note failure, track workspace for sweep |
```

- [ ] **Step 4: Add the model line to the wave-reviewer template**

In `plugins/workspace-jj/skills/fan-flames-wave-reviewer.md` (currently line 14), replace:

```
Agent tool:
  subagent_type: "peer-review-jj:change-reviewer"
  description: "Wave N review: <files summary>"
```

with:

```
Agent tool:
  subagent_type: "peer-review-jj:change-reviewer"
  model: <per the skill's Model Selection — sonnet floor; opus/session for risky or final waves>
  description: "Wave N review: <files summary>"
```

- [ ] **Step 5: Verify**

```bash
grep -c "Model Selection" plugins/workspace-jj/skills/fan-flames.md plugins/workspace-jj/skills/fan-flames-wave-reviewer.md
grep -n "model: <per" plugins/workspace-jj/skills/fan-flames.md plugins/workspace-jj/skills/fan-flames-wave-reviewer.md
```

Expected: `fan-flames.md` ≥ 2 mentions and one `model: <per` line; the template has one of each.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(fan-flames): per-dispatch model selection

Ports SDD's model-selection guidance: explicit model on every Agent call,
tiered by role (haiku for transcription briefs, sonnet floor for reviewers
and prose-spec implementers, opus/session for the final wave's review),
BLOCKED escalation re-dispatches with a more capable model. Parallel
dispatch multiplies model cost, so this matters more here than in SDD."
jj new
```

---

### Task 2: Fix-dispatch evidence contract (#5)

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (Fix Loop, currently line 526)

**Interfaces:**
- Consumes: `## Model Selection` heading from Task 1 (referenced in the fix-dispatch bullet).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Replace the Fix Loop steps**

In `plugins/workspace-jj/skills/fan-flames.md`, replace the current Fix Loop items 1–3:

```markdown
1. Dispatch fix subagent **without** `isolation: "worktree"` (the workspace already exists — `isolation` would create a new one). Tell the subagent to work in the existing workspace directory path and provide the reviewer's specific findings
2. Fix subagent uses the same implementer protocol (DONE / BLOCKED /
   NEEDS_CONTEXT) and appends its fix report — what it changed and the
   test results — to the task's existing `<artifacts>/task-N-report.md`
3. Re-run tests, then re-dispatch reviewer for affected files only
```

with:

```markdown
1. Dispatch ONE fix subagent per task carrying that task's complete findings
   list — never one subagent per finding (per-finding fixers each rebuild
   context and re-run suites). Dispatch **without** `isolation: "worktree"`
   (the workspace already exists — `isolation` would create a new one), on
   the same model as the task's implementer (see Model Selection). Tell it
   to work in the existing workspace directory path, and name the test files
   covering the change — a small fix doesn't need the whole suite
2. Fix subagent uses the same implementer protocol (DONE / BLOCKED /
   NEEDS_CONTEXT) and appends its fix report to the task's existing
   `<artifacts>/task-N-report.md`. The report must contain the covering
   tests, the command run, and the output — confirm all three are present
   before re-dispatching the reviewer
3. Re-dispatch reviewer for affected files only
```

- [ ] **Step 2: Verify**

```bash
grep -n "never one subagent per finding" plugins/workspace-jj/skills/fan-flames.md
grep -n "covering" plugins/workspace-jj/skills/fan-flames.md
```

Expected: both hit inside the Fix Loop section; the old "Re-run tests, then re-dispatch" line is gone.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(fan-flames): fix-dispatch evidence contract

Ports SDD's fix contract: one fixer per task with the complete findings
list, covering tests named in the dispatch, and the fix report must show
covering tests + command + output before the re-review dispatches."
jj new
```

---

### Task 3: Reviewer hardening (#4)

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames-wave-reviewer.md` (JSON schema at line 74, severity guide at lines 83–86)
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (REVIEW Step 2 fill-in list; Handling Review Results table at line 518)

**Interfaces:**
- Consumes: nothing from earlier tasks (independent of Tasks 1–2 content).
- Produces: the `cannot-verify` severity value, used identically in the template JSON schema, template severity guide, and the skill's Handling Review Results table (see Global Constraints).

- [ ] **Step 1: Add cannot-verify to the template's JSON schema**

In `plugins/workspace-jj/skills/fan-flames-wave-reviewer.md`, replace:

```
        "severity": "critical|important|suggestion",
```

with:

```
        "severity": "critical|important|suggestion|cannot-verify",
```

- [ ] **Step 2: Replace the template's severity guide with guide + calibration**

In the same file, replace:

```
    Severity guide:
    - **critical**: wrong behavior, missing requirement, security issue
    - **important**: naming confusion, missing edge case, API misuse, pattern violation
    - **suggestion**: style preference, minor improvement — don't block on these
```

with:

```
    Severity guide:
    - **critical**: wrong behavior, missing requirement, security issue
    - **important**: the task can't be merged until fixed — incorrect or
      fragile behavior, a missed requirement, verbatim duplication of a
      logic block, swallowed errors, tests that assert nothing
    - **suggestion**: style preference, broader-coverage wishes, polish —
      don't block on these
    - **cannot-verify**: a requirement you can't verify from this wave's
      changes alone (it lives in unchanged code or spans tasks). Say in the
      finding what the orchestrator should check. Report it alongside your
      other findings — don't widen your search to chase it

    Calibration: not everything is critical. If the brief itself mandates
    something this rubric calls a defect, that IS a finding — report it as
    important with "plan-mandated" in the text. The plan's authorship does
    not grade its own work; the human decides.
```

- [ ] **Step 3: Add anti-pre-judging rules to the skill's REVIEW phase**

In `plugins/workspace-jj/skills/fan-flames.md`, immediately after the REVIEW Step 2 fill-in list (the block ending `- `[CHANGE_IDS]` — the jj change IDs from the implementers`) and before `Dispatch all reviewers for the wave in parallel.`, insert:

```markdown
When filling the template, never pre-judge findings: no "do not flag X", no
pre-rated severities ("suggestion at most"), and no open-ended extras
("check all uses") without a concrete task-specific reason. If you expect a
finding would be a false positive, let the reviewer raise it and adjudicate
it in the fix loop.
```

- [ ] **Step 4: Handle cannot-verify and plan-mandated findings in the skill**

In the Handling Review Results severity table, replace:

```markdown
| suggestion | Note for user, don't block |
```

with:

```markdown
| suggestion | Note for user, don't block |
| cannot-verify | Orchestrator resolves it — you hold the plan and cross-task context the reviewer lacks. A confirmed gap = review-failed for that task |
```

And after the line `If no critical/important findings: all tasks approved for fan-in.`, insert:

```markdown
A finding labeled plan-mandated — or any finding that conflicts with what
the plan's text requires — goes to the user: present the finding beside the
plan text and ask which governs. Don't dismiss it because the plan mandates
it, and don't dispatch a fix that contradicts the plan without asking.
```

- [ ] **Step 5: Verify**

```bash
grep -c "cannot-verify" plugins/workspace-jj/skills/fan-flames.md plugins/workspace-jj/skills/fan-flames-wave-reviewer.md
grep -n "plan-mandated" plugins/workspace-jj/skills/fan-flames.md plugins/workspace-jj/skills/fan-flames-wave-reviewer.md
```

Expected: `cannot-verify` ≥ 1 in the skill and ≥ 2 in the template; `plan-mandated` appears in both files.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(fan-flames): reviewer hardening — cannot-verify channel, calibration, no pre-judging

Ports SDD's reviewer safeguards adapted to the JSON findings contract:
cannot-verify severity for requirements outside the wave's changes
(orchestrator resolves them), severity calibration with plan-mandated
defects still reported, and a ban on pre-judging findings in dispatch
prompts."
jj new
```

---

### Task 4: Pre-flight plan scan (#6)

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (PLAN phase, before `### User Interaction` at line 187)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Insert the Pre-Flight Plan Scan subsection**

In `plugins/workspace-jj/skills/fan-flames.md`, immediately before `### User Interaction` (currently line 187), insert:

```markdown
### Pre-Flight Plan Scan

While extracting tasks, scan the plan once for conflicts:

- tasks that contradict each other or the plan's Global Constraints
- anything the plan explicitly mandates that review would flag as a defect
  (a test that asserts nothing, verbatim duplication of a logic block)

Batch anything found into the same interaction as the wave-plan
confirmation — each finding beside the plan text that mandates it, asking
which governs. If the scan is clean, proceed without comment. The review
loop remains the net for conflicts that only emerge from implementation.

```

- [ ] **Step 2: Verify**

```bash
grep -n "Pre-Flight Plan Scan" plugins/workspace-jj/skills/fan-flames.md
```

Expected: one hit, located between the wave-computation steps and `### User Interaction`.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(fan-flames): pre-flight plan scan in PLAN phase

Ports SDD's pre-flight review: scan the plan for internal contradictions
and plan-mandated defects while extracting tasks (the plan is already being
read for file extraction), batching findings into the wave-confirmation
interaction instead of one interrupt per discovery mid-run."
jj new
```

---

## Deliberately not ported

- SDD's diff-file review mechanics (`review-package`, DIFF_FILE handoffs) — fan-flames reviewers read code via jj change IDs, which is already a zero-context handoff.
- SDD's "ask questions before starting" implementer round-trip — parallel wave dispatch can't block on mid-wave Q&A; NEEDS_CONTEXT covers it.
- SDD's praise-first reviewer tone guidance and TDD RED/GREEN evidence blocks — nice-to-haves that don't pay for their line count in a skill read every run.

## Verification (whole branch)

1. `grep -rn "FULL TEXT\|Re-run tests, then" plugins/workspace-jj/` — no hits
2. The severity enum is identical in all three places: template JSON schema, template severity guide, skill Handling Review Results table (`critical`, `important`, `suggestion`, `cannot-verify`)
3. Read `fan-flames.md` top to bottom once: total growth from this plan ≤ ~70 lines; every new section reads coherently in place
4. `plugins/workspace-jj/tests/test-fan-flames-scripts.sh` — still 15/15 (untouched, regression check)
