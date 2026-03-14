---
allowed-tools: Bash(jj commit:*), Bash(jj status:*), Bash(jj diff:*), Bash(jj log:*), Bash(jj bookmark:*), Bash(jj git push:*), Bash(gh pr create:*)
description: Commit, push, and open a PR using jj
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current jj status: !`jj status`
- Changed files (JSON): !`jj diff -T '"{ \"path\": " ++ self.path().display().escape_json() ++ ", \"status\": " ++ self.status().escape_json() ++ " }\n"'`
- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Bookmarks on current change: !`jj log -r @ --no-graph -T 'bookmarks'`

## Your task

Based on the above changes:

1. `jj commit -m "<msg>"` — finalize the working copy with an appropriate description
2. Check if building on trunk: `jj log -r '@- & trunk()' --no-graph -T 'json(self) ++ "\n"'` — if this returns a result, the change is directly on trunk and needs a bookmark
3. Check if `@-` already has a bookmark: `jj log -r @- --no-graph -T 'bookmarks'`
4. If no bookmark exists on `@-`: `jj bookmark create <descriptive-name> -r @-` (use a short kebab-case name derived from the change description)
5. Push: `jj git push --bookmark <name> --allow-new`
6. Create a pull request: `gh pr create` with an appropriate title and body

For colocated repos (`.jj/` + `.git/`), `gh` works directly. For non-colocated repos, if `gh` fails, advise the user to set `GIT_DIR=.jj/repo/store/git` or run `jj git export` first.

You have the capability to call multiple tools in a single response. You MUST do all of the above in a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
