# Project Setup Plugin (jj)

Bootstrap jj (Jujutsu) workflow enforcement for any Claude Code project with a single `/project-setup` command.

## Overview

When starting a new Claude Code project that uses jj, there's no automated way to set up jj workflow enforcement. This plugin adds a `/project-setup` command that configures everything in one step:

- **SessionStart hook** — shows current jj change, status, and workflow reminder when a session starts
- **PreToolUse guard hook** — advises Claude to run `jj new` before editing into a non-empty change (informational — does not block)
- **PreCompact hook** — snapshots the working copy before context compaction so `jj undo` / `jj op restore` can always reach the pre-compaction state
- **CLAUDE.md template** — slim jj VCS policy directive
- **Permissions** — pre-allows jj commands and gh CLI, denies raw git

The plugin itself (independent of running `/project-setup`) also registers a `PreToolUse` hook on all `Bash` calls that blocks raw `git` commands and git internals access, backed by `scripts/block-raw-git.sh`. This is active as soon as the plugin is enabled.

## Installation

```bash
claude plugins add muloka/claude-plugins:project-setup-jj
```

## Usage

Run the setup command in any jj project:

```
/project-setup
```

This creates/updates the following in your project:

| File | Purpose |
|------|---------|
| `.claude/scripts/jj-session-start.sh` | SessionStart hook showing jj context |
| `.claude/scripts/require-jj-new.sh` | PreToolUse hook — advises Claude to run `jj new` before editing into a non-empty change (informational — does not block) |
| `.claude/scripts/jj-workspace-create.sh` | WorktreeCreate hook — creates jj workspace for worktree isolation |
| `.claude/scripts/jj-workspace-remove.sh` | WorktreeRemove hook — cleans up jj workspace |
| `.claude/settings.local.json` | Hook registration (SessionStart, PreToolUse, PreCompact, WorktreeCreate, WorktreeRemove) + jj permissions |
| `CLAUDE.md` | jj VCS policy directive (created or updated) |

**Restart Claude Code** after running `/project-setup` for the SessionStart hook to take effect.

## What the SessionStart Hook Shows

On every session start, you'll see:

```
== jj Session Context ==

Current change:
<current change details>

Working copy status:
<modified/added files>

Repository config (JSON):
<repository config>

== jj Workflow Reminder ==
- Use `jj new` to start a fresh change before making edits
- Use `jj describe -m "..."` to set intent on the current change
- Use `jj diff` to review working copy changes
- Never use raw git commands — use jj equivalents
```

## Statusline

Two more commands manage a jj-aware statusline, independent of `/project-setup`:

```
/statusline-jj-setup
```

Copies `.claude/scripts/statusline-jj.sh` into the project and sets it as the `statusLine` command in `.claude/settings.local.json`. The statusline is a powerline-style bar showing the model, bookmark, change ID, change description, trunk-sync status, context-window percentage, and Anthropic service status.

```
/statusline-jj-remove
```

Removes `.claude/scripts/statusline-jj.sh` and deletes the `statusLine` key from `.claude/settings.local.json`.

## Idempotent

Running `/project-setup` multiple times is safe. It will:
- Overwrite scripts with the latest version
- Merge settings without duplicating entries
- Update the jj section in CLAUDE.md (via markers) without touching other content

## Related Plugins

- **[workspace-jj](../workspace-jj)** — kaisen parallel orchestration and workspace listing
- **[commit-commands-jj](../commit-commands-jj)** — commit, push, and PR workflows for jj

## Requirements

- [jj (Jujutsu)](https://martinvonz.github.io/jj/) must be installed
- [jq](https://jqlang.github.io/jq/) must be installed (for JSON merging)

## Author

[muloka](https://github.com/muloka)

## Version

1.0.0
