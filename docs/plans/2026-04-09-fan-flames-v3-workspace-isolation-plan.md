# Fan-Flames v3: Workspace Isolation Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate nondeterministic workspace isolation in fan-flames by removing `isolation: "worktree"` and having the orchestrator manage jj workspaces directly.

**Architecture:** Single file change to the fan-flames skill. The orchestrator creates jj workspaces via bash before dispatch, agents `cd` into them, and the orchestrator cleans up after review. No hook changes.

**Tech Stack:** Markdown (skill file), bash (jj CLI commands)

**Spec:** `docs/specs/2026-04-09-fan-flames-v3-workspace-isolation-design.md`

---

### Task 1: Rewrite FAN OUT to use orchestrator-managed workspaces

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md:150-213`

- [ ] **Step 1: Replace the Phase 2 header and intro** (lines 150-152)

Replace:
```markdown
## Phase 2: FAN OUT 🪭 — Create Workspaces and Dispatch

For each task in the current wave, dispatch a subagent with workspace isolation:
```

With:
```markdown
## Phase 2: FAN OUT 🪭 — Create Workspaces and Dispatch

For each task in the current wave, the orchestrator creates a jj workspace and dispatches a subagent to work in it.

### Step 1: Create workspaces

Before dispatching any agents, create all workspaces for the wave:

```bash
# For each task in the wave:
DIR="/tmp/jj-workspaces/$(basename $(jj root))/<task-name>"
mkdir -p "$(dirname "$DIR")"
parent_rev=$(jj log -r '@-' --no-graph -T 'commit_id')
jj workspace add "$DIR" --name "workspace-<task-name>" --revision "$parent_rev"
```

All workspaces are pinned to `@-` (the parent revision), ensuring each creates an independent branch (Pattern B).

### Step 2: Dispatch agents

For each task, dispatch a subagent **without** `isolation: "worktree"`:
```

- [ ] **Step 2: Replace the agent dispatch template** (lines 154-206)

Replace the existing Agent tool block (lines 154-206) with:
```markdown
```
Agent tool:
  description: "Task N: <short description>"
  prompt: |
    ## Working Directory
    CRITICAL: Your first action MUST be:
      cd <workspace-path>
    ALL work happens in that directory. Do not operate in any other directory.
    Verify you are in the right workspace:
      jj workspace list
    Confirm you see workspace-<task-name> marked as the active workspace.

    <full task text from plan>

    <any project context needed: CLAUDE.md, relevant file contents, etc.>

    <if wave > 1, include prior wave context — see "Prior Wave Context" below>

    CRITICAL: You MUST NOT use ANY raw git commands — not even for context
    discovery. Always use jj equivalents (jj log, jj diff, jj status, etc.).
    The only exceptions are `jj git` subcommands and `gh` CLI.

    ## Self-Review Before Reporting

    Before reporting back, review your work with fresh eyes:

    - Completeness: did I implement everything in the spec?
    - Quality: are names clear, code maintainable?
    - Discipline: did I avoid overbuilding (YAGNI)?
    - Testing: do tests verify behavior, not just mock it?
    - Formatting: run the project's formatter/linter (e.g., cargo fmt, prettier, ruff) and fix any issues

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

- [ ] **Step 3: Replace the dispatch rules** (lines 208-213)

Replace:
```markdown
**Dispatch rules:**
- Dispatch all tasks in the current wave simultaneously (parallel, not sequential)
- Each subagent gets `isolation: "worktree"` — Claude Code creates a jj workspace via the WorktreeCreate hook
- Provide each subagent with the full task text, not a summary
- Include relevant project context (CLAUDE.md rules, key file contents)
- If the plan uses superpowers skills (TDD, code review), include those references in the subagent prompt
```

With:
```markdown
**Dispatch rules:**
- Create all workspaces first, then dispatch all agents simultaneously (parallel, not sequential)
- Agents are dispatched **without** `isolation: "worktree"` — the orchestrator manages jj workspaces directly
- Each agent's prompt begins with the `cd` + verify instructions for its workspace path
- Provide each subagent with the full task text, not a summary
- Include relevant project context (CLAUDE.md rules, key file contents)
- If the plan uses superpowers skills (TDD, code review), include those references in the subagent prompt
```

- [ ] **Step 4: Verify the edit**

Run: `grep -n "isolation" plugins/workspace-jj/skills/fan-flames.md`

Expected: Only the fix loop reference at ~line 335 should mention `isolation: "worktree"`. Lines 157 and 210 should be gone.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(fan-flames): replace isolation:worktree with orchestrator-managed workspaces in FAN OUT"
jj new
```

---

### Task 2: Promote integrity check to primary gate in COLLECT

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md:244-286`

- [ ] **Step 1: Replace the COLLECT intro** (lines 244-255)

Replace:
```markdown
## Phase 3: COLLECT — Classify Results

As subagents return, classify each result:

| Status | Action |
|--------|--------|
| DONE | Ready for fan-in |
| DONE_WITH_CONCERNS | Read concerns, decide if fan-in safe |
| NEEDS_CONTEXT | Provide context, re-dispatch |
| BLOCKED | Note failure, preserve workspace |

