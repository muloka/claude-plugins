---
allowed-tools: Bash(jj op log:*), Bash(jj op show:*), Bash(jj log:*)
description: Inspect a single jj operation with JSON output
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Recent operations (JSON): !`jj op log --limit 5 --no-graph -T 'json(self) ++ "\n"'`

## Git → jj translation

| Git | jj |
|---|---|
| `git reflog show` | `jj op show` |
| `git reflog` | `jj op log` |

## Your task

Inspect a specific operation from the operation log. If no operation ID is given, show the most recent operation.

1. If an operation ID was provided as an argument, run `jj op show <arg> -T 'json(self) ++ "\n"'`
2. If no argument, use the most recent operation from the context above
3. Present the operation details: ID, timestamp, user, description, and what changes it made
4. If the user wants to understand the impact, suggest `jj op diff --from <prev-op> --to <op>`

Notes:
- Operations record every repository mutation (commit, rebase, fetch, etc.)
- Use `jj op log` to find operation IDs
- Pairs with `/undo` — inspect an operation before deciding whether to reverse it
- The JSON metadata uses the same Operation type as `jj op log`

You have the capability to call multiple tools in a single response. Perform the inspection using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
