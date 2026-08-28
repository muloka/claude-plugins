# Project Setup Plugin (jj)

Bootstrap jj (Jujutsu) workflow enforcement for any Claude Code project with a single `/project-setup` command.

## Overview

When starting a new Claude Code project that uses jj, there's no automated way to set up jj workflow enforcement. This plugin adds a `/project-setup` command that configures everything in one step:

- **SessionStart hook** — shows the current jj change, the local stack (`trunk()..@`), conflicts, workspaces, status and workflow reminder when a session starts
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

The authoritative list is the comment block in `scripts/block-raw-git.sh`, which is byte-identical across this plugin and `peer-review-jj` and pinned by assertions in `project-setup-jj/tests/test-block-raw-git.sh`. `commit-commands-jj` depends on this plugin for the wall rather than shipping its own copy (#128), so those assertions guard its commands too. Every jj command the deny messages recommend is checked to exist *and* be runnable by `.github/tests/test-jj-recommendations.sh`. It is a guardrail against habit, not a sandbox — anyone who needs git can disable the plugin.

## Flags the Installed jj Does Not Have

The plugin registers a second `PreToolUse` hook on `Bash`, `scripts/check-jj-flags.sh`, also active as soon as the plugin is enabled. It rejects a long flag that the jj on this machine does not accept.

`jj git push --allow-new` is the case it was written for: correct for years, now removed — pushing a new bookmark is the default. The habit outlives the flag, and jj's own error actively misleads:

```
error: unexpected argument '--allow-new' found
  tip: a similar argument exists: '--all'
```

`--all` pushes **every** bookmark. Anyone reaching for the old `--allow-new` wanted one new bookmark pushed, which is now just `--bookmark <name>`, so taking that suggestion turns a no-op flag into a repo-wide push. Answering precisely is most of the hook's value.

**The decision is a property, not a list.** There is no table of removed flags to fall out of date: the check asks the installed binary what it accepts via `--help` and denies only what that binary does not list. It is correct across jj upgrades by construction and self-corrects if a flag returns.

**Scope is deliberately narrow.** Like every hook of this kind the matcher is quote-blind, and most jj subcommands take free text that routinely names flags — `jj describe -m "the fixture uses jj new --no-edit"` would be denied by a general version of this check, as would several of this repo's own commit messages. So it runs only for subcommands with no free-text argument anywhere in their surface. `jj git push` is the archetype and currently the whole list. Widening that scope is a claim about a subcommand's argument surface; the boundary note in the script says what the claim has to be.

Pinned by `tests/test-check-jj-flags.sh`, where every deny case is paired with a must-allow case — a hook that denied everything would otherwise pass the deny half of the suite.

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
| `.claude/settings.local.json` | Personal settings: jj/gh allow-list. **Not** the statusline — that lives in the tracked `settings.json` so jj workspaces inherit it |
| `CLAUDE.md` | jj VCS policy directive (created or updated) |

**Restart Claude Code** after running `/project-setup` for the SessionStart hook to take effect.

## What the SessionStart Hook Shows

On every session start, you'll see:

```
== jj Session Context ==

Current change (@):
<current change as JSON>

Local stack (trunk()..@):
qnmwxqnp @ [empty] (no description)     # one compact line per change ahead of
yxurtlwx (main) feat(...): ...          # trunk; markers for @, [empty],
                                        # [conflict] and bookmarks.
                                        # Or "(none — @ is at trunk)"

Conflicts: none            # or "CONFLICTS PRESENT" + the conflicted paths

Workspaces:
<jj workspace list — which workspace @ belongs to, and who else is live>

Working copy status:
<modified/added files>

Identity:
<user.email>

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

Copies `.claude/hooks/statusline-jj.sh` into the project and sets it as the `statusLine` command in the **tracked** `.claude/settings.json`. The statusline is a powerline-style bar showing the model, bookmark, change ID, change description, trunk-sync status, context-window percentage, and Anthropic service status.

Both halves are tracked on purpose: a `claude -w` session runs in a jj workspace, which materialises only tracked files, so a statusline configured in the gitignored `.claude/settings.local.json` — or pointing at a script under the gitignored `.claude/scripts/` — silently disappears in every side thread. The configured command resolves the *live* workspace (`$CLAUDE_PROJECT_DIR`, falling back to `jj root`) rather than hardcoding an absolute path to the main checkout.

```
/statusline-jj-remove
```

Removes `statusline-jj.sh` and deletes the `statusLine` key from **both** `.claude/settings.json` and `.claude/settings.local.json`. It clears both `.claude/hooks/` and the legacy `.claude/scripts/`, so a project set up before either move can still uninstall cleanly — and because both scopes apply, removing only one would leave the statusline running.

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
