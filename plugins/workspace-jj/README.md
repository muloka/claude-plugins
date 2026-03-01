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

## Usage

```bash
# Start Claude in an isolated jj workspace
claude --worktree feature-auth

# Auto-generated name
claude --worktree
```

Subagents can also use workspace isolation with `isolation: "worktree"` in their frontmatter.

## Requirements

- [jj (Jujutsu)](https://martinvonz.github.io/jj/) must be installed
- [jq](https://jqlang.github.io/jq/) must be installed (for JSON parsing in hooks)

## Cleanup

Workspaces are cleaned up automatically when you exit a session and choose to remove the worktree. For manual cleanup of stale workspaces, use the `/clean_stale` command from the [commit-commands-jj](../commit-commands-jj) plugin.

## Author

[muloka](https://github.com/muloka)

## Version

1.0.0
