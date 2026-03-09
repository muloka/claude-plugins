---
allowed-tools: Bash(jj status:*), Bash(jj diff:*), Bash(jj commit:*), Bash(jj log:*)
description: Finalize the current jj change with a description
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current jj status: !`jj status`
- Changed files (JSON): !`jj diff -T '"{ \"path\": " ++ self.path().display().escape_json() ++ ", \"status\": " ++ self.status().escape_json() ++ " }\n"'`
- Change stats (JSON): !`jj log -r @ --no-graph -T 'self.diff().stat().files().map(|entry| "{ \"path\": " ++ entry.path().display().escape_json() ++ ", \"lines_added\": " ++ entry.lines_added() ++ ", \"lines_removed\": " ++ entry.lines_removed() ++ ", \"bytes_delta\": " ++ entry.bytes_delta() ++ " }\n")'`
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

In jj, the working copy IS already a commit. The natural flow is:
1. Review changes in the working copy (already there — no staging needed)
2. `jj commit -m "<msg>"` — describes the current change and starts a new empty one on top

Based on the above changes, finalize the current jj change with an appropriate description.

There is no `git add` equivalent in jj. All working copy changes are automatically included. If the user needs partial commits, they should use `jj split` before running `/commit`.

You have the capability to call multiple tools in a single response. Create the commit using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
