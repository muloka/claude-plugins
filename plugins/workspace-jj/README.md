# Workspace Plugin (jj)

Enables Claude Code's worktree isolation (`--worktree` flag and `isolation: "worktree"` for subagents) in jj (Jujutsu) repositories using jj workspaces.

## Overview

Claude Code uses git worktrees by default for isolated parallel sessions. This plugin replaces that with jj workspaces via `WorktreeCreate` and `WorktreeRemove` hooks, so `--worktree` works natively in jj repos.

## How It Works

- **WorktreeCreate**: Runs `jj workspace add` to create an isolated workspace at `.claude/worktrees/<name>/`
- **WorktreeRemove**: Runs `jj workspace forget` and removes the directory on cleanup

Workspaces share the same repository store, so they're lightweight and fast to create.

## Installation

```bash
claude plugins add muloka/claude-plugins:workspace-jj
```

## Setup

After installing, run the setup command in your jj project:

```
/workspace-setup
```

This copies the hook scripts to `.claude/scripts/` in your project and configures the `WorktreeCreate` and `WorktreeRemove` hooks in `.claude/settings.local.json`. Restart your Claude Code session after setup.

**Why is this needed?** Claude Code currently doesn't pick up `WorktreeCreate`/`WorktreeRemove` hooks from plugins — they must be in project or user settings. The `/workspace-setup` command handles this for you.

**After plugin updates:** Re-run `/workspace-setup` to refresh the scripts in `.claude/scripts/`.

## Commands

| Command | Description |
|---------|-------------|
| `/workspace-setup` | Configure worktree hooks for the current project |
| `/workspace-list` | List all active jj workspaces (JSON output) |

## Usage

```bash
# Start Claude in an isolated jj workspace
claude --worktree feature-auth

# Auto-generated name
claude --worktree

# List active workspaces
/workspace-list
```

Subagents can also use workspace isolation with `isolation: "worktree"` in their frontmatter.

## Requirements

- [jj (Jujutsu)](https://martinvonz.github.io/jj/) must be installed
- [jq](https://jqlang.github.io/jq/) must be installed (for JSON parsing in hooks)

## Cleanup

Workspaces are cleaned up automatically when you exit a session and choose to remove the worktree. For manual cleanup of stale workspaces, use the `/clean_stale` command from the [commit-commands-jj](../commit-commands-jj) plugin.

## Fan-Flames Skill

Parallel workspace orchestration — fan out tasks to isolated jj workspaces, fan in results.

```
🪭 Fan out → N workspaces → N subagents → 🔥 Fan in → single change → /peer-review
```

**Usage:** Triggered automatically when `subagent-driven-development` runs in a jj repo, or directly:

- "Fan out these 3 tasks into parallel workspaces"
- "Run these tasks in parallel with isolation"
- "Dispatch subagents for these independent tasks"

**Merge order:** Smallest diff first (by files touched). Override with `--merge-order task-3,task-1,task-2`.

**Failure handling:** Partial success is preserved. Failed workspaces stay alive for inspection via `/workspace-list`.

See [design spec](../../docs/specs/2026-03-18-permission-gateway-and-fan-flames-design.md) for full details.

## Author

[muloka](https://github.com/muloka)

## Version

1.0.0
