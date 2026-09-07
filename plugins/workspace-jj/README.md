# Workspace Plugin (jj)

Wave-based parallel orchestration with spec review gates for jj (Jujutsu) repositories.

## Overview

Provides the **kaisen** skill — a parallel task orchestrator that dispatches subagents to isolated jj workspaces, gates each wave with a test + peer review pass, then reunifies results into a single change. The jj-native replacement for superpowers' `subagent-driven-development`. Workspace hooks are installed by `/project-setup` from the [project-setup-jj](../project-setup-jj) plugin.

**For side threads, the default door is `jjtab`** — a shell function ([below](#side-threads-which-door-to-use)) that makes a jj workspace beside the repo and launches plain `claude` in it, with no harness guard. `claude --worktree` and `EnterWorktree` still work in jj repos through the hooks, but a session started that way is guarded (no `jj git` inside until it leaves); keep them for throwaway spikes and for isolation you need *from inside* a session. `/finish` is the safety net when one of those turns into PR work anyway.

## How It Works

- **WorktreeCreate**: Runs `jj workspace add --revision <trunk>` to create an isolated workspace at `/tmp/jj-workspaces/<project>/<name>/`, based on `trunk()` (falling back to `@-`, then `@` itself, in a repo with no remote — each guarded against resolving to the root commit, which would give an empty workspace). Workspaces are created outside the repo to prevent jj's auto-snapshotting from attributing workspace edits to the default workspace's `@`.
- **WorktreeRemove**: Runs `jj workspace forget` and removes the directory on cleanup. `/finish` calls the same script itself for a worktree the session has already left.

Workspaces share the same repository store (lightweight, fast to create) but each gets an independent working copy on the same base.

**A session in a hook-made workspace is harness-isolated.** Claude Code refuses every `jj git` command there (push, fetch, even `remote list`) and most compound shell commands: it reads the `git` token as a git invocation and cannot be configured otherwise. The SessionStart briefing says so at minute zero; `/finish` (commit-commands-jj 0.20+) leaves the worktree with `ExitWorktree` keep before its first remote command. The briefing fires only at session start, so a mid-session `EnterWorktree` gets no notice — `/finish` still covers it. A workspace you make by hand (`jjtab` below) has no guard at all.

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
# Default for any side thread: hand-made workspace beside the repo, plain claude, no guard
jjtab feature-auth            # shell function below; base is trunk(), add a revset to change it

# Only for a throwaway spike, or isolation from inside a running session:
# harness worktree (guarded — no jj git inside until /finish or ExitWorktree leaves it)
claude --worktree spike-auth

# List all workspaces
/workspace-list
```

## Side Threads: Which Door to Use

**Default: `jjtab`.** Start a side thread with it unless you know the thread will never push and you want nothing left behind. The harness guard (above) is the reason: a workspace the harness did not create has no guard, so fetch, push and `/finish` all run from inside it, and it can be resumed tomorrow by `cd`-ing back in and running `claude`. A `claude --worktree` session can leave its worktree only once, and a resumed one may not be able to leave at all.

| Situation | Use | Guard |
|-----------|-----|-------|
| New tab, any side thread (**default**) | `jjtab <name> [revset]` (below) | none |
| New tab, throwaway spike that will never push | `claude --worktree <name>` — the WorktreeCreate hook makes the workspace | yes |
| Already inside a session and need isolation now | ask Claude to enter a worktree (native `EnterWorktree` → same hook; it cannot enter a `jjtab` workspace) | yes |
| In a guarded workspace and it turned into PR work | `/finish` leaves the worktree for you (commit-commands-jj 0.20+); otherwise `ExitWorktree` with keep, then push from the main checkout — bookmarks and changes are repo-global. One-way: the session finishes in the main checkout | lifted |
| Parallel agent execution of a plan | `/kaisen` — the skill manages workspaces itself | none |

`jjtab` is a terminal door only: it ends by launching `claude`, so Claude cannot route itself there mid-session — which is why the in-session row exists and why `/finish` handles the guarded case.

Each workspace has its own working copy (`@`), so tabs never affect each other; all changes remain visible in the shared `jj log` from anywhere. One rule: never `jj edit` (or otherwise rewrite) a change that another workspace has checked out as its `@` — that creates a divergent change (`change_id??`, two commits for one change). Recover by abandoning the unwanted commit by its commit ID.

The `jjtab` function for your shell config:

```bash
# jjtab NAME [REVSET] — durable jj workspace beside the repo + plain claude in it.
#   - base is trunk(), never `@-`: a thread must not inherit a parked empty change.
#   - dir is <repo>-ws/NAME, a sibling of the repo; survives reboots.
# Plain `claude`, NOT `claude --worktree`: the harness worktree-isolation guard
# refuses every `jj git push/fetch` form and cannot be configured off, so a
# thread that must push needs a workspace the harness did not create.
# Run from the MAIN checkout: `jj root` is the current workspace's root, so
# running inside <repo>-ws/<x> would nest <x>-ws under it (guarded below).
# Finish with /finish in-session, or `jj workspace forget NAME` + rm the dir.
jjtab() {
  local name=${1:?usage: jjtab NAME [REVSET]}
  local rev=${2:-'trunk()'}
  local root
  root=$(jj root) || return
  case "$(dirname "$root")" in
    *-ws) echo "jjtab: run from the main checkout, not a workspace ($root)" >&2; return 1 ;;
  esac
  local dir="${root}-ws/$name"
  mkdir -p "$(dirname "$dir")" || return   # jj workspace add needs the parent to exist
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
