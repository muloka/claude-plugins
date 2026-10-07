---
allowed-tools: Bash(jj op log:*), Bash(jj op revert:*), Bash(jj op restore:*), Bash(jj log:*), Bash(jj status:*), Bash(jj evolog:*), Bash(jj describe:*)
description: Undo the last jj operation
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Recent operations (JSON): !`jj op log --limit 5 --no-graph -T 'json(self) ++ "\n"'`
- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Current status: !`jj status`

## Git → jj translation

| Git | jj |
|---|---|
| `git reflog` | `jj op log` |
| `git reset HEAD~1` | `jj op revert` |
| `git status` | `jj status` |
| `git log --oneline -5` | `jj log --limit 5` |

## Your task

In jj, every operation is recorded in the operation log, and `jj op revert <op-id>` reverses one of them. Most of the work is choosing the right one and knowing what reverting it does to files the user edited afterwards.

1. **Find the operation to undo.** It is the newest entry in the log above with `"is_snapshot": false`. An entry with `"is_snapshot": true` ("snapshot working copy") is jj recording file edits made since the previous jj command. This command's own Context created the top one if anything had changed. Reverting a snapshot entry deletes those edits from disk. Bare `jj undo` does the same, because it reverts the newest entry whatever it is.
2. **If no snapshot entry is newer than it**, run `jj op revert <op-id>`.
3. **If one is**, the user edited files after that operation, and reverting it leaves the change divergent: a restored copy without the edits next to the current copy with them. Don't revert it. When the operation's effect is simple to reverse directly, do that instead. A `describe`, for example, is undone by describing again with the previous message, which `jj evolog -r @` shows. Otherwise, tell the user what the operation did and that they edited files since, and offer two choices: the revert, which leaves the change divergent, or `jj op restore <op-id>` to the entry before it, which also discards the later edits.
4. Confirm the result with `jj status` and `jj log --limit 5 --no-graph -T 'json(self) ++ "\n"'`.
5. Report what was undone and how, in a sentence or two.

Notes:
- For restoring to an older state, use `jj op restore <op-id>` (the op IDs are visible in `jj op log`)
- The revert itself is an operation and can be reverted
- No commit is ever lost: `jj op log` keeps every state, so even a wrong revert can be walked back with `jj op restore`
- Prefer `jj op revert <op-id>` over bare `jj undo` here. `jj undo` is *not*
  deprecated — it is current — but it is **sequential**: calling it twice walks
  two operations back, not one. An agent that retries after an ambiguous result
  will undo more than it meant to. `jj op revert <op-id>` names exactly what it
  reverses, so it says the same thing every time it runs
- `jj op undo` **was** deprecated in favour of `jj op revert`, and has been
  removed. Don't confuse it with bare `jj undo`, which still exists
