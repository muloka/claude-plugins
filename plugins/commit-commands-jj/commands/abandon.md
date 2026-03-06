---
allowed-tools: Bash(jj abandon:*), Bash(jj log:*), Bash(jj status:*), Bash(jj diff:*)
description: Discard a jj change (current or specified revision)
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Current diff stats: !`jj diff --stat`
- Current status: !`jj status`

## Git → jj translation

| Git | jj |
|---|---|
| `git reset --hard HEAD~1` | `jj abandon` |
| `git checkout -- .` | `jj abandon` (then jj creates a new empty change) |
| `git diff --stat` | `jj diff --stat` |
| `git status` | `jj status` |

## Your task

In jj, `jj abandon` discards a change entirely. Descendants are rebased onto its parent. If you abandon the current working copy change, jj automatically creates a new empty change in its place.

1. Check if the current change has modifications (from the diff stats/status above)
   - If it does, warn the user that the change has uncommitted work that will be lost
2. Run `jj abandon`
   - If the user specified a revision, run `jj abandon <revision>` instead
3. Show the result: `jj log --limit 5 --no-graph -T 'json(self) ++ "\n"'` and `jj status`
4. Remind the user: run `/undo` if this was a mistake

Notes:
- Abandoning a change does NOT delete its content from the op log — it can be recovered with `jj undo`
- Descendants of the abandoned change are rebased onto its parent
- If you abandon the working copy change (`@`), jj creates a new empty change automatically
- To abandon multiple changes, use a revset: `jj abandon <revset>`

You have the capability to call multiple tools in a single response. Perform the abandon using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