Track which tasks succeeded and which failed. **Capture the change ID and workspace directory name from each subagent's report** — change IDs are needed for fan-in squash, workspace names for cleanup.
```

With:
```markdown
## Phase 3: COLLECT — Classify Results

As subagents return, classify each result:

| Status | Action |
|--------|--------|
| DONE | Verify workspace integrity, then ready for fan-in |
| DONE_WITH_CONCERNS | Verify workspace integrity, read concerns, decide if fan-in safe |
| NEEDS_CONTEXT | Provide context, re-dispatch |
| BLOCKED | Note failure, track workspace for sweep |

Track which tasks succeeded and which failed. **Capture the change ID and workspace directory name from each subagent's report** — change IDs are needed for fan-in squash, workspace names for cleanup.
```

- [ ] **Step 2: Replace the Workspace Integrity Check section** (lines 257-272)

Replace:
```markdown
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
```

With:
```markdown
### Workspace Integrity Check (Primary Gate)

**This is the first validation step after agents return.** Without `isolation: "worktree"`, agents rely on `cd` to reach their workspace. If an agent fails to `cd`, edits land in the default workspace's `@`. The integrity check catches this before review wastes cycles.

**Step 1:** Check default workspace `@` for leaked changes:

```bash
jj diff -r @ --stat
```

If `@` shows unexpected changes, at least one agent failed to `cd` to its workspace.

**Step 2:** For each agent that reported DONE or DONE_WITH_CONCERNS, verify its change landed in the correct workspace:

```bash
# Check the workspace's working copy matches the reported change ID
jj log -r 'workspace-<task-name>@' --no-graph -T 'change_id'
```

Compare against the change ID the agent reported.

**Step 3:** If mismatch detected, flag as `WORKSPACE_LEAK`:
1. Report: "Workspace integrity failure — Task N's edits landed in the default workspace instead of workspace-<task-name>."
2. Determine if changes are in `@` (recoverable — skip squash for this task) or lost (treat as BLOCKED)
3. Report to user before proceeding to review

> **Safety net context:** This check replaces the former Pattern C edge case handler. Pattern C was caused by dual isolation mechanisms (`isolation: "worktree"` + jj workspace hook). With orchestrator-managed workspaces (v3), the root cause is eliminated. This check catches `cd` failures, which are the remaining risk vector.
```

- [ ] **Step 3: Replace the Workspace Lifecycle section** (lines 284-286)

Replace:
```markdown
### Workspace Lifecycle

In v1, workspaces survived COLLECT and were cleaned up during FAN IN (after each squash). In v2, **workspaces remain alive through the REVIEW phase** so that fix subagents can be dispatched into the original workspace if review fails. Cleanup happens after all tasks in the wave pass review, before FAN IN.
```

With:
```markdown
### Workspace Lifecycle

The orchestrator owns the full workspace lifecycle — no hooks are involved:

- **FAN OUT:** Orchestrator creates workspaces via `jj workspace add`
- **COLLECT:** Workspaces kept alive for integrity verification
- **REVIEW:** Workspaces kept alive so fix subagents can be dispatched to existing workspace paths
- **POST-REVIEW:** Orchestrator cleans up workspaces for tasks that passed review
- **FAN IN:** Uses change IDs only (workspaces already cleaned up)

Workspaces for failed/blocked tasks are handled by the wave-end sweep (see Phase 4).
```

- [ ] **Step 4: Verify the edit**

Run: `grep -n "WorktreeCreate hook\|WorktreeRemove hook\|edge case" plugins/workspace-jj/skills/fan-flames.md`

Expected: No references to hooks causing Pattern C. The "edge case" language should be gone from COLLECT.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(fan-flames): promote integrity check to primary gate in COLLECT, update lifecycle docs"
jj new
```

---

### Task 3: Add wave-end workspace sweep to REVIEW phase

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md:343-350`

- [ ] **Step 1: Replace the "After All Tasks in the Wave Pass" and "Skipping Review" sections** (lines 343-350)

Replace:
```markdown
### After All Tasks in the Wave Pass

1. Clean up workspaces: `jj workspace forget workspace-<dir-name>` for each task
2. Proceed to FAN IN

### Skipping Review

When `--skip-review` is set, this entire phase is skipped. Workspaces are cleaned up immediately after COLLECT, and all DONE/DONE_WITH_CONCERNS tasks proceed directly to FAN IN.
```

With:
```markdown
### After All Tasks in the Wave Pass

1. Clean up workspaces for passed tasks:
   ```bash
   jj workspace forget workspace-<task-name>
   rm -rf /tmp/jj-workspaces/<repo>/<task-name>
   ```
2. Proceed to FAN IN

### Wave-End Workspace Sweep

After FAN IN completes (or after COLLECT if the wave is fully blocked), sweep all workspaces created this wave to prevent leaking directories in `/tmp`:

