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

## Serial SDD: shims for the superpowers scripts

Kaisen is for plans whose tasks are independent. A **serial** plan — tasks strictly ordered, or repeatedly touching the same files — gets nothing from waves of one task each, so the right tool there is superpowers' own `subagent-driven-development`, run in the default workspace.

Two of that skill's helper scripts shell out to `git` and are denied by `block-raw-git.sh`, the PreToolUse hook project-setup-jj registers in its plugin manifest — so it fires in every jj repo where the plugin is enabled, not through per-project settings anyone can toggle. These are drop-in replacements:

| Superpowers script | Replacement | What changes |
|---|---|---|
| `scripts/sdd-workspace` | `scripts/sdd-artifacts` | `jj root` replaces `git rev-parse --show-toplevel`. Same argv, same stdout, same `.superpowers/sdd/<plan>/` layout — a plan mid-flight can switch without moving an artifact. Renamed because in a jj repo "workspace" means `jj workspace add`, and this directory is not one. |
| `scripts/review-package` | `scripts/sdd-review-package` | Same sections, plus the guard jj needs (below); argv is now a superset — `[--evolution-diff]` is accepted as a leading flag. |
| `scripts/task-brief` | works as-is | It only shells out when deriving its default path. Pass an explicit outfile: `task-brief <plan> <n> "$(sdd-artifacts <plan>)/task-<n>-brief.md"`. |

**Hand the review package change IDs, not commit IDs.** This is the guard, and it is the reason `sdd-review-package` is more than a port. Upstream protects BASE and HEAD with `git rev-parse --verify`, which fails loudly on a revision that no longer exists. jj offers no equivalent failure, because the revision still exists: a rewrite — `jj describe`, `jj squash`, the rebase of descendants that follows either, and every working-copy snapshot — leaves the old commit reachable and merely *hidden*. Measured on jj 0.44.0:

```
jj log  -r <stale-commit-id>                    → resolves, hidden=YES, pre-rewrite tree
jj diff --from <stale-commit-id> --to @ --stat  → exit 0, plausible diff
```

So a BASE captured before a review round does not error afterwards — it silently produces a package built against the code as it was *before* the fix, which a reviewer reads as current and reports clean. A change ID has no such failure: it follows its change through every rewrite.

`sdd-review-package` therefore reinstates the guard on jj's terms — a hidden BASE or HEAD is a hard error naming the change ID to use instead, and a commit-ID-shaped argument is a warning rather than a stop, since an immutable record is a legitimate use. The one hidden BASE that is not an error is a fix round's own pre-fix copy: when BASE is hidden and shares HEAD's change ID the error instead hands back a ready-to-run `--evolution-diff` rerun, and that mode diffs the round against HEAD's own evolution — `## Evolution` from `jj evolog` in place of `## Changes`, packages named `evolution-<change>-<baseCommit>..<headCommit>.diff`. Packages are named `review-<baseChange>..<headChange>-<headCommit>.diff`: change IDs carry identity across a review round, the head commit ID keeps each round's package a distinct file.

**BASE must be on HEAD's line of history.** The two halves of a package are built by different machinery: `## Changes` is the revset range `base..head`, while `## Files changed` and `## Diff` compare the two trees directly. Those agree for an ancestral pair and disagree for a sibling pair, and nothing in the output says which you got — measured on two revisions forked off the same root, the package listed one change while the diff deleted a file that change never touched. A non-ancestral BASE is therefore a hard error too in the default mode, which also catches BASE and HEAD passed the wrong way round. `--evolution-diff` skips it — a predecessor is a rewrite of its successor, not a DAG ancestor — and requires BASE to be on HEAD's evolution chain instead.

**Implementers share the default workspace.** Serial SDD deliberately uses no isolation, so implementer subagents running `jj describe` and `jj new` move `@` for the orchestrator too. Dispatch one at a time; that constraint is what makes the shared working copy safe, not an incidental scheduling choice.

## Author

[muloka](https://github.com/muloka)
