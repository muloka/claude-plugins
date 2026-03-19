---
name: fan-flames
description: |
  Orchestrate parallel subagent execution across isolated jj workspaces, then
  reunify results into a single change. Use when the user asks to "fan out tasks",
  "run tasks in parallel with isolation", "dispatch subagents for independent tasks",
  or when subagent-driven-development routes here via CLAUDE.md override in a jj repo.
---

# Fan-Flames: Parallel Workspace Orchestration

Orchestrate parallel subagent execution across isolated jj workspaces, then reunify
results into a single change. The jj-native equivalent of running multiple developers
on separate branches and merging.

**Announce at start:** "I'm using the fan-flames skill to orchestrate parallel workspace execution."

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

## Phase 1: PLAN — Validate Independence

Before fanning out, validate that tasks can run in parallel:

1. Extract the file paths each task will touch (from the plan's `Files:` sections or by analyzing task descriptions)
2. Build a file → task mapping
3. If any file appears in multiple tasks, **flag it immediately**:

```
⚠️ File overlap detected:
  src/api/handler.ts → Task 2, Task 4

These tasks may conflict. Options:
  a) Proceed anyway (jj handles conflicts, resolve during fan-in)
  b) Restructure tasks to eliminate overlap
  c) Run overlapping tasks sequentially, others in parallel
```

Wait for user decision before proceeding.

4. **Recommend** 3-5 concurrent workspaces for most tasks. Note the recommendation to the user but do not block dispatch if more are requested.

## Phase 2: FAN OUT 🪭 — Create Workspaces and Dispatch

For each task, dispatch a subagent with workspace isolation:

```
Agent tool:
  description: "Task N: <short description>"
  isolation: "worktree"
  prompt: |
    <full task text from plan>

    <any project context needed: CLAUDE.md, relevant file contents, etc.>

    IMPORTANT: Before reporting back, capture your change ID:
    jj log -r @ --no-graph -T 'change_id'

    When done, report:
    - Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
    - Change ID: <the change_id from above>
    - Files changed (list paths)
    - Test results (if applicable)
    - Any concerns
```

**Dispatch rules:**
- Dispatch ALL independent tasks simultaneously (parallel, not sequential)
- Each subagent gets `isolation: "worktree"` — Claude Code creates a jj workspace via the WorktreeCreate hook
- Provide each subagent with the full task text, not a summary
- Include relevant project context (CLAUDE.md rules, key file contents)
- If the plan uses superpowers skills (TDD, code review), include those references in the subagent prompt

**Progress tracking:**
- After dispatch, report how many subagents are running:

```
🪭 Fan-out: 3 tasks dispatched to isolated workspaces
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

Track which tasks succeeded and which failed. **Capture the change ID from each subagent's report** — these are needed for fan-in.

## Phase 4: FAN IN 🔥 — Reunify Changes

**Why change IDs, not workspace revsets:** Each subagent reports its change ID before returning. We use these IDs for squash instead of `workspace-<name>@` revsets because Claude Code may fire the WorktreeRemove hook (which calls `jj workspace forget`) when a subagent finishes, before the orchestrator runs fan-in. Change IDs are stable regardless of workspace lifecycle.

**Merge order:** Sort completed tasks by files touched (ascending). Smallest diff first — fewer files touched means lower conflict surface area. This establishes a stable base early.

If the user specified `--merge-order`, use their explicit ordering instead.

**To count files touched per task:**

```bash
jj diff -r <change-id> --stat | tail -1
```

**Before fan-in, verify orchestrator is in the default workspace:**

```bash
jj workspace list  # default workspace should be marked
```

**For each completed task, in order:**

1. **Squash into the default workspace using the change ID:**

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

3. **Clean up the workspace (if it still exists):**

```bash
# May already be cleaned up by WorktreeRemove hook — that's fine
jj workspace forget workspace-<task-name> 2>/dev/null || true
```

**For each failed task:**
- Do NOT squash or forget — preserve workspace for inspection
- Report the failure and workspace name

## Phase 5: VERIFY — Review and Report

After all fan-in is complete:

1. **Run peer review** on the combined result:

```
/peer-review
```

2. **Report plan coverage:**

**If plan-based:**

```
🪭🔥 Fan-flames complete (N/M tasks)

### Merged
- 🔥 Task 1: "Add validation middleware" — squashed into @
- 🔥 Task 3: "Update API types" — squashed into @

### Failed
- Task 2: "Migrate auth store" — <failure reason>
  Workspace: workspace-task-2 (preserved, inspect with /workspace-list)

### Plan Coverage
- X/Y plan requirements satisfied by merged tasks
- Z requirements blocked by failed tasks
```

**If ad-hoc:**

```
🪭🔥 Fan-flames complete (N/M tasks)

### Merged
- 🔥 "Add validation middleware" — squashed into @
- 🔥 "Update API types" — squashed into @

### Failed
- "Migrate auth store" — <failure reason>
  Workspace preserved for inspection
```

## Conflict Handling Reference

jj's conflict model is first-class — conflicts are recorded in the tree, not blocking.

- Conflicts after a squash don't prevent further squashes
- But compounding conflicts become harder to reason about
- Smallest-diff-first ordering minimizes conflict cascading
- Use `jj resolve --list` to see conflicted files
- Use `jj resolve <file>` to resolve interactively

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--merge-order auto` | auto | Merge order: `auto` (smallest diff first) or explicit task list |
| `--skip-review` | false | Skip `/peer-review` after fan-in |

## Key Principles

- **Delegate dispatch** — don't reimplement superpowers' agent patterns
- **jj-specific bookends only** — workspace create, squash, forget, conflict handling
- **Partial success is progress** — merge what succeeded, preserve what failed
- **Smallest diff first** — minimize conflict surface during fan-in
- **Permission-gateway underneath** — subagents run autonomously when installed
