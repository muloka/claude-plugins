---
allowed-tools: Bash(jj squash:*), Bash(jj log:*), Bash(jj status:*), Bash(jj diff:*), Bash(jj describe:*)
description: Squash the current jj change into its parent
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Parent change (JSON): !`jj log -r @- --no-graph -T 'json(self) ++ "\n"'`
- Changed files (JSON): !`jj diff -T '"{ \"path\": " ++ self.path().display().escape_json() ++ ", \"status\": " ++ self.status().escape_json() ++ " }\n"'`
- Change stats (JSON): !`jj log -r @ --no-graph -T 'self.diff().stat().files().map(|entry| "{ \"path\": " ++ entry.path().display().escape_json() ++ ", \"lines_added\": " ++ entry.lines_added() ++ ", \"lines_removed\": " ++ entry.lines_removed() ++ ", \"bytes_delta\": " ++ entry.bytes_delta() ++ " }\n")'`
- Current status: !`jj status`

## Git → jj translation

| Git | jj |
|---|---|
| `git rebase -i` (squash) | `jj squash` |
| `git commit --amend` | `jj squash` (moves current into parent) |
| `git diff HEAD` | `jj diff` |
| `git log --oneline -5` | `jj log --limit 5` |

## Your task

In jj, `jj squash` moves all changes from the current change into its parent and combines their descriptions. The current change becomes empty afterward.

1. Check if the current change has any modifications (from the diff/status above)
   - If the current change is empty (no diff), report "nothing to squash" and stop
2. Construct a combined description from the current change and parent descriptions (from context above). Write a clean, concise message that captures both — do not just concatenate them.
3. Run `jj squash -m "<combined-description>"`
   - Always use `-m` to avoid opening an editor (agents cannot interact with editors)
   - If the user specified a target revision, run `jj squash --into <rev> -m "<combined-description>"` instead
4. Show the result: `jj log --limit 5 --no-graph -T 'json(self) ++ "\n"'`

Notes:
- After squashing, the working copy moves to the (now-combined) parent change
- `jj squash` is the idiomatic way to fold small fixups into a previous change
- For squashing into a non-parent change, use `jj squash --into <rev>`

You have the capability to call multiple tools in a single response. Perform the squash using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
