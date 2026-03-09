---
allowed-tools: Bash(jj evolog:*), Bash(jj log:*)
description: Show how a jj change has evolved over time
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Evolution log (JSON): !`jj evolog -r ${1:-@} --no-graph -T 'json(self) ++ "\n"'`
- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`

## Git → jj translation

| Git | jj |
|---|---|
| `git reflog` | `jj evolog` (per-change) or `jj op log` (per-operation) |

## Your task

Show the evolution history of a change (default: `@`). In jj, every modification to a change (rebase, describe, squash, conflict resolution) creates a new version. `jj evolog` shows all versions.

1. Present the evolution entries from context above in chronological order
2. For each entry, highlight: what changed (description update, rebase, content change), when, and by which operation
3. Summarize the change's journey (e.g., "created → described → rebased onto main → squashed fixup")

Notes:
- This is jj's equivalent of per-commit reflog — it shows the full history of a single change
- Useful for debugging "what happened to this change?" after syncs, rebases, or collaboration
- Each evolution entry includes the operation that caused it
- The change ID stays the same across all versions — only the commit ID changes

You have the capability to call multiple tools in a single response. Perform the inspection using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
