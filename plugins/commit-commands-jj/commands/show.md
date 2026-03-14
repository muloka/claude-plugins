---
allowed-tools: Bash(jj show:*), Bash(jj diff:*), Bash(jj log:*)
description: Inspect a single jj revision with JSON output
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Revision metadata (JSON): !`jj show -r @ -T 'json(self) ++ "\n"' -s`

## Git → jj translation

| Git | jj |
|---|---|
| `git show <commit>` | `jj show -r <rev>` |
| `git log -1 <commit>` | `jj log -r <rev>` |

## Your task

Show a summary of the specified revision (default: `@`).

1. If an argument was provided, run `jj show -r <arg> -T 'json(self) ++ "\n"' -s` for that revision instead
2. Present the revision metadata: change ID, commit ID, author, description, and parent(s)
3. Show the file-level summary (added/modified/deleted files)
4. If the user wants the full diff, run `jj diff -r <rev>`

Notes:
- `jj show` combines revision metadata + diff in one command
- Use `-r <rev>` to inspect any revision (change IDs, commit IDs, bookmarks, or revsets)
- The JSON metadata uses the same Commit type as `jj log`

You have the capability to call multiple tools in a single response. Perform the inspection using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