| Task status | Action |
|---|---|
| DONE and squashed | Already cleaned in POST-REVIEW (no-op) |
| BLOCKED or CRASHED | Default: preserve workspace for inspection. Report: "Workspace preserved: `/tmp/jj-workspaces/<repo>/<task-name>`" |
| WORKSPACE_LEAK | Clean up (content is already in `@`): `jj workspace forget workspace-<task-name>` + `rm -rf` |

Partial success is progress — don't silently discard failed workspaces. The user can inspect and manually clean up later.

### Skipping Review

When `--skip-review` is set, the review phase is skipped. Workspaces are cleaned up immediately after COLLECT, and all DONE/DONE_WITH_CONCERNS tasks proceed directly to FAN IN. The wave-end sweep still runs after FAN IN.
```

- [ ] **Step 2: Verify the edit**

Run: `grep -n "sweep\|WORKSPACE_LEAK\|CRASHED" plugins/workspace-jj/skills/fan-flames.md`

Expected: New sweep section visible with all three status handlers.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(fan-flames): add wave-end workspace sweep for orphaned workspaces"
jj new
```

---

### Task 4: Add Pattern C safety net comment in FAN IN

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md:356-365`

- [ ] **Step 1: Update the FAN IN topology intro** (lines 356-365)

Replace:
```markdown
jj workspaces share a single DAG. Concurrent subagents may produce two different
topologies depending on timing and jj's working-copy snapshot mechanism:

**Pattern A: Auto-chained** — Subagents see each other's commits and chain linearly.
The default workspace's `@` already sits on top of all changes. Content is merged.

**Pattern B: Independent branches** — Each subagent created a change off the shared
parent. Changes need to be squashed into `@`.

Both patterns produce correct content. Detect which occurred, then handle accordingly.
```

With:
```markdown
jj workspaces share a single DAG. With orchestrator-managed workspaces pinned to `@-`,
subagents should consistently produce **Pattern B** (independent branches). The
dual-topology detection below is retained as a safety net.

**Pattern A: Auto-chained** — Subagents see each other's commits and chain linearly.
The default workspace's `@` already sits on top of all changes. Content is merged.

> **Safety net (v3):** With orchestrator-managed workspaces pinned to `@-`, Pattern A
> is not expected to occur. It is retained for defense-in-depth. If Pattern A is
> detected, it is handled correctly — no squash needed.

**Pattern B: Independent branches (expected)** — Each subagent created a change off the
shared parent. Changes need to be squashed into `@`.

Both patterns produce correct content. Detect which occurred, then handle accordingly.
```

- [ ] **Step 2: Update the "Why change IDs" section** (lines 463-468)

Replace:
```markdown
Each subagent reports its change ID before returning. We use these IDs instead of
`workspace-<name>@` revsets because Claude Code may fire the WorktreeRemove hook
(which calls `jj workspace forget`) when a subagent finishes, before the orchestrator
runs fan-in. Change IDs are stable regardless of workspace lifecycle.
```

With:
```markdown
Each subagent reports its change ID before returning. We use these IDs instead of
`workspace-<name>@` revsets because workspaces are cleaned up after review but
before fan-in. Change IDs are stable regardless of workspace lifecycle.
```

- [ ] **Step 3: Verify the edit**

Run: `grep -n "safety net\|Safety net\|defense-in-depth\|WorktreeRemove" plugins/workspace-jj/skills/fan-flames.md`

Expected: Two "safety net" references (FAN IN intro and Pattern A note). No "WorktreeRemove" references.

- [ ] **Step 4: Commit**

```bash
jj describe -m "docs(fan-flames): add safety net annotations to Pattern A/C in FAN IN"
jj new
```

---

### Task 5: Final verification pass

**Files:**
- Read: `plugins/workspace-jj/skills/fan-flames.md` (full file)

- [ ] **Step 1: Verify no stale references to `isolation: "worktree"` in dispatch**

Run: `grep -n "isolation" plugins/workspace-jj/skills/fan-flames.md`

Expected: Only the fix loop reference (~line 335) should mention `isolation: "worktree"`. That line says "Dispatch fix subagent **without** `isolation: "worktree"`" — this is correct documentation, not a dispatch instruction.

- [ ] **Step 2: Verify no stale hook references in COLLECT/FAN OUT**

Run: `grep -n "WorktreeCreate\|WorktreeRemove\|hook creates\|hook fires" plugins/workspace-jj/skills/fan-flames.md`

Expected: No matches in Phases 2-5. References may remain in prerequisites (line ~69) where the skill checks that hooks are configured — that's fine (hooks still exist for other users).

- [ ] **Step 3: Read the full file and verify flow coherence**

Read the complete `fan-flames.md` and verify:
- Phase 2 creates workspaces before dispatch, no `isolation: "worktree"`
- Phase 3 runs integrity check as first validation step
- Phase 4 cleans up passed workspaces, sweep handles the rest
- Phase 5 expects Pattern B, has safety net comments for Pattern A
- No contradictions between sections

- [ ] **Step 4: Commit final state (if any fixups needed)**

```bash
jj describe -m "chore(fan-flames): final verification pass for v3 workspace isolation"
jj new
```
