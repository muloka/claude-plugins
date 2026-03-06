---
allowed-tools: Bash(jj log:*), Bash(jj edit:*), Bash(jj status:*), Bash(jj diff:*)
description: Edit an earlier jj change by moving the working copy to it
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Recent changes (JSON): !`jj log --limit 15 --no-graph -T 'json(self) ++ "\n"'`
- Current status: !`jj status`

## Git → jj translation

| Git | jj |
|---|---|
| `git checkout <commit>` | `jj edit <revision>` |
| `git status` | `jj status` |
| `git diff HEAD` | `jj diff` |
| `git log --oneline -15` | `jj log --limit 15` |

## Your task

In jj, `jj edit` moves the working copy to an earlier change so you can amend it in place. Descendants are automatically rebased when you modify the change.

1. If the user specified a revision, run `jj edit <revision>`
   - If no revision was specified, review the recent changes shown above and ask the user which change to edit
2. Show `jj status` and `jj diff` so the user can see the state of the change they switched to
3. Remind the user: when done editing, run `/new` to create a fresh change on top

Notes:
- `jj edit` does NOT create a new change — it moves the working copy to an existing one
- Any modifications you make will amend that change in place
- All descendant changes are automatically rebased
- This command does NOT auto-return to the tip — the user controls when they're finished

You have the capability to call multiple tools in a single response. Switch to the target change using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
