# Fan-Flames v2 Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Do NOT use subagent-driven-development or fan-flames for this plan.** All 10 tasks modify the same file sequentially — no parallelism benefit. Additionally, the CLAUDE.md override routes subagent-driven-development to fan-flames, which is the skill being modified (chicken-and-egg).

**Goal:** Evolve fan-flames from a flat parallel dispatcher into a wave-based orchestrator with per-task spec review gates, replacing superpowers' subagent-driven-development in jj repos.

**Architecture:** Single skill file (`fan-flames.md`) rewritten in place, plus a new spec reviewer prompt template. The skill describes orchestration behavior for Claude Code — it's a markdown prompt, not traditional code. Changes are structured as incremental section rewrites that can be validated by reading the file and checking structural consistency.

**Tech Stack:** Markdown (skill file), shell awareness (jj commands referenced in prompts)

**Spec:** `docs/specs/2026-04-02-fan-flames-v2-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `plugins/workspace-jj/skills/fan-flames.md` | Rewrite | Main skill — phase orchestration, wave computation, review gates |
| `plugins/workspace-jj/skills/fan-flames-spec-reviewer.md` | Create | Spec reviewer prompt template — self-contained, jj-native |

The spec reviewer prompt is separated into its own file (referenced by fan-flames.md) to keep the main skill focused on orchestration. Same pattern as superpowers' `subagent-driven-development/spec-reviewer-prompt.md`.

---

### Task 1: Create Spec Reviewer Prompt Template

**Files:**
- Create: `plugins/workspace-jj/skills/fan-flames-spec-reviewer.md`

No tests — this is a prompt template, validated by structural review.

- [ ] **Step 1: Create the spec reviewer prompt template**

Write `plugins/workspace-jj/skills/fan-flames-spec-reviewer.md`:

```markdown
# Spec Reviewer Prompt Template

Use this template when dispatching a spec reviewer subagent during the REVIEW phase.

**Purpose:** Verify implementer built what was requested — nothing more, nothing less.

**Dispatch context:** Spec reviewers run in the orchestrator's context (no `isolation: "worktree"`). They are read-only, using jj revset commands to inspect changes by change ID.

