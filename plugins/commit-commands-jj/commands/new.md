---
allowed-tools: Bash(jj new:*), Bash(jj log:*), Bash(jj describe:*), Bash(jj status:*)
description: Start a new jj change on top of the current one (or a specified revision)
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Recent changes (JSON): !`jj log --limit 10 --no-graph -T 'json(self) ++ "\n"'`
- Current status: !`jj status`

## Git → jj translation

| Git | jj |
|---|---|
| `git checkout -b <branch>` | `jj new` (start a new change) |
| `git status` | `jj status` |
| `git log --oneline -10` | `jj log --limit 10` |
| `git branch --show-current` | `jj log -r @ --no-graph` |

## Your task

In jj, `jj new` creates a new empty change on top of the current working copy change. This is how you start fresh work after finalizing a change.

1. Run `jj new` to create a new empty change on top of the current one
   - If the user specifies a target revision, run `jj new <revision>` instead
2. If the user stated what they intend to work on, describe the new change: `jj describe -m "<intent>"`
3. Confirm the new change with `jj log -r @ --no-graph -T 'json(self) ++ "\n"'`

Notes:
- `jj new` does NOT require the current change to be committed first — jj auto-snapshots the working copy
- The previous change keeps its content; the new change starts empty
- To start a change on top of a different revision: `jj new <rev>`

You have the capability to call multiple tools in a single response. Create the new change using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
