---
description: Cleans up stale bookmarks and workspaces in a jj repository by fetching latest remote state and removing bookmarks deleted on the remote.
allowed-tools: Bash(jj bookmark:*), Bash(jj workspace:*), Bash(jj git fetch:*)
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current bookmarks (JSON): !`jj bookmark list --all -T 'json(self) ++ "\n"'`
- Current workspaces: !`jj workspace list`

## Your Task

You need to execute the following commands to clean up stale local bookmarks and workspaces in a jj repository.

## Commands to Execute

1. **First, fetch the latest remote state**
   Execute this command:
   ```bash
   jj git fetch
   ```

   Note: jj automatically prunes deleted remote tracking refs during fetch — no `--prune` flag needed.

2. **List all bookmarks to find stale ones**
   Execute this command:
   ```bash
   jj bookmark list --all -T 'json(self) ++ "\n"'
   ```

   Look for local bookmarks whose remote counterpart has been deleted. These appear as bookmarks that exist locally but have no corresponding remote tracking bookmark, or bookmarks marked as deleted on remote.

3. **List workspaces to find stale ones**
   Execute this command:
   ```bash
   jj workspace list
   ```

4. **Delete stale bookmarks**
   For each stale bookmark found in step 2, execute:
   ```bash
   jj bookmark delete <bookmark-name>
   ```

5. **Forget stale workspaces**
   For each stale workspace found in step 3 (other than the default workspace), execute:
   ```bash
   jj workspace forget <workspace-name>
   ```

## Expected Behavior

After executing these commands, you will:

- Have the latest remote state fetched
- Identify and remove local bookmarks that were deleted on the remote
- Identify and forget any stale workspaces
- Provide feedback on which bookmarks and workspaces were cleaned up

If no stale bookmarks or workspaces are found, report that no cleanup was needed.
