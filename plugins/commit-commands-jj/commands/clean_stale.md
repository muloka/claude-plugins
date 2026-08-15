---
description: Cleans up a jj repository by fetching remote state — which prunes bookmarks deleted on the remote — and forgetting stale workspaces.
allowed-tools: Bash(jj bookmark list:*), Bash(jj workspace:*), Bash(jj git fetch:*)
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Bookmarks **before** the fetch (JSON): !`jj bookmark list --all -T 'json(self) ++ "\n"'`
- Current workspaces: !`jj workspace list`

## Your Task

Clean up a jj repository. There are two halves and they are not symmetric: **the
bookmark half is one command, and the workspace half is the only part that needs
you to find anything.**

## Commands to Execute

1. **Fetch the latest remote state — this *is* the bookmark cleanup**
   ```bash
   jj git fetch
   ```

   `jj git fetch` prunes deleted remote-tracking refs *and* drops the local
   bookmark that tracked them. There is no `--prune` flag because there is
   nothing to opt into, and there is **no follow-up `jj bookmark delete`** —
   after this step no stale bookmark remains to find.

   Its output names what went, so read it rather than re-deriving it:
   ```
   bookmark: feature-gone@origin [deleted] untracked
   ```

   **Do not go hunting for "local bookmarks whose remote was deleted."** That is
   the `git fetch --prune` + `git branch -d` habit, and jj does not need it.
   Running `jj bookmark delete <name>` on a bookmark fetch already removed just
   prints `Warning: No matching bookmarks for names: <name>` and exits 0 —
   a no-op that reads like a successful cleanup.

   If fetch also reports `Abandoned N commits that are no longer reachable`,
   that is jj dropping commits the deleted bookmark was the only path to —
   **including work you just merged, if it was squash-merged.** A squash-merge
   rebuilds the work as a *new* commit, so your local one is not an ancestor of
   trunk and the deleted bookmark was indeed its only path; only a true merge
   commit leaves it reachable. The content is safe in trunk, but `@` re-parents
   onto the pre-merge base and the merged files read as reverted on disk — run
   `jj new trunk()`. This is why `/finish` step 6 deletes the remote branch
   *last*: while it exists, the fetch is inert and the work can be verified
   before anything is dropped.

2. **List workspaces to find stale ones**
   ```bash
   jj workspace list
   ```

   This half is real work. A workspace whose directory has been deleted stays
   registered indefinitely — no ordinary jj command clears it, and nothing in
   step 1 touches it.

3. **Forget stale workspaces**
   For each stale workspace found in step 2 (other than the default workspace):
   ```bash
   jj workspace forget <workspace-name>
   ```

## Expected Behavior

After executing these commands, you will:

- Have the latest remote state fetched, with bookmarks deleted on the remote
  already pruned as part of that fetch
- Have identified and forgotten any stale workspaces
- Report what was cleaned up — for bookmarks, that is whatever the fetch output
  named (compare against the pre-fetch list in Context if you want the delta)

If the fetch pruned nothing and no stale workspaces are found, report that no
cleanup was needed.
