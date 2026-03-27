# Fan-Flames v2: Wave-Based Execution with Review Gates

**Date:** 2026-04-02
**Status:** Draft
**Supersedes:** Fan-flames sections in `2026-03-18-permission-gateway-and-fan-flames-design.md`
**Plugin:** `workspace-jj`
**Skill:** `fan-flames.md` (evolved in place)
**Superpowers version reference:** 5.0.7 (subagent-driven-development, spec-reviewer, code-quality-reviewer, implementer prompt)

---

## Overview

Evolve fan-flames from a flat parallel dispatcher into a wave-based orchestrator with per-task spec review gates. Closes the rigor gap with superpowers' `subagent-driven-development` while preserving fan-flames' parallel execution model and jj-native advantages.

**Before (fan-flames v1):**
```
PLAN → FAN OUT (all tasks) → COLLECT → FAN IN → VERIFY
```

**After (fan-flames v2):**
```
PLAN → [per wave: FAN OUT → COLLECT → REVIEW → FAN IN] → VERIFY
```

**Net result:** Full subagent-driven-development rigor (spec review gates, implementer escalation protocol, self-review) + parallel speed + jj-native advantages (change IDs, first-class conflicts, auto-rebase, surgical squash, cheap workspaces).

### Why this replaces subagent-driven-development in jj repos

