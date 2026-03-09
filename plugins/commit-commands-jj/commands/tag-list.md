---
allowed-tools: Bash(jj tag:*)
description: List tags with JSON output
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Tags (JSON): !`jj tag list -T 'json(self) ++ "\n"'`

## Git → jj translation

| Git | jj |
|---|---|
| `git tag -l` | `jj tag list` |

## Your task

List all tags in the repository with structured JSON output.

1. Present the tags from context above: tag name, target commit, and associated metadata
2. If no tags exist, report that the repository has no tags
3. If the user wants details on a specific tag's target, suggest `jj show -r <tag-name>`

Notes:
- Tags in jj work similarly to Git tags — they point to specific commits
- The JSON metadata uses the same CommitRef type as `jj bookmark list`
- Use `jj tag list` to see all tags; filter with revsets for specific tags

You have the capability to call multiple tools in a single response. Perform the inspection using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
