---
name: fan-flames
description: |
  Orchestrate parallel subagent execution across isolated jj workspaces with
  wave-based scheduling and per-task spec review gates, then reunify results
  into a single change. Use when the user asks to "fan out tasks", "run tasks
  in parallel with isolation", "dispatch subagents for independent tasks",
  or when subagent-driven-development routes here via CLAUDE.md override in a jj repo.
---

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

## Prerequisites

Before starting, verify:

1. **jj repo** — confirm this is a jj repository (`jj root` succeeds)
2. **workspace-jj installed** — confirm WorktreeCreate hooks are configured (`/workspace-list` works or `.claude/settings.local.json` has WorktreeCreate hooks)
3. **Clean working copy** — current change should have a description and be a sensible parent for the parallel work

If any prerequisite fails, explain what's missing and how to fix it.

## Input

The user provides one of:

**A) Plan document reference** — path to a plan file with numbered tasks
**B) Ad-hoc task list** — inline list of independent task descriptions

If given a plan document, read it and extract all tasks with their full text.

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

## Phase 2: FAN OUT 🪭 — Create Workspaces and Dispatch

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

**Dispatch rules:**
- Dispatch all tasks in the current wave simultaneously (parallel, not sequential)
- Each subagent gets `isolation: "worktree"` — Claude Code creates a jj workspace via the WorktreeCreate hook
- Provide each subagent with the full task text, not a summary
- Include relevant project context (CLAUDE.md rules, key file contents)
- If the plan uses superpowers skills (TDD, code review), include those references in the subagent prompt

**Progress tracking:**
- After dispatch, report how many subagents are running:

```
🪭 Fan-out: Wave W — 3 tasks dispatched to isolated workspaces
  🔥 Task 1: "Add validation middleware"
  🔥 Task 2: "Migrate auth store"
  🔥 Task 3: "Update API types"

Waiting for all subagents to return...
```

## Phase 3: COLLECT — Classify Results

As subagents return, classify each result:

| Status | Action |
|--------|--------|
| DONE | Ready for fan-in |
| DONE_WITH_CONCERNS | Read concerns, decide if fan-in safe |
| NEEDS_CONTEXT | Provide context, re-dispatch |
| BLOCKED | Note failure, preserve workspace |

Track which tasks succeeded and which failed. **Capture the change ID and workspace directory name from each subagent's report** — change IDs are needed for fan-in squash, workspace names for cleanup.

### Recovery: Missing Change IDs

If a subagent crashes or times out before reporting its change ID, the change still exists in jj's DAG — it's just not referenced. Recover it by searching for the task description:

```bash
jj log -r 'description("Task N: <short description>")' --no-graph -T 'change_id'
```

If multiple matches, use the most recent. If no matches, the subagent likely never created any changes — treat as BLOCKED.

### Workspace Lifecycle

In v1, workspaces survived COLLECT and were cleaned up during FAN IN (after each squash). In v2, **workspaces remain alive through the REVIEW phase** so that fix subagents can be dispatched into the original workspace if spec review fails. Cleanup happens after all tasks in the wave pass spec review, before FAN IN.

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

## Phase 5: FAN IN 🔥 — Reunify Changes

**Only spec-approved tasks are squashed.** Tasks that failed spec review and couldn't be fixed are preserved in their workspaces — same handling as BLOCKED tasks.

jj workspaces share a single DAG. Concurrent subagents may produce two different
topologies depending on timing and jj's working-copy snapshot mechanism:

**Pattern A: Auto-chained** — Subagents see each other's commits and chain linearly.
The default workspace's `@` already sits on top of all changes. Content is merged.

**Pattern B: Independent branches** — Each subagent created a change off the shared
parent. Changes need to be squashed into `@`.

Both patterns produce correct content. Detect which occurred, then handle accordingly.

### Step 1: Detect topology

```bash
jj log -r '<change-id-1> | <change-id-2> | <change-id-3>' --no-graph -T 'change_id ++ " " ++ parents.map(|p| p.change_id()).join(",") ++ "\n"'
```

