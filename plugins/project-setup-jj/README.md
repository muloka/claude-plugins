# Project Setup Plugin (jj)

Bootstrap jj (Jujutsu) workflow enforcement for any Claude Code project with a single `/project-setup` command.

## Overview

When starting a new Claude Code project that uses jj, there's no automated way to set up jj workflow enforcement. This plugin adds a `/project-setup` command that configures everything in one step:

- **SessionStart hook** — shows current jj change, status, and workflow reminder when a session starts
- **Hookify rules** — 3 warn-level rules that nudge toward jj best practices
- **CLAUDE.md template** — jj policy, workflow guide, and Git→jj translation table
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
| `.claude/settings.local.json` | Hook registration + jj permissions |
| `.claude/hookify.warn-raw-git.local.md` | Warn when raw git commands detected |
| `.claude/hookify.require-jj-workflow.local.md` | Remind to run `jj new` before edits |
| `.claude/hookify.warn-git-internals.local.md` | Warn on `.git/` access or git plumbing |
| `CLAUDE.md` | jj workflow instructions (created or updated) |

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
- Update hookify rules to the latest version
- Update the jj section in CLAUDE.md (via markers) without touching other content

## Related Plugins

- **[workspace-jj](../workspace-jj)** — worktree isolation via jj workspaces (optional, run `/workspace-setup` after)
- **[commit-commands-jj](../commit-commands-jj)** — commit, push, and PR workflows for jj

## Requirements

- [jj (Jujutsu)](https://martinvonz.github.io/jj/) must be installed
- [jq](https://jqlang.github.io/jq/) must be installed (for JSON merging)

## Author

[muloka](https://github.com/muloka)

## Version

1.0.0
