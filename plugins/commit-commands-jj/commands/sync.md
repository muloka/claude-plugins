---
allowed-tools: Bash(jj git fetch:*), Bash(jj rebase:*), Bash(jj log:*), Bash(jj status:*)
description: Fetch from remote and rebase the current change onto trunk
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Current status: !`jj status`
- Trunk state (JSON): !`jj log -r 'trunk()' --no-graph --limit 1 -T 'json(self) ++ "\n"'`

## Git → jj translation

| Git | jj |
|---|---|
| `git fetch` | `jj git fetch` |
| `git rebase origin/main` | `jj rebase -d main@origin` |
| `git status` | `jj status` |
| `git log --oneline -10` | `jj log --limit 10` |

## Your task

Sync fetches the latest remote state and rebases your current work onto trunk. This is the jj equivalent of `git pull --rebase`.

1. Fetch from the remote: `jj git fetch`
2. Rebase onto trunk: `jj rebase -d main@origin`
   - If that fails (e.g., remote is not named `origin` or branch is not `main`), fall back to `jj rebase -d trunk()`
3. Check for conflicts: `jj log -r 'conflicts()' --no-graph -T 'json(self) ++ "\n"'`
   - If conflicts exist, report them clearly so the user can resolve them
   - If no conflicts, report success
4. Show the final state: `jj log --limit 10 --no-graph -T 'json(self) ++ "\n"'`

Notes:
- `jj git fetch` auto-prunes deleted remote tracking refs
- `trunk()` is a revset that resolves to the trunk bookmark (usually `main@origin`)
- If the current change is already on trunk, the rebase is a no-op
- Conflicts in jj are first-class — they are recorded in the change, not left as markers in the working copy

You have the capability to call multiple tools in a single response. Perform the sync using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
