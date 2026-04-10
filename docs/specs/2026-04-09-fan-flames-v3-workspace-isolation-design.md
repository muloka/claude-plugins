# Fan-Flames v3: Workspace Isolation Fix

**Date:** 2026-04-09
**Status:** Approved
**Scope:** fan-flames skill only (no hook changes)

## Problem

Fan-flames dispatches subagents with `isolation: "worktree"`, which triggers two independent isolation mechanisms:

1. **Claude Code** creates a git-level worktree
2. **WorktreeCreate hook** creates a jj workspace at `/tmp/jj-workspaces/...`

The agent ends up in one or the other nondeterministically. Observed in a real run: within a single wave, Task 10 auto-chained into `@`'s ancestry (workspace isolation failed — Pattern C), while Tasks 3 and 5 landed correctly in independent branches (Pattern B). All three were dispatched identically.

**Root cause:** Dual isolation mechanisms. Claude Code's worktree and the jj workspace are at different paths. The agent's file resolution sometimes follows one, sometimes the other.

**Key signal:** `jj squash` returning "Nothing changed" is the fingerprint of Pattern C (edits leaked into `@`), not true Pattern A (organic auto-chaining).

## Solution

Remove `isolation: "worktree"` from FAN OUT dispatch. The orchestrator creates and manages jj workspaces directly. Agents are dispatched as regular (non-isolated) agents with instructions to `cd` to the workspace path.

This eliminates the dual mechanism entirely. The fix loop (Phase 4) already uses this pattern successfully — initial dispatch becomes consistent with fix dispatch.

## Changes

### 1. FAN OUT — Orchestrator-managed workspace creation

**Before:**
```
Agent tool:
  isolation: "worktree"
  prompt: <task>
```

**After:**
```
Before dispatch, orchestrator creates workspace:
  DIR="/tmp/jj-workspaces/$(basename $(jj root))/<task-name>"
  parent_rev=$(jj log -r '@-' --no-graph -T 'commit_id')
  jj workspace add "$DIR" --name "workspace-<task-name>" --revision "$parent_rev"

Agent tool:
  description: "Task N: <short description>"
  prompt: |
    ## Working Directory
    CRITICAL: Your first action MUST be: cd <workspace-path>
    ALL work happens in that directory. Do not operate in any other directory.
    Verify with: jj workspace list (confirm you're in workspace-<task-name>)
    
    <rest of task prompt unchanged>
```

Workspaces are pinned to `@-` (the parent revision), ensuring independent branches (Pattern B).

### 2. COLLECT — Integrity check promoted to primary gate

The existing integrity check (checking `jj diff -r @ --stat` for unexpected changes) is promoted from edge-case handler to the first validation step in COLLECT.

**Rationale:** Without `isolation: "worktree"`, agents rely on `cd` to reach their workspace. If an agent fails to `cd`, edits land in the default workspace's `@`. The integrity check catches this before review wastes cycles.

**Detection steps:**

1. Check default workspace `@` for leaked changes:
   ```bash
   jj diff -r @ --stat
   ```

2. For each agent, verify its change landed in the correct workspace:
   ```bash
   jj log -r 'workspace-<task-name>@' --no-graph -T 'change_id'
   ```
   Compare against the change ID the agent reported.

3. If mismatch detected, flag as `WORKSPACE_LEAK`:
   - Determine if changes are in `@` (recoverable) or lost
   - Report to user before proceeding

### 3. Workspace lifecycle — orchestrator owns full lifecycle

**Before:** Mixed ownership. WorktreeCreate hook creates. WorktreeRemove hook may fire prematurely when Claude Code cleans up its worktree. Fan-flames also cleans up manually after review.

**After:** Orchestrator owns create and destroy. Hooks are not involved.

```
Lifecycle per wave:

  PLAN:        nothing
  FAN OUT:     orchestrator creates workspaces via bash
  COLLECT:     orchestrator verifies integrity
               workspaces kept alive
  REVIEW:      workspaces kept alive (fix subagents dispatch to existing path)
               fix subagents: no isolation flag, cd to workspace path (unchanged)
  POST-REVIEW: orchestrator cleans up passed workspaces:
                 jj workspace forget workspace-<task-name>
                 rm -rf /tmp/jj-workspaces/<repo>/<task-name>
  FAN IN:      uses change IDs only (unchanged)
```

**Hook scripts are untouched.** They remain for non-fan-flames users who use `isolation: "worktree"` directly in a jj repo. Fan-flames simply doesn't trigger them because it doesn't use `isolation: "worktree"`.

### 4. Error handling — wave-end workspace sweep

After FAN IN (or after COLLECT if the wave is fully blocked), sweep all workspaces created this wave:

| Task status | Action |
|---|---|
| DONE and squashed | Already cleaned in POST-REVIEW (no-op) |
| BLOCKED or CRASHED | Report to user: "Workspace preserved for inspection: `<path>`". Default: keep (matches current behavior for failed tasks). |
| WORKSPACE_LEAK | Clean up (content is already in `@`): `jj workspace forget` + `rm -rf` |

**Principle:** Partial success is progress. Don't silently discard failed workspaces — the user decides. But don't leak workspace directories in `/tmp` either.

### 5. FAN IN — no changes

The FAN IN phase (Pattern A/B detection, squash logic) is unchanged. With orchestrator-managed workspaces pinned to `@-`, we should consistently get Pattern B (independent branches). The dual-topology detection stays as a safety net.

**Pattern C handling retained as safety net.** With no `isolation: "worktree"`, the worktree-resolution mechanism that caused Pattern C is eliminated. The integrity check in COLLECT (Section 2) is the new equivalent, catching `cd` failures instead. Pattern C code in FAN IN is not expected to trigger — it is retained for defense-in-depth, not because it represents a live code path.

## Files to modify

| File | Change |
|---|---|
| `plugins/workspace-jj/skills/fan-flames.md` | All changes described above |

No changes to hook scripts, no new files.

## What this does NOT change

- **Hook scripts** (`jj-workspace-create.sh`, `jj-workspace-remove.sh`) — untouched, still serve standalone `isolation: "worktree"` users
- **FAN IN squash logic** — unchanged, Pattern A/B detection stays
- **Fix loop dispatch** — already uses the no-isolation pattern, unchanged
- **Review phase** — unchanged
- **Wave computation** — unchanged