Check: do all change IDs share the same parent? If yes → Pattern B (independent branches).
If changes are ancestors of each other → Pattern A (auto-chained).

Simpler heuristic: check if the default workspace's `@` is already a descendant of all change IDs:

```bash
# If this returns all change IDs, they're already in @'s ancestry — Pattern A
jj log -r 'ancestors(@) & (<change-id-1> | <change-id-2> | <change-id-3>)' --no-graph -T 'change_id ++ "\n"'
```

### Step 2a: Pattern A — Auto-chained (content already merged)

If all changes are already in `@`'s ancestry, fan-in is free. No squash needed.

1. **Verify content:** Spot-check that expected files exist in the working copy
2. **Optionally reshape the DAG** with `jj parallelize` if a clean fan-out/fan-in
   diamond shape is preferred for history readability:

```bash
jj parallelize <change-id-1>::<change-id-N>
```

This retroactively converts the chain into siblings off the shared parent.
Only do this if the user cares about history topology — content is identical either way.

### Step 2b: Pattern B — Independent branches (squash needed)

If changes are independent siblings, squash each into `@`.

**Merge order:** Sort by files touched (ascending). Smallest diff first — fewer files
touched means lower conflict surface area.

If the user specified `--merge-order`, use their explicit ordering instead.

```bash
# Count files touched per task
jj diff -r <change-id> --stat | tail -1
```

**Before fan-in, verify orchestrator is in the default workspace:**

```bash
jj workspace list  # default workspace should be marked
```

**For each completed task, in order:**

1. **Squash into the default workspace:**

```bash
jj squash --from <change-id> --into @
```

2. **Check for conflicts:**

```bash
jj resolve --list
```

If conflicts exist:
- Report them clearly with file paths
- Ask user: resolve now, skip this task, or abandon the merge
- If user wants to resolve: use `jj resolve` to handle each conflict

### Why change IDs, not workspace revsets

Each subagent reports its change ID before returning. We use these IDs instead of
`workspace-<name>@` revsets because Claude Code may fire the WorktreeRemove hook
(which calls `jj workspace forget`) when a subagent finishes, before the orchestrator
runs fan-in. Change IDs are stable regardless of workspace lifecycle.

**For each failed task:**
- Do NOT squash or forget — preserve workspace for inspection
- Report the failure and workspace name

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

When `--skip-review` is set, skip `/peer-review` and proceed directly to the plan coverage report.

## Conflict Handling Reference

jj's conflict model is first-class — conflicts are recorded in the tree, not blocking.

- Conflicts after a squash don't prevent further squashes
- But compounding conflicts become harder to reason about
- Smallest-diff-first ordering minimizes conflict cascading
- Use `jj resolve --list` to see conflicted files
- Use `jj resolve <file>` to resolve interactively

## DAG Topology Reference

jj provides tools to reshape history after the fact:

- **`jj parallelize A::D`** — converts a chain A→B→C→D into siblings off A's parent
- **`jj new A B C`** — creates a merge commit with multiple parents
- **`jj rebase -r C -A B`** — moves changes between branches
- **`jj absorb`** — redistributes changes from a merge commit back into parent branches

The chain-first approach is strictly more flexible — you can always reshape later
but can't un-parallelize without squashing. Content is what matters; topology is presentation.

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--merge-order auto` | auto | Merge order within each wave: `auto` (smallest diff first) or explicit task list |
| `--skip-spec-review` | false | Skip per-task REVIEW phase (cleanup after COLLECT, straight to FAN IN) |
| `--skip-review` | false | Skip `/peer-review` in VERIFY |

## Key Principles

- **Delegate dispatch** — don't reimplement superpowers' agent patterns
- **jj-specific bookends only** — workspace create, squash, forget, conflict handling
- **Partial success is progress** — merge what succeeded, preserve what failed
- **Smallest diff first** — minimize conflict surface during fan-in
- **Permission-gateway underneath** — subagents run autonomously when installed
