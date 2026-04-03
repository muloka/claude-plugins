---
description: "Execute a plan using wave-based parallel orchestration with spec review gates"
argument-hint: "[plan-file] [--skip-spec-review] [--skip-review] [--merge-order auto|task-1,task-2,...]"
allowed-tools: Agent, Bash, Read, Write, Edit, Glob, Grep, Skill
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents (jj log, jj diff, jj status, etc.). The only exceptions are `jj git` subcommands and `gh` CLI.**

**When spawning sub-agents, you MUST include this directive in every agent prompt: "CRITICAL: You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents (jj log, jj diff, jj status, etc.). The only exceptions are `jj git` subcommands and `gh` CLI."**

# Fan-Flames: Parallel Workspace Orchestration

Orchestrate parallel subagent execution across isolated jj workspaces with
wave-based scheduling and per-task spec review gates, then reunify results
into a single change. The jj-native replacement for superpowers' subagent-driven-development.

**Announce at start:** "I'm using fan-flames to orchestrate parallel workspace execution."

## Input

Parse `$ARGUMENTS` to extract:
- **plan-file**: Path to a plan document with numbered tasks. If provided, read it and extract all tasks.
- **--skip-spec-review**: Skip per-task REVIEW phase
- **--skip-review**: Skip `/peer-review` in VERIFY
- **--merge-order**: `auto` (default, smallest diff first) or explicit task order

If no plan file given, ask the user for a plan document or ad-hoc task list.

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

## Prerequisites

Before starting, verify:

1. **jj repo** — confirm this is a jj repository (`jj root` succeeds)
2. **workspace-jj installed** — confirm WorktreeCreate hooks are configured (`.claude/settings.local.json` has WorktreeCreate hooks)
3. **Clean working copy** — current change should have a description and be a sensible parent for the parallel work

If any prerequisite fails, explain what's missing and how to fix it.

## Phase 1: PLAN — Validate Independence and Compute Waves

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

**No overlaps:** "All N tasks are independent — executing as a single wave." Proceed immediately.

**Overlaps detected:** Present wave plan, wait for user confirmation.

### Parallelism Threshold

After computing waves, calculate the parallelism ratio: tasks in the largest wave / total tasks. If less than 40% of tasks can run in parallel (e.g., 2 of 9 tasks in the largest wave), warn the user:

```
⚠️ Low parallelism: only N/M tasks can run in parallel (largest wave: W tasks).
File overlaps make most tasks sequential. The overhead of workspace setup,
spec review, and squash ceremony may exceed the time saved.

Options:
  a) Proceed with fan-flames anyway
  b) Switch to single-agent sequential execution (superpowers:executing-plans)
```

Wait for user decision.

5. **Recommend** 3-5 concurrent workspaces per wave.

## Phase 2: FAN OUT 🪭 — Dispatch

For each task in the current wave, dispatch a subagent with workspace isolation:

