# Project Setup Plugin (jj)

Bootstrap jj (Jujutsu) workflow enforcement for any Claude Code project with a single `/project-setup` command.

## Overview

When starting a new Claude Code project that uses jj, there's no automated way to set up jj workflow enforcement. This plugin adds a `/project-setup` command that configures everything in one step:

- **SessionStart hook** — shows current jj change, status, and workflow reminder when a session starts
- **PreToolUse guard hook** — prompts you to run `jj new` before editing into a non-empty change
- **CLAUDE.md template** — slim jj VCS policy directive
- **Permissions** — pre-allows jj commands and gh CLI, denies raw git

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
| `.claude/scripts/require-jj-new.sh` | PreToolUse hook — prompts `jj new` before editing non-empty changes |
| `.claude/scripts/jj-workspace-create.sh` | WorktreeCreate hook — creates jj workspace for worktree isolation |
| `.claude/scripts/jj-workspace-remove.sh` | WorktreeRemove hook — cleans up jj workspace |
| `.claude/settings.local.json` | Hook registration + jj permissions |
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

== jj Workflow Reminder ==
- Use `jj new` to start a fresh change before making edits
- Use `jj describe -m "..."` to set intent on the current change
- Use `jj diff` to review working copy changes
- Never use raw git commands — use jj equivalents
```

## Idempotent

Running `/project-setup` multiple times is safe. It will:
- Overwrite scripts with the latest version
- Merge settings without duplicating entries
- Update the jj section in CLAUDE.md (via markers) without touching other content

## Related Plugins

- **[workspace-jj](../workspace-jj)** — fan-flames parallel orchestration and workspace listing
- **[commit-commands-jj](../commit-commands-jj)** — commit, push, and PR workflows for jj

## Requirements

- [jj (Jujutsu)](https://martinvonz.github.io/jj/) must be installed
- [jq](https://jqlang.github.io/jq/) must be installed (for JSON merging)

## Author

[muloka](https://github.com/muloka)

## Version

1.0.0