## Template

    Agent tool:
      description: "Spec review: Task N"
      prompt: |
        You are reviewing whether an implementation matches its specification.

        ## What Was Requested

        [FULL TEXT of task requirements from plan]

        ## What Implementer Claims

        [From implementer's status report — status, files changed, test results, concerns]

        ## Do Not Trust the Report

        The implementer may be incomplete, inaccurate, or optimistic.
        Verify everything independently by reading the actual code.

        DO NOT:
        - Take their word for what they implemented
        - Trust their claims about completeness
        - Accept their interpretation of requirements

        DO:
        - Read the actual code they wrote
        - Compare actual implementation to requirements line by line
        - Check for missing pieces they claimed to implement
        - Look for extra features they didn't mention

        ## How to Read the Code

        This is a jj repository. The implementation lives in change [CHANGE_ID].

        jj diff -r [CHANGE_ID]                        # see what changed
        jj file show -r [CHANGE_ID] [path]            # read a file at that revision
        jj log -r [CHANGE_ID] --stat                  # summary of files touched

        Do NOT limit yourself to the diff. Read full files when context matters
        for understanding whether the implementation is correct.

        CRITICAL: You MUST NOT use ANY raw git commands. Always use jj equivalents.

        ## Your Job

        Read the code and verify:

        **Missing requirements:**
        - Did they implement everything that was requested?
        - Are there requirements they skipped or missed?
        - Did they claim something works but didn't actually implement it?

        **Extra/unneeded work:**
        - Did they build things that weren't requested?
        - Did they over-engineer or add unnecessary features?

        **Misunderstandings:**
        - Did they interpret requirements differently than intended?
        - Did they solve the wrong problem?

        Report:
        - PASS — spec compliant (cite evidence from code: file paths, what you verified)
        - FAIL — issues found (file:line references, what's missing/extra/wrong)

## Placeholders

- `[FULL TEXT of task requirements from plan]` — paste the complete task text, not a summary
- `[From implementer's status report]` — the implementer's full report including status, files, tests, concerns
- `[CHANGE_ID]` — the jj change ID reported by the implementer
```

- [ ] **Step 2: Verify file exists and is well-formed**

```bash
cat plugins/workspace-jj/skills/fan-flames-spec-reviewer.md | head -5
```

Expected: frontmatter-free markdown starting with `# Spec Reviewer Prompt Template`

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(fan-flames): add spec reviewer prompt template"
```

---

### Task 2: Rewrite PLAN Phase — Add Wave Computation

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (Phase 1: PLAN section, roughly lines 38-57)

- [ ] **Step 1: Read current PLAN phase**

```bash
jj file show -r @ plugins/workspace-jj/skills/fan-flames.md
```

Identify the Phase 1: PLAN section boundaries.

- [ ] **Step 2: Replace the PLAN phase**

Replace the existing Phase 1 section (from `## Phase 1: PLAN` through the end of the section before `## Phase 2: FAN OUT`) with:

```markdown
## Phase 1: PLAN — Validate Independence and Compute Waves

Before fanning out, validate that tasks can run in parallel and compute execution waves:

1. Extract the file paths each task will touch (from the plan's `Files:` sections or by analyzing task descriptions)
2. Build a file → task mapping
3. Build an undirected overlap graph: edge between tasks that share files
4. Compute waves using greedy graph coloring:
   - For each task, assign to the earliest wave where it has no overlap with already-assigned tasks in that wave

```
Example:
Tasks: 1(a.ts, b.ts), 2(c.ts), 3(a.ts, d.ts), 4(e.ts), 5(d.ts, e.ts)

Overlap graph:
  1 ── 3  (a.ts)
  3 ── 5  (d.ts)
  4 ── 5  (e.ts)

Wave assignment:
  Wave 1: Task 1, Task 2, Task 4  ← no edges between them
  Wave 2: Task 3, Task 5          ← no edges between them
```

### User Interaction

**No overlaps (most common case):**

```
All N tasks are independent — executing as a single wave.
```

No confirmation needed. Proceed immediately.

**Overlaps detected:**

```
File overlaps detected — proposing W waves:

  Wave 1: Task 1 (a.ts, b.ts), Task 2 (c.ts), Task 4 (e.ts)
  Wave 2: Task 3 (a.ts, d.ts), Task 5 (d.ts, e.ts)

  Overlaps: 1↔3 (a.ts), 3↔5 (d.ts), 4↔5 (e.ts)

Proceed with this wave plan? (or restructure)
```

Wait for user confirmation before proceeding.

5. **Recommend** 3-5 concurrent workspaces per wave for most tasks. Note the recommendation but do not block dispatch if more are requested.
```

- [ ] **Step 3: Verify the edit is clean**

Read the file and confirm the PLAN section flows into the FAN OUT section without duplicated or orphaned content.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(fan-flames): add wave computation to PLAN phase"
```

---

### Task 3: Rewrite FAN OUT Phase — Implementer Prompt Enhancement

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (Phase 2: FAN OUT section, roughly lines 59-102)

- [ ] **Step 1: Read current FAN OUT phase**

Identify the Phase 2 section boundaries and the existing subagent prompt template.

- [ ] **Step 2: Replace the subagent prompt template**

In the FAN OUT phase, replace the existing `Agent tool:` prompt block with the enhanced version that adds self-review and escalation guidance. The new prompt:

```markdown
For each task in the current wave, dispatch a subagent with workspace isolation:

```
Agent tool:
  description: "Task N: <short description>"
  isolation: "worktree"
  prompt: |
    <full task text from plan>

    <any project context needed: CLAUDE.md, relevant file contents, etc.>

    CRITICAL: You MUST NOT use ANY raw git commands — not even for context
    discovery. Always use jj equivalents (jj log, jj diff, jj status, etc.).
    The only exceptions are `jj git` subcommands and `gh` CLI.

    ## Self-Review Before Reporting

    Before reporting back, review your work with fresh eyes:

    - Completeness: did I implement everything in the spec?
    - Quality: are names clear, code maintainable?
    - Discipline: did I avoid overbuilding (YAGNI)?
    - Testing: do tests verify behavior, not just mock it?

    If you find issues, fix them now before reporting.

    ## When You're in Over Your Head

    It is always OK to stop and say "this is too hard for me."
    Bad work is worse than no work.

    STOP and escalate when:
    - The task requires architectural decisions with multiple valid approaches
    - You need to understand code beyond what was provided
    - You feel uncertain about your approach
    - The task involves restructuring the plan didn't anticipate

    ## Reporting

    IMPORTANT: Before reporting back, capture your change ID and workspace name:
    jj log -r @ --no-graph -T 'change_id'
    basename "$PWD"

    When done, report:
    - Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
    - Change ID: <the change_id from above>
    - Workspace directory: <the basename from above>
    - Files changed (list paths)
    - Test results (if applicable)
    - Self-review findings (if any)
    - Any concerns
```
```

- [ ] **Step 3: Update the dispatch rules**

Keep the existing dispatch rules but add a note about per-wave dispatch:

```markdown
**Dispatch rules:**
- Dispatch all tasks in the current wave simultaneously (parallel, not sequential)
- Each subagent gets `isolation: "worktree"` — Claude Code creates a jj workspace via the WorktreeCreate hook
- Provide each subagent with the full task text, not a summary
- Include relevant project context (CLAUDE.md rules, key file contents)
- If the plan uses superpowers skills (TDD, code review), include those references in the subagent prompt
```

- [ ] **Step 4: Update progress tracking to reference waves**

Replace the progress tracking example:

```markdown
**Progress tracking:**
- After dispatch, report how many subagents are running:

```
🪭 Fan-out: Wave W — 3 tasks dispatched to isolated workspaces
  🔥 Task 1: "Add validation middleware"
  🔥 Task 2: "Migrate auth store"
  🔥 Task 3: "Update API types"

Waiting for all subagents to return...
```
```

- [ ] **Step 5: Verify the edit is clean**

Read the file and confirm the FAN OUT section is coherent.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(fan-flames): enhance implementer prompt with self-review and escalation"
```

---

### Task 4: Update COLLECT Phase — Defer Workspace Cleanup

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (Phase 3: COLLECT section, roughly lines 104-127)

- [ ] **Step 1: Read current COLLECT phase**

Identify the Phase 3 section boundaries.

- [ ] **Step 2: Add cleanup deferral note**

After the existing COLLECT content (status classification table, change ID tracking, recovery mechanism), add:

```markdown
### Workspace Lifecycle

In v1, workspaces survived COLLECT and were cleaned up during FAN IN (after each squash). In v2, **workspaces remain alive through the REVIEW phase** so that fix subagents can be dispatched into the original workspace if spec review fails. Cleanup happens after all tasks in the wave pass spec review, before FAN IN.
```

- [ ] **Step 3: Verify the edit is clean**

Read the file and confirm COLLECT flows into the next section.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(fan-flames): defer workspace cleanup to after REVIEW"
```

---

### Task 5: Add REVIEW Phase (new)

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (insert new section between COLLECT and FAN IN)

This is the largest task — the new REVIEW phase. Insert it after Phase 3 (COLLECT) and before the existing FAN IN phase.

- [ ] **Step 1: Identify insertion point**

Find the end of the COLLECT section and the start of the FAN IN section. The new REVIEW phase goes between them.

- [ ] **Step 2: Insert the REVIEW phase**

Add the following section between COLLECT and FAN IN:

```markdown
## Phase 4: REVIEW — Spec Compliance Gates

Runs once per wave, after COLLECT and before FAN IN.

### Spec Reviewer Dispatch

For each DONE or DONE_WITH_CONCERNS task, dispatch a spec reviewer subagent. Spec reviewers run in the orchestrator's context (no `isolation: "worktree"`) — they are read-only, using `jj diff -r` and `jj file show -r` to inspect changes by change ID. All reviewers for the wave run in parallel and cannot conflict.

Use the template at `./fan-flames-spec-reviewer.md` to construct each reviewer prompt. Fill in:
- `[FULL TEXT of task requirements from plan]` — the complete task text
- `[From implementer's status report]` — the implementer's report
- `[CHANGE_ID]` — the jj change ID from the implementer

### Handling Review Results

| Reviewer result | Action |
|----------------|--------|
| PASS | Task approved for fan-in |
| FAIL | Enter fix loop |

### Fix Loop

When a spec reviewer returns FAIL:

1. Dispatch fix subagent **without** `isolation: "worktree"` (the workspace already exists — `isolation` would create a new one). Tell the subagent to work in the existing workspace directory path (e.g., `.claude/workspaces/<task-name>/`) and provide the reviewer's specific findings
2. Fix subagent uses the same implementer protocol (DONE / BLOCKED / NEEDS_CONTEXT)
3. Re-dispatch spec reviewer for that task only (same template, updated implementer report)
4. Repeat until PASS
5. Escalate to user after 2 failed fix attempts — present the reviewer's findings and ask how to proceed

Fix-induced file overlap changes for later waves are ignored. jj handles any resulting conflicts during fan-in.

### After All Tasks in the Wave Pass

1. Clean up workspaces: `jj workspace forget workspace-<dir-name>` for each task
2. Proceed to FAN IN

### Skipping Review

When `--skip-spec-review` is set, this entire phase is skipped. Workspaces are cleaned up immediately after COLLECT, and all DONE/DONE_WITH_CONCERNS tasks proceed directly to FAN IN. This restores v1 behavior.
```

- [ ] **Step 3: Renumber subsequent phases**

After inserting REVIEW as Phase 4:
- FAN IN becomes Phase 5 (was Phase 4 in v1)
- VERIFY becomes Phase 6 (was Phase 5 in v1)

Update the heading numbers in the existing FAN IN and VERIFY sections.

- [ ] **Step 4: Verify the edit is clean**

Read the file and confirm the REVIEW phase is properly positioned and subsequent phases are correctly renumbered.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(fan-flames): add REVIEW phase with spec compliance gates and fix loop"
```

---

### Task 6: Update FAN IN Phase — Spec-Approved Only

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (now Phase 5: FAN IN)

- [ ] **Step 1: Read current FAN IN phase**

Identify the FAN IN section.

- [ ] **Step 2: Add spec-approval gate**

At the top of the FAN IN section, after the phase heading, add:

```markdown
**Only spec-approved tasks are squashed.** Tasks that failed spec review and couldn't be fixed are preserved in their workspaces — same handling as BLOCKED tasks.
```

- [ ] **Step 3: Remove workspace cleanup from FAN IN**

Workspace cleanup now happens in REVIEW (Phase 4). Remove `jj workspace forget` calls from:
- **Pattern A (Step 2a):** Remove the "Clean up workspaces" step (line ~165 in current file)
- **Pattern B (Step 2b):** Remove Step 3 ("Clean up the workspace") from within the "For each completed task, in order" loop (line ~220 in current file)

Leave all other FAN IN content (squash, conflict detection, topology detection) unchanged.

For **failed tasks** (at the end of Pattern B), keep the instruction:

```markdown
**For each failed task:**
- Do NOT forget workspace — preserve for inspection
- Report the failure and workspace name
```

- [ ] **Step 4: Verify the edit is clean**

Read the FAN IN section and confirm cleanup references are removed and the spec-approval gate is present.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(fan-flames): gate fan-in on spec approval, move cleanup to REVIEW"
```

---

### Task 7: Update VERIFY Phase — Enhanced Reporting

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (now Phase 6: VERIFY)

- [ ] **Step 1: Read current VERIFY phase**

Identify the VERIFY section.

- [ ] **Step 2: Replace the report template**

Replace the existing report format with the enhanced version that includes wave information:

```markdown
## Phase 6: VERIFY — Review and Report

After all waves complete:

1. **Run peer review** on the combined result:

```
/peer-review
```

`/peer-review` sees the full merged diff across all waves — cross-task patterns (naming consistency, file growth, integration issues) are visible here that per-task review would miss. If it finds quality issues, fix them in the default workspace on the combined result.

2. **Report plan coverage:**

**If plan-based:**

```
🪭🔥 Fan-flames complete (N/M tasks across W waves)

### Waves
- Wave 1: Tasks 1, 2, 4 — all passed spec review, merged
- Wave 2: Tasks 3, 5 — Task 3 passed, Task 5 blocked

### Plan Coverage
- X/Y plan requirements satisfied by merged tasks
- Z requirements blocked by failed tasks

### Failed
- Task 5: <failure reason>
  Workspace: workspace-task-5 (preserved, inspect with /workspace-list)
```

**If ad-hoc:**

```
🪭🔥 Fan-flames complete (N/M tasks across W waves)

### Waves
- Wave 1: "Add validation", "Update types" — merged
- Wave 2: "Migrate store" — blocked

### Failed
- "Migrate store" — <failure reason>
  Workspace preserved for inspection
```
```

- [ ] **Step 3: Verify the edit is clean**

Read the VERIFY section and confirm it references waves and `/peer-review`.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(fan-flames): enhance VERIFY with wave reporting and explicit quality gate"
```

---

### Task 8: Update Flags and Metadata

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (Flags section + frontmatter)

- [ ] **Step 1: Update the Flags table**

Replace the existing Flags section:

```markdown
## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--merge-order auto` | auto | Merge order within each wave: `auto` (smallest diff first) or explicit task list |
| `--skip-spec-review` | false | Skip per-task REVIEW phase (cleanup after COLLECT, straight to FAN IN) |
| `--skip-review` | false | Skip `/peer-review` in VERIFY (unchanged from v1) |
```

- [ ] **Step 2: Update the frontmatter description**

Update the skill's YAML frontmatter description to reflect v2 capabilities:

```yaml
---
name: fan-flames
description: |
  Orchestrate parallel subagent execution across isolated jj workspaces with
  wave-based scheduling and per-task spec review gates, then reunify results
  into a single change. Use when the user asks to "fan out tasks", "run tasks
  in parallel with isolation", "dispatch subagents for independent tasks",
  or when subagent-driven-development routes here via CLAUDE.md override in a jj repo.
---
```

- [ ] **Step 3: Verify the edit is clean**

Read the file top (frontmatter) and flags section, confirm both are updated.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(fan-flames): update flags (add --skip-spec-review) and metadata"
```

---

### Task 9: Add Per-Wave Loop Structure

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (top-level structure)

This task adds the orchestration glue: the per-wave loop that ties FAN OUT → COLLECT → REVIEW → FAN IN together, and the top-level phase diagram.

- [ ] **Step 1: Update the top-level phase diagram**

Replace the title and description paragraph (lines 10-16 of the current file: the `# Fan-Flames` heading through the "Announce at start" line) with the updated version below. **Preserve** the Prerequisites section, Input section, and all reference sections (Conflict Handling Reference, DAG Topology Reference, Key Principles) — do not modify or remove them.

```markdown
# Fan-Flames: Parallel Workspace Orchestration

Orchestrate parallel subagent execution across isolated jj workspaces with
wave-based scheduling and per-task spec review gates, then reunify results
into a single change. The jj-native replacement for superpowers' subagent-driven-development.

**Announce at start:** "I'm using the fan-flames skill to orchestrate parallel workspace execution."

## Phase Overview

```
PLAN ─── validate independence, compute waves, confirm with user
  │
  ╔══════════════════════════════════════════════╗
  ║  Per wave:                                   ║
  ║                                              ║
  ║  FAN OUT ── dispatch all wave tasks          ║
  ║     │       in parallel workspaces           ║
  ║     ▼                                        ║
  ║  COLLECT ── gather results + change IDs      ║
  ║     │       classify status                  ║
  ║     │       workspaces kept alive            ║
  ║     ▼                                        ║
  ║  REVIEW ── spec reviewers (parallel,         ║
  ║     │      read-only, all tasks at once)     ║
  ║     │      fix loop in original workspace    ║
  ║     │      cleanup workspaces on pass        ║
  ║     ▼                                        ║
  ║  FAN IN ── squash into @, smallest first     ║
  ║            (only spec-approved tasks)         ║
  ╚══════════════════════════════════════════════╝
  │
VERIFY ── /peer-review on combined result
           (covers code quality across all waves)
           report plan coverage
```

## Per-Wave Execution

For each wave (computed in PLAN):

1. Execute **FAN OUT** — dispatch all wave tasks in parallel
2. Execute **COLLECT** — gather results, classify, keep workspaces alive
3. Execute **REVIEW** — spec reviewers in parallel, fix loop if needed, cleanup on pass
4. Execute **FAN IN** — squash spec-approved tasks into @

After all waves complete, execute **VERIFY**.

If only one wave (no overlaps), this is equivalent to v1 behavior plus spec review.
```

- [ ] **Step 2: Verify the full file structure**

Read the complete file and verify:
- Frontmatter is correct
- Phase overview diagram is present
- Per-wave execution section exists
- Phases are numbered 1-6 in order: PLAN, FAN OUT, COLLECT, REVIEW, FAN IN, VERIFY
- No orphaned or duplicated content
- Prerequisites section is preserved (unchanged from v1)
- Input section is preserved (unchanged from v1)
- Conflict Handling Reference section is preserved
- DAG Topology Reference section is preserved
- Key Principles section is preserved

- [ ] **Step 3: Final commit**

```bash
jj describe -m "feat(fan-flames): add per-wave loop structure and phase overview diagram"
```

---

### Task 10: Structural Validation

**Files:**
- Read: `plugins/workspace-jj/skills/fan-flames.md` (full file)
- Read: `plugins/workspace-jj/skills/fan-flames-spec-reviewer.md` (full file)

This task validates the complete implementation against the spec.

- [ ] **Step 1: Verify all spec requirements are covered**

Read `docs/specs/2026-04-02-fan-flames-v2-design.md` and check each section against the implementation:

| Spec Section | Implemented In |
|-------------|---------------|
| Phase structure (6 phases, wave loop) | Task 9: phase overview + per-wave loop |
| Wave computation (greedy graph coloring) | Task 2: PLAN phase |
| Implementer self-review | Task 3: FAN OUT prompt |
| Implementer escalation protocol | Task 3: FAN OUT prompt |
| Workspace cleanup deferral | Task 4: COLLECT + Task 5: REVIEW |
| Spec reviewer dispatch (parallel, read-only) | Task 5: REVIEW + Task 1: template |
| Fix loop (in existing workspace, 2-attempt limit) | Task 5: REVIEW |
| Spec-approved gate on FAN IN | Task 6: FAN IN |
| `/peer-review` as quality gate | Task 7: VERIFY |
| Enhanced plan coverage reporting with waves | Task 7: VERIFY |
| `--skip-spec-review` flag (new) | Task 8: Flags |
| `--skip-review` unchanged from v1 | Task 8: Flags |
| jj-native throughout (no git commands) | All tasks |
| CLAUDE.md override unchanged | No change needed |
| jj Features Leveraged table | Informational spec content — no plan task needed |

- [ ] **Step 2: Verify spec reviewer template references**

Confirm that fan-flames.md references `./fan-flames-spec-reviewer.md` and the template file exists.

- [ ] **Step 3: Verify no v1 content conflicts**

Check that:
- Workspace cleanup is NOT mentioned in FAN IN (moved to REVIEW)
- Phase numbers are sequential (1-6)
- No references to "Phase 4: FAN IN" (now Phase 5)
- No references to "Phase 5: VERIFY" (now Phase 6)
- `--skip-review` only refers to `/peer-review` in VERIFY, not the new REVIEW phase

- [ ] **Step 4: Final commit (only if fixes were made during validation)**

```bash
jj describe -m "feat(fan-flames): v2 — wave-based execution with spec review gates

Evolves fan-flames from flat parallel dispatcher to wave-based orchestrator:
- Automatic wave computation from file-overlap graph
- Per-task spec review gates with fix loop
- Implementer self-review and escalation protocol
- Workspace cleanup deferred to after review passes
- Enhanced plan coverage reporting with wave info
- --skip-spec-review flag for v1 compat

Closes rigor gap with superpowers subagent-driven-development
while preserving parallel execution and jj-native advantages."
```