```
Agent tool:
  description: "Task N: <short description>"
  isolation: "worktree"
  prompt: |
    <full task text from plan>
    <project context: CLAUDE.md, relevant file contents>

    CRITICAL: You MUST NOT use ANY raw git commands. Always use jj equivalents.

    ## Self-Review Before Reporting
    Before reporting back, review your work:
    - Completeness: did I implement everything in the spec?
    - Quality: are names clear, code maintainable?
    - Discipline: did I avoid overbuilding (YAGNI)?
    - Testing: do tests verify behavior, not just mock it?
    If you find issues, fix them now before reporting.

    ## When You're in Over Your Head
    It is always OK to stop and say "this is too hard for me."
    STOP and escalate when:
    - The task requires architectural decisions with multiple valid approaches
    - You need to understand code beyond what was provided
    - You feel uncertain about your approach

    ## Reporting
    IMPORTANT: Before reporting back, capture your change ID and workspace name:
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

**Dispatch rules:**
- Dispatch all tasks in the current wave simultaneously (parallel, not sequential)
- Each subagent gets `isolation: "worktree"` — Claude Code creates a jj workspace via the WorktreeCreate hook
- Provide each subagent with the full task text, not a summary
- Include relevant project context (CLAUDE.md rules, key file contents)

## Phase 3: COLLECT — Classify Results

| Status | Action |
|--------|--------|
| DONE | Ready for review |
| DONE_WITH_CONCERNS | Read concerns, decide if review safe |
| NEEDS_CONTEXT | Provide context, re-dispatch |
| BLOCKED | Note failure, preserve workspace |

**Capture the change ID and workspace directory name from each subagent's report.**

**Workspaces remain alive** through the REVIEW phase so fix subagents can be dispatched if spec review fails.

### Workspace Integrity Check

After collecting results, verify each subagent's changes actually landed in its workspace, not in the default workspace's `@`:

```bash
# Check if default workspace @ has unexpected changes
jj diff -r @ --stat
```

If the default workspace's `@` shows changes that belong to a subagent task, workspace isolation failed (**Pattern C**). Handle by:
1. Report the issue: "Workspace isolation failure — Task N's edits landed in the default workspace instead of its workspace."
2. Skip squash for that task (changes are already in `@`)
3. Verify the content is correct by diffing against the task spec
4. Continue with remaining tasks normally

This is a known edge case — the WorktreeCreate hook creates the jj workspace, but the agent may resolve file paths to the main repo instead of the workspace copy.

### Recovery: Missing Change IDs

```bash
jj log -r 'description("Task N: <short description>")' --no-graph -T 'change_id'
```

## Phase 4: REVIEW — Spec Compliance Gates

**Skip this phase if `--skip-spec-review` is set.** Clean up workspaces and proceed to FAN IN.

### Tiered Review

Not all tasks need a full reviewer agent. Before dispatching, assess each task's complexity:

**Trivial tasks** (< 10 lines changed, no logic/control flow changes — e.g., visibility modifiers, import reordering, renaming): Verify inline by reading the diff yourself. Report: "Task N: trivial change (N lines), verified inline — PASS." No reviewer agent needed.

**Non-trivial tasks** (logic changes, new functions, structural modifications): Dispatch a spec reviewer subagent as below.

### Spec Reviewer Dispatch

For each non-trivial DONE/DONE_WITH_CONCERNS task, dispatch a spec reviewer subagent (read-only, no isolation needed). All reviewers run in parallel.

Read the spec reviewer template at: `plugins/workspace-jj/skills/fan-flames-spec-reviewer.md`

Use that template to construct each reviewer prompt. Fill in:
- `[FULL TEXT of task requirements from plan]` — the complete task text
- `[From implementer's status report]` — the implementer's report
- `[CHANGE_ID]` — the jj change ID from the implementer

### Fix Loop

When a reviewer returns FAIL:
1. Dispatch fix subagent **without** `isolation: "worktree"` — tell it to work in the existing workspace directory
2. Fix subagent uses same protocol (DONE / BLOCKED / NEEDS_CONTEXT)
3. Re-dispatch spec reviewer for that task only
4. Repeat until PASS. Escalate to user after 2 failed attempts.

### After All Tasks Pass

1. Clean up workspaces: `jj workspace forget workspace-<dir-name>`
2. Proceed to FAN IN

## Phase 5: FAN IN 🔥 — Reunify

**Only spec-approved tasks are squashed.**

### Detect topology

```bash
# If all change IDs are in @'s ancestry → Pattern A (auto-chained, no squash needed)
jj log -r 'ancestors(@) & (<change-id-1> | <change-id-2>)' --no-graph -T 'change_id ++ "\n"'
```

### Pattern A: Auto-chained — content already merged. Optionally `jj parallelize` for clean history.

### Pattern B: Independent branches — squash each into @, smallest diff first:

```bash
JJ_EDITOR=true jj squash --from <change-id> --into @
jj resolve --list  # check for conflicts
```

**For failed tasks:** Do NOT squash — preserve workspace for inspection.

## Phase 6: VERIFY — Review and Report

**Skip `/peer-review` if `--skip-review` is set.**

1. Run `/peer-review` on the combined result
2. Report plan coverage:

```
🪭🔥 Fan-flames complete (N/M tasks across W waves)

### Waves
- Wave 1: Tasks 1, 2, 4 — all passed spec review, merged
- Wave 2: Tasks 3, 5 — Task 3 passed, Task 5 blocked

### Plan Coverage
- X/Y requirements satisfied
- Z requirements blocked

### Failed
- Task 5: <reason>
  Workspace preserved (inspect with /workspace-list)
```
