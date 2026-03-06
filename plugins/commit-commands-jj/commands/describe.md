---
allowed-tools: Bash(jj status:*), Bash(jj diff:*), Bash(jj describe:*), Bash(jj log:*)
description: Set or update the description of the current jj change
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current jj status: !`jj status`
- Changed files (JSON): !`jj diff -T '"{ \"path\": " ++ self.path().display().escape_json() ++ ", \"status\": " ++ self.status().escape_json() ++ " }\n"'`
- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Recent changes (JSON): !`jj log --limit 10 --no-graph -T 'json(self) ++ "\n"'`

## Git → jj translation

| Git | jj |
|---|---|
| `git status` | `jj status` |
| `git diff HEAD` | `jj diff` |
| `git branch --show-current` | `jj log -r @ --no-graph` |
| `git log --oneline -10` | `jj log --limit 10` |

## Your task

In jj, `jj describe` sets or updates the description of the current working copy change. Unlike `jj commit`, it does NOT finalize the change or start a new one — you stay on the same change with the same change ID.

Use cases:
- Label what you're currently working on
- Identify changes in anonymous branches (jj favors descriptions over bookmarks)
- Update the message before pushing

Based on the above changes, set an appropriate description on the current change:

`jj describe -m "<msg>"`

After describing, the change ID stays the same (only the commit ID changes). There is no staging in jj — the description applies to whatever is in the working copy.

You have the capability to call multiple tools in a single response. Set the description using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