| Capability | subagent-driven-dev | fan-flames v2 |
|-----------|---------------------|---------------|
| Execution model | Sequential (one task at a time) | Parallel within waves, sequential across waves |
| Isolation | git worktrees | jj workspaces (shared store, near-instant) |
| Spec review | Per-task, sequential | Per-task, parallel across all wave tasks |
| Code quality review | Per-task (between spec and next task) | Batched to VERIFY via `/peer-review` |
| Fix propagation | Manual rebase | jj auto-rebase |
| Conflict model | Blocking (git) | First-class (jj records, doesn't block) |
| Reference stability | git SHAs (change on rebase) | jj change IDs (survive everything) |
| Implementer protocol | DONE/DONE_WITH_CONCERNS/BLOCKED/NEEDS_CONTEXT | Same |
| Self-review | Yes | Yes (adopted) |
| DAG reshaping | Not available | `jj parallelize`, `jj absorb` post-hoc |

Code quality review is deferred to VERIFY because: (a) spec review catches "wrong thing built" — the high-value per-task gate; (b) quality issues rarely cascade across tasks; (c) `/peer-review` sees cross-task patterns that per-task review cannot.

---

## Phase Structure

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

---

## Phase 1: PLAN

Unchanged from v1 except for wave computation.

### Wave Computation

When file overlaps exist between tasks, partition into waves using greedy graph coloring on the file-overlap graph:

1. Extract file paths per task (from plan `Files:` sections or task analysis)
2. Build undirected overlap graph: edge between tasks that share files
3. Assign waves greedily — for each task, assign to the earliest wave where it has no overlap with already-assigned tasks in that wave

```
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

**No overlaps (most common):**
```
All 5 tasks are independent — executing as a single wave.
```
No confirmation needed. Proceed immediately.

**Overlaps detected:**
```
File overlaps detected — proposing 2 waves:

  Wave 1: Task 1 (a.ts, b.ts), Task 2 (c.ts), Task 4 (e.ts)
  Wave 2: Task 3 (a.ts, d.ts), Task 5 (d.ts, e.ts)

  Overlaps: 1↔3 (a.ts), 3↔5 (d.ts), 4↔5 (e.ts)

Proceed with this wave plan? (or restructure)
```
Wait for user confirmation before proceeding.

---

## Phase 2: FAN OUT

Unchanged from v1. For each task in the current wave, dispatch a subagent with `isolation: "worktree"`.

### Implementer Prompt Enhancement

The subagent prompt adds a self-review step before reporting, adopted from superpowers' implementer protocol:

```
Agent tool:
  description: "Task N: <short description>"
  isolation: "worktree"
  prompt: |
    <full task text from plan>
    <project context: CLAUDE.md, relevant file contents>

    ## Self-Review Before Reporting

    Before reporting back, review your work:

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

    Capture your change ID and workspace name before reporting:
      jj log -r @ --no-graph -T 'change_id'
      basename "$PWD"

    Report:
    - Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
    - Change ID: <change_id>
    - Workspace directory: <basename>
    - Files changed (list paths)
    - Test results (if applicable)
    - Self-review findings (if any)
    - Any concerns
```

The escalation statuses (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT) are unchanged from v1 and match superpowers exactly.

**What's NOT adopted from superpowers:**
- Git commit step — in jj, the working copy IS the commit
- Git SHA references — change IDs throughout

---

## Phase 3: COLLECT

Classify results, capture change IDs and workspace names. In v1, workspaces survive COLLECT and are cleaned up during FAN IN (after each squash). In v2, cleanup is pulled earlier — to after REVIEW passes, before FAN IN — so that fix subagents can be dispatched into the still-existing workspace if spec review fails.

---

## Phase 4: REVIEW (new)

Inserted between COLLECT and FAN IN. Runs once per wave.

### Spec Reviewer Dispatch

For each DONE or DONE_WITH_CONCERNS task, dispatch a spec reviewer subagent. Spec reviewers run in the orchestrator's context (no `isolation: "worktree"`) — they are read-only, using `jj diff -r` and `jj file show -r` to inspect changes by change ID. All reviewers for the wave run in parallel and cannot conflict.

```
Agent tool:
  description: "Spec review: Task N"
  prompt: |
    You are reviewing whether an implementation matches its specification.

    ## What Was Requested

    <full task text from plan>

    ## What Implementer Claims

    <from implementer's status report>

    ## Do Not Trust the Report

    The implementer may be incomplete, inaccurate, or optimistic.
    Verify everything independently by reading the actual code.

    ## How to Read the Code

    This is a jj repository. The implementation lives in change <change-id>.

    jj diff -r <change-id>                    # see what changed
    jj file show -r <change-id> <path>        # read a file at that revision
    jj log -r <change-id> --stat              # summary of files touched

    Do NOT limit yourself to the diff. Read full files when context matters.

    ## Your Job

    Read the code and verify:

    - Missing requirements: anything requested but not implemented?
    - Extra work: anything built that wasn't requested?
    - Misunderstandings: right feature, wrong interpretation?

    Report:
    - PASS — spec compliant (cite evidence from code)
    - FAIL — issues found (file:line references, what's missing/extra/wrong)
```

**Design note:** Self-contained, jj-native prompt. Inspired by superpowers' `spec-reviewer-prompt.md` — same adversarial "don't trust the report" stance, same missing/extra/misunderstood categories. Adapted for jj: change IDs instead of SHA ranges, `jj diff -r` and `jj file show -r` instead of git commands.

### Fix Loop

When a spec reviewer returns FAIL:

1. Dispatch fix subagent **without** `isolation: "worktree"` (the workspace already exists — `isolation` would create a new one). Instead, tell the subagent to work in the existing workspace directory path (e.g., `.claude/workspaces/<task-name>/`) and provide the reviewer's specific findings
2. Fix subagent uses the same implementer protocol (DONE / BLOCKED / NEEDS_CONTEXT)
3. Re-dispatch spec reviewer for that task only
4. Repeat until PASS
5. Escalate to user after 2 failed attempts

Fix-induced file overlap changes for later waves are ignored. jj handles any resulting conflicts during fan-in. Rationale: the fix loop is the exception path, and recomputing waves adds complexity for a rare case that jj's conflict model handles gracefully.

### After All Tasks Pass

1. Clean up workspaces: `jj workspace forget workspace-<dir-name>`
2. Proceed to FAN IN

---

## Phase 5: FAN IN

Unchanged from v1. Squash completed tasks into `@`, smallest diff first (by files touched). Detect topology (auto-chained vs independent branches) and handle accordingly.

**Only spec-approved tasks are squashed.** Tasks that failed spec review and couldn't be fixed are preserved in their workspaces (same as v1's failure handling for BLOCKED tasks).

---

## Phase 6: VERIFY

Enhanced from v1. Now explicitly owns code quality review.

### Quality Review via /peer-review

`/peer-review` runs on the combined result of all waves. It sees the full merged diff — cross-task patterns (naming consistency, file growth, integration issues) are visible here that per-task review would miss.

If `/peer-review` finds quality issues, they are fixed in the default workspace on the combined result. No wave machinery needed at this point.

### Plan Coverage Report (enhanced)

```
Fan-flames complete (N/M tasks across W waves)

### Waves
- Wave 1: Tasks 1, 2, 4 — all passed spec review, merged
- Wave 2: Tasks 3, 5 — Task 3 passed, Task 5 blocked

### Plan Coverage
- X/Y requirements satisfied
- Z requirements blocked (Task 5: <reason>)

### Failed
- Task 5: <reason>
  Workspace: preserved (inspect with /workspace-list)
```

---

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--merge-order auto` | auto | Merge order within each wave: `auto` (smallest diff first) or explicit task list |
| `--skip-spec-review` | false | Skip per-task REVIEW phase (cleanup after COLLECT, straight to FAN IN) |
| `--skip-review` | false | Skip `/peer-review` in VERIFY (unchanged from v1) |

One new flag: `--skip-spec-review` controls the new per-task REVIEW phase. The existing `--skip-review` retains its v1 meaning (skip `/peer-review` in VERIFY). Both can be combined for maximum speed, no review at all.

---

## CLAUDE.md Override

The existing entry stays unchanged:

```markdown
| `subagent-driven-development` | `workspace-jj:fan-flames` | jj-native workspace isolation with reunification |
```

The override now routes to a fan-flames that has review gates, closing the gap that motivated the override.

---

## jj Features Leveraged

| jj Feature | How fan-flames v2 uses it |
|------------|--------------------------|
| Change IDs | Stable references through squash, rebase, fix loops. Reviewers, fixers, and fan-in all use the same ID. |
| First-class conflicts | Wave 2 can start even if wave 1 has unresolved conflicts. Fan-in doesn't block on conflicts. |
| Auto-rebase | Fixing a review issue in wave 1 automatically rebases wave 2's changes onto the fix. |
| `jj squash --from X --into Y` | Surgical fan-in — moves exactly one task's changes into `@`. |
| `jj diff -r <change-id>` | Spec reviewers read code without needing the workspace to exist. |
| `jj file show -r <change-id>` | Reviewers can read full files at any revision. |
| `jj parallelize` | Optional DAG reshaping in VERIFY for history readability. |
| `jj workspace add --revision` | Workspaces pinned to `@-` for independent branching. |
| `jj workspace forget` | Lightweight cleanup — just removes tracking, store is shared. |
| `jj duplicate -d` | One-shot cherry-pick when fix propagation needs a separate change. |
| Path-scoped `jj restore` | Partial fan-in: selectively restore files from a task's change. |

---

## Prerequisites

### Required

- **jj repository** — `jj root` succeeds
- **WorktreeCreate/WorktreeRemove hooks configured** — workspace-jj's hook scripts installed in `.claude/settings.local.json`

### Recommended

- **permission-gateway** — auto-approves safe commands for subagents, preserving parallelism benefit

### Prerequisite Improvement (separate effort)

The `/workspace-setup` command (workspace-jj plugin) that installs WorktreeCreate/WorktreeRemove hooks should fold into `/project-setup` (project-setup-jj plugin). Currently, `/project-setup` writes the CLAUDE.md override table referencing fan-flames, but fan-flames won't work without `/workspace-setup`. This creates a broken reference.

Recommended approach: project-setup copies all hook scripts (session-start, require-jj-new, workspace-create, workspace-remove) and configures all hooks in one command. workspace-jj keeps its skill (fan-flames) and commands (workspace-list), but setup consolidates. This is a setup UX concern — design separately.

---

## What This Spec Does NOT Cover

- **Changes to `/peer-review`** — peer-review-jj is already more capable than superpowers' code-quality-reviewer (multi-agent scaling, file partitioning, specialist dispatch). The structured severity taxonomy (Critical/Important/Minor) and "ready to merge?" verdict format from superpowers are worth borrowing in a future enhancement, but are not required for fan-flames v2.
- **CRDT integration** — jjp (Loro CRDT-augmented jj proxy) could enable true concurrent editing without workspace isolation. This is a future exploration that would fundamentally change the fan-out model, not an incremental addition.
- **project-setup consolidation** — noted as prerequisite improvement above, designed separately.

---

## Changes from v1

| Area | v1 | v2 |
|------|----|----|
| Phase structure | 5 phases, flat | 6 phases, wave loop |
| File overlap handling | Flag and ask | Automatic wave computation |
| Workspace cleanup | During FAN IN (after each squash) | After REVIEW passes (before FAN IN) |
| Spec review | None (peer-review at end only) | Per-task, parallel within wave |
| Implementer prompt | Status + change ID reporting | + self-review + escalation guidance |
| Quality review | `/peer-review` in VERIFY | Same (explicitly designated as quality gate) |
| Backward compat | N/A | `--skip-spec-review` skips per-task review (v1 behavior) |
