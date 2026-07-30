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

**Scope of the hook.** It denies `git` where the shell would start a command: on its own, after `;` `&&` `||` `|` or a newline, inside `$(…)` or `<(…)`, inside `(…)` or `{ …; }`, and after a keyword, wrapper or `VAR=value` prefix. A clause beginning `jj git …` is never denied.

It matches text rather than parsing the shell, which cuts both ways.

- **Not caught** (deliberately): backtick substitution, an interpreter handed git as data (`bash -c 'git status'`), wrappers carrying their own options (`eval "git …"`, `sudo -u me git`, `timeout 5 git`), and spellings other than the bare word (`/usr/bin/git`).
- **Over-caught**: it is quote-blind, so a git command named after a separator *inside* a quoted string still reads as command position — `jj describe -m 'first; git status next'` is denied. Prose that merely mentions git is fine; prose that puts it right after a separator is not.

**Scope of the git-internals rule.** A second, separately-coded branch denies reading or writing the git directory. `.git` must appear as a *whole path component*: `ls .git`, `cat .git/HEAD` and `cat /repo/.git/HEAD` are denied.

- **Not caught**: longer names that merely start with the same letters — `.gitignore`, `.gitattributes` and `.github/` all pass, which matters because this repo's own CI lives in `.github/`.
- **Not caught**: a `.git` *suffix* on a URL or directory name. `jj git clone https://host/o/r.git dir`, `gh repo clone o/r.git dir` and `npm i https://host/o/r.git --save` all pass. An earlier unanchored version of this rule denied all three — including `jj git clone`, which this very hook recommends.
- **Over-caught**: quote-blind here too, so prose naming the directory (`jj describe -m 'the .git directory'`) is denied.

Git plumbing commands are *not* special-cased. `git config` and `git rev-parse` are denied by the raw-git rule above like any other subcommand, and get advice specific to them.

The authoritative list is the comment block in `scripts/block-raw-git.sh`, which is byte-identical across all three plugins and pinned by assertions in `project-setup-jj/tests/test-block-raw-git.sh`. Every jj command the deny messages recommend is checked to exist *and* be runnable by `.github/tests/test-jj-recommendations.sh`. It is a guardrail against habit, not a sandbox — anyone who needs git can disable the plugin.

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
| `.claude/hooks/jj-session-start.sh` | SessionStart hook showing jj context |
| `.claude/hooks/require-jj-new.sh` | PreToolUse hook — advises Claude to run `jj new` before editing into a non-empty change (informational — does not block) |
| `.claude/hooks/jj-workspace-create.sh` | WorktreeCreate hook — creates jj workspace for worktree isolation |
| `.claude/hooks/jj-workspace-remove.sh` | WorktreeRemove hook — cleans up jj workspace |
| `.claude/settings.json` | Hooks (SessionStart, PreToolUse, PreCompact, WorktreeCreate, WorktreeRemove) + the `Bash(git *)` deny floor — **commit this**, it is what makes fresh clones and jj workspaces enforce the rules (#97) |
| `.claude/settings.local.json` | Personal settings: jj/gh allow-list, and `statusLine` if `/statusline-jj-setup` is used |
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

Copies `.claude/hooks/statusline-jj.sh` into the project and sets it as the `statusLine` command in `.claude/settings.local.json`. The statusline is a powerline-style bar showing the model, bookmark, change ID, change description, trunk-sync status, context-window percentage, and Anthropic service status.

```
/statusline-jj-remove
```

Removes `statusline-jj.sh` and deletes the `statusLine` key from `.claude/settings.local.json`. It clears both `.claude/hooks/` and the legacy `.claude/scripts/`, so a project set up before the move can still uninstall cleanly.

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
