# Workspace Plugin (jj)

Wave-based parallel orchestration with spec review gates for jj (Jujutsu) repositories.

## Overview

Provides the **kaisen** skill — a parallel task orchestrator that dispatches subagents to isolated jj workspaces, gates each wave with a test + peer review pass, then reunifies results into a single change. The jj-native replacement for superpowers' `subagent-driven-development`. Workspace hooks are installed by `/project-setup` from the [project-setup-jj](../project-setup-jj) plugin.

## How It Works

- **WorktreeCreate**: Runs `jj workspace add --revision @-` to create an isolated workspace at `/tmp/jj-workspaces/<project>/<name>/`, pinned to the parent revision for independent branching. Workspaces are created outside the repo to prevent jj's auto-snapshotting from attributing workspace edits to the default workspace's `@`.
- **WorktreeRemove**: Runs `jj workspace forget` and removes the directory on cleanup

Workspaces share the same repository store (lightweight, fast to create) but each gets an independent working copy pinned to the same parent revision.

## Installation

```bash
claude plugins add muloka/claude-plugins:workspace-jj
```

## Setup

Workspace hooks are installed automatically by `/project-setup` from the [project-setup-jj](../project-setup-jj) plugin. No separate setup step needed.

## Commands

| Command | Description |
|---------|-------------|
| `/kaisen [plan-file] [--skip-review] [--merge-order auto\|task-1,task-2,...]` | Execute a plan using wave-based parallel orchestration with spec review gates |
| `/workspace-list` | List all jj workspaces with JSON output |

## Usage

```bash
# Start Claude in an isolated jj workspace
claude --worktree feature-auth

# Auto-generated name
claude --worktree

# List all workspaces
/workspace-list
```

## Side Threads: Which Door to Use

| Situation | Use | Ceremony |
|-----------|-----|----------|
| New terminal tab, ephemeral thread | `claude --worktree <name>` from the main checkout | one command — the WorktreeCreate hook makes the jj workspace (in `/tmp`, pinned to `@-`) and the session starts inside it |
| New terminal tab, durable thread | `jjtab <name> [revset]` shell function (below) | one command — sibling directory next to the repo, survives reboots, custom base revset |
| Already inside a session | ask Claude to enter a worktree (native `EnterWorktree` → same hook) | zero |
| Parallel agent execution of a plan | `/kaisen` | the skill orchestrates workspaces itself |

Each workspace has its own working copy (`@`), so tabs never affect each other; all changes remain visible in the shared `jj log` from anywhere. One rule: never `jj edit` (or otherwise rewrite) a change that another workspace has checked out as its `@` — that creates a divergent change (`change_id??`, two commits for one change). Recover by abandoning the unwanted commit by its commit ID.

The `jjtab` function for your shell config:

```bash
# jjtab NAME [REVSET] — jj workspace as a sibling dir + launch claude in it.
# Default base: parents of the current @. e.g.: jjtab hotfix 'trunk()'
jjtab() {
  local name=${1:?usage: jjtab NAME [REVSET]}
  local rev=${2:-'@-'}
  local dir="../$(basename "$PWD")-$name"
  jj workspace add "$dir" --name "$name" --revision "$rev" || return
  cd "$dir" && claude
}
```

Finish a side thread with `/finish` in-session, or manually: `jj workspace forget <name>` from the main checkout, then remove the directory.

## Requirements

- [jj (Jujutsu)](https://martinvonz.github.io/jj/) must be installed
- [jq](https://jqlang.github.io/jq/) must be installed (for JSON parsing in hooks)

## Cleanup

Workspaces are cleaned up automatically when you exit a session and choose to remove the worktree. For manual cleanup of stale workspaces, use the `/clean_stale` command from the [commit-commands-jj](../commit-commands-jj) plugin.

## Kaisen Skill

Wave-based parallel workspace orchestration — fan out tasks to isolated jj workspaces, gate each wave on a test + peer review pass, then fan in the review-approved results.

```
PLAN → per wave: 🪭 Fan out → Collect → Review (test + peer review) → 🔥 Fan in → next wave or report
```

**Usage:** Triggered automatically when `subagent-driven-development` runs in a jj repo, or directly:

- "Fan out these 3 tasks into parallel workspaces"
- "Run these tasks in parallel with isolation"
- "Dispatch subagents for these independent tasks"

**Dual-topology handling:** jj workspaces share a single DAG. Concurrent subagents may auto-chain (building on each other's commits) or create independent branches. Kaisen detects which pattern occurred and handles both:

- **Auto-chained:** Content already merged — skip squash, optionally `jj parallelize` for clean history
- **Independent branches:** Squash each into `@`, smallest diff first (by files touched)

Override merge order with `--merge-order task-3,task-1,task-2`. Skip the REVIEW phase (cleanup straight to FAN IN, no test + peer review) with `--skip-review`.

**Failure handling:** Partial success is preserved. Failed workspaces stay alive for inspection via `/workspace-list`.

**Change-ID based fan-in:** Subagents report their change ID and workspace directory name (`basename $PWD`) before returning. Fan-in uses change IDs (not workspace revsets) because the orchestrator cleans up workspaces after review, before it runs squash.

See [design spec](../../docs/specs/2026-07-15-kaisen-rename-and-collision-design.md) for full details.

## Author

[muloka](https://github.com/muloka)
