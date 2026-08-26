---
description: Finish development work — push+PR, squash into trunk, keep, or discard
allowed-tools: Bash(jj:*), Bash(jj git push:*), Bash(gh pr create:*), Bash(gh pr view:*), AskUserQuestion, Read
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Parent change (JSON): !`jj log -r @- --no-graph -T 'json(self) ++ "\n"'`
- Current diff stats: !`jj diff --stat`
- Current status: !`jj status`
- Bookmarks on current change: !`jj log -r @ --no-graph -T 'bookmarks'`
- Current workspace root: !`jj workspace root`
- All workspaces (name, root): !`jj workspace list --no-pager -T 'self.name() ++ "\t" ++ self.root() ++ "\n"'`

## Overview

**This skill replaces `superpowers:finishing-a-development-branch` for jj repos.**

Guide completion of development work by presenting clear options and executing the chosen workflow.

**Core principle:** Verify work exists → Verify tests → Present options → Execute choice → Clean up.

**Announce at start:** "I'm using the /finish skill to complete this work."

## Step 1: Verify the change has content

Check the context above. If the current change (`@`) is empty (no diff), check if `@-` has the work (common after `jj commit`). Identify the target change — the one with the actual work.

If no changes exist anywhere in the current line of work (compare against `trunk()`):
```
Nothing to finish — no changes found against trunk.
```
Stop.

If changes exist, continue. Show a brief summary of what's being finished:
```
Finishing: <description or summary of changes>
<N> files changed, +<additions>, -<deletions>
```

## Step 2: Verify tests

The menu comes after a green suite — integrating untested work is how bad
merges happen.

1. **Find the project's test command.** In order of authority: project
   instructions (CLAUDE.md), CI config (`.github/workflows/`), then standard
   manifests (`package.json` scripts.test, `Cargo.toml`, `pyproject.toml`,
   `Makefile` test target, `go.mod`).

   If none of these yields a test command, report:
   ```
   No test suite detected — skipping test gate.
   ```
   and continue to Step 3.

2. **Run the suite on the tree being finished.** A green run earlier in the
   session only proves the tree it ran on — if `@` has changed since, run it
   again. (The test command is usually outside this command's pre-approved
   tools, so expect a permission prompt.)

3. **If tests fail**, report the failures and stop:
   ```
   Tests failing (<N> failures). Must fix before finishing:
   <failures>
   ```
   Do not present the menu. If the user explicitly says to discard the work
   anyway, Option 4 remains available on that request.

## Step 3: Present options

Present exactly these 4 options:

```
What would you like to do?

1. Push and create a Pull Request
2. Merge into trunk locally (fast-forward)
3. Keep as-is (I'll handle it later)
4. Discard this work
```

## Step 4: Execute choice

### Option 1: Push and create PR (most common)

1. **Ancestor check before push.** Before creating the bookmark, check for non-empty changes between trunk and the target that are NOT the target itself:
   ```bash
   jj log -r 'ancestors(TARGET) & ~ancestors(trunk()) & ~TARGET' --no-graph
   ```
   If any exist, warn the user:
   ```
   This PR will include N ancestor change(s) not part of this work:
   - <change-id>: <description>
   They'll be merged into trunk with the PR.
   ```
   Let the user decide whether to squash them into the target first or push them separately.

2. Ensure a bookmark exists on the target change:
   ```bash
   # Check for existing bookmark
   jj log -r <target> --no-graph -T 'bookmarks'
   ```
   If no bookmark: create one from the change description:
   ```bash
   jj bookmark create <kebab-case-name> -r <target>
   ```
   (Descriptive names make better PR branches. Only if the user explicitly
   wants a quick anonymous push: `jj git push --change <target>` generates a
   `push-<change-id>` bookmark and pushes it in one step.)

3. Push the bookmark:
   ```bash
   jj git push --bookmark <name>
   ```

4. Create the PR:
   ```bash
   gh pr create --head <bookmark-name> --title "<title>" --body "$(cat <<'EOF'
   ## Summary
   <2-3 bullets from the diff>

   ## Test plan
   - [ ] <verification steps>

   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   EOF
   )"
   ```

5. Output the PR URL.

6. **Post-merge cleanup.** After a successful `gh pr merge`.

   Do not pass `--delete-branch` to `gh pr merge`. It tries to delete a local
   *git* branch and fails (`could not determine current branch`, or `not on any
   branch` — wording varies by `gh` version), because a jj working copy is not
   on one. The merge itself still succeeds — only the branch cleanup fails, and
   step (e) below handles that.

   **Do not delete the remote branch by hand either — not with `--delete-branch`,
   not with `gh api -X DELETE`.** It must survive until step (e), and the reason
   is the fetch in (a). While the branch exists on the remote your local change
   is still reachable from it and the fetch is inert. Once it is gone, that
   fetch *itself* does the abandoning — `Abandoned 1 commits that are no longer
   reachable` / `Rebased 1 descendant commits` — dropping `@` onto the
   **pre-merge base** with every merged file reverted on disk, before step (b)
   has confirmed anything landed. And (b) can no longer run: the target's
   *change* id stops resolving. Tidying the branch early buys nothing and costs
   the one check standing between a bad merge and a destroyed change.

   **Where the repo deletes head branches for you, this is unavoidable.** Check
   with `gh repo view --json deleteBranchOnMerge`. If `true`, the branch is gone
   before you can fetch, so trade the gate for a restore point — capture both of
   these *before* step (a):
   ```bash
   jj op log -n 1 --no-graph -T 'id.short()'             # restore point
   jj log -r <target> --no-graph -T 'commit_id.short()'  # survives the abandon
   ```
   The **commit** id is deliberate, and the one place this repo's "hand around
   change ids" rule inverts: once the fetch abandons the change its change id is
   gone, while the commit id still resolves — so step (b) can still be asked,
   as `jj diff --from 'trunk()' --to <commit-id> --stat`. If that is not empty,
   `jj op restore <op-id>` puts the change back.

   a. **Fetch**, so `trunk()` names the merged trunk rather than the state you
      pushed from:
      ```bash
      jj git fetch
      ```

   b. **Verify trunk actually has the work — before abandoning anything.** A
      squash-merge rebuilds your changes as a new commit; nothing guarantees it
      matches what you pushed, and the next step is destructive. Which check
      is right depends on what you merged.

      **One PR, or a stack merged as one PR** — the target should now be
      identical to trunk:
      ```bash
      jj diff --from 'trunk()' --to <target> --stat
      ```
      Empty output means trunk's content equals the target's, so the local
      changes are redundant copies. **If it is not empty, stop and report** —
      something did not land, and abandoning would destroy the only copy.

      **Sibling PRs merged separately** — do NOT use the check above. It will
      report a failure on a perfectly clean merge: each sibling legitimately
      differs from trunk by the *other* sibling's content, so whole-tree
      equality is the wrong question. Ask instead whether each target's own
      contribution landed — for every file it touched, trunk's copy must match
      its copy:
      ```bash
      for f in $(jj diff -r <target> --summary | awk '{print $2}'); do
        diff -q <(jj file show -r <target> "$f") \
                <(jj file show -r 'trunk()' "$f") >/dev/null \
          && echo "ok      $f" || echo "DIFFERS $f"
      done
      ```
      Every file must report `ok`. A `DIFFERS` means either the merge dropped
      something, or a later change touched the same file — **stop and look**
      either way. Repeat per target; abandon only the targets that pass.

   c. **Abandon** the local changes now duplicated in trunk:
      ```bash
      jj abandon 'ancestors(<target>) & ~ancestors(trunk())'
      ```
      If (a) already reported `Abandoned N commits that are no longer
      reachable`, the remote branch was deleted before the fetch and this step
      has nothing left to do — skip it rather than resolving `<target>`, which
      no longer exists.

   d. **Move the working copy onto the merged trunk:**
      ```bash
      jj new trunk()
      ```
      This is not optional. Abandoning re-parents `@` onto whatever the bottom
      of the stack sat on — the *pre-merge* trunk — so `@` silently lands on a
      stale base and every file you just merged reads as reverted on disk. The
      work is safe in trunk; the working copy is simply looking at the wrong
      revision, which is far more alarming than it sounds. Whichever step did
      the abandoning — (c), or the fetch in (a) — this is the fix.

   e. **Delete the bookmark.** Abandoning the target usually takes the local
      bookmark with it (it pointed at an abandoned change), so this is often
      just the remote half:
      ```bash
      jj bookmark delete <name>   # only if it survived (c)
      jj git push --deleted
      ```

7. Then: Workspace cleanup (Step 5).

### Option 2: Merge into trunk locally (fast-forward)

Do NOT reach for `jj squash --into trunk()`. Measured on jj 0.44.0: `--into`
and `-r` are mutually exclusive (the command errors before doing anything),
and the corrected `--from <target> --into trunk()` form is then rejected with
`Error: Commit ... is immutable` — trunk is in `builtin_immutable_heads()`.
The jj-native local merge is a rebase plus a bookmark fast-forward, which
rewrites nothing that is shared:

1. Fetch latest trunk:
   ```bash
   jj git fetch
   ```

2. Rebase the work onto trunk:
   ```bash
   jj rebase -r <target> -d trunk()
   ```
   The ancestor concern from Option 1 applies here too: moving the bookmark
   to the target brings every ancestor with it, so if the ancestor check
   shows unrelated changes between trunk and the target, surface them first.

3. Fast-forward the trunk bookmark (read its name — usually `main` — from
   `jj log -r 'trunk()' --no-graph -T 'bookmarks'` before the move):
   ```bash
   jj bookmark move <trunk-bookmark> --to <target>
   ```

4. Verify against the **local bookmark, not `trunk()`**:
   ```bash
   jj log -r <trunk-bookmark> --limit 3 --no-graph
   ```
   `trunk()` keeps resolving to the *remote* bookmark (`main@origin`) until a
   push happens, so it still shows the pre-merge state on a successful local
   merge — checking it here reports a false failure.

5. Report that the merge is local only: the remote is unchanged until
   `jj git push --bookmark <trunk-bookmark>` (measured: the push is a clean
   `[move forward ...]`, no force needed). Push only if the user asks.

6. Then: Workspace cleanup (Step 5).

### Option 3: Keep as-is

Report:
```
Keeping change <change-id>. No cleanup performed.
```

**Do NOT clean up workspace.** Stop here.

### Option 4: Discard

`jj abandon` is **not** the destructive act it is in git. The operation log holds
the pre-abandon state, and `jj op restore` returns to it exactly — including
files that were never committed. Your job is to preserve that property and hand
it to the user, not to gate the discard behind a typed keyword.

1. **Capture the restore point before touching anything:**
   ```bash
   jj op log -n 1 --no-graph -T 'id.short()'
   ```
   `jj op log` snapshots the working copy before it reports, so the id it
   returns already covers the current state. **Do not add
   `--ignore-working-copy`** — it skips that snapshot and hands back a restore
   point that predates the most recent edits, which is exactly the work about to
   be discarded.

2. **State what is going, and whether a copy survives anywhere.** Read the
   target's bookmarks from Context — do not assert either line below without
   having looked:
   ```
   Discarding <change-id>: <description> — <N> files changed.
   Not pushed; this is the only copy.        # no bookmark, or bookmark never pushed
   Pushed as <bookmark>; the remote still has it.   # a pushed bookmark exists
   ```

3. **Abandon:**
   ```bash
   jj abandon <target>
   ```
   This also drops the local bookmark. **Pushing that deletion is a second,
   separate act of destruction** — `jj git push --deleted` (or pushing the
   deleted bookmark) removes the remote's copy, which for pushed work was the
   only surviving one. Do it only if the user asked for the branch to be gone
   from the remote too, and say plainly that you did.

4. **Hand back the exact recovery command**, with the id from step 1 — not a
   bare pointer to `/undo`, which only reaches the *last* operation and is wrong
   as soon as anything else runs.

   Work that was never pushed:
   ```
   If you want it back: jj op restore <id>
   ```

   **If you deleted a pushed bookmark, `--what repo` is not optional.** A bare
   `jj op restore` also restores remote-tracking refs, so jj starts believing
   the remote still holds the branch. The next `jj git push` then answers
   `Nothing changed.` while the remote stays empty — silent loss behind a
   success message. `jj op restore --help` says it outright: *"Do not restore
   these if you'd like to push after the undo."*
   ```
   If you want it back: jj op restore <id> --what repo
   then re-publish:     jj git push --bookmark <name>
   ```

Then: Workspace cleanup (Step 5).

## Step 5: Workspace cleanup

**For Options 1, 2, and 4 only.**

1. **Identify the current workspace by root, not by name.** Read the two
   workspace lines from Context: the current workspace is the row of the
   list whose root equals the current workspace root. (The list template is
   pinned deliberately — jj 0.44 changed what `jj workspace list` prints by
   default, and this step depends on the root field being present.) On macOS,
   `/tmp` is a symlink to `/private/tmp` — treat the two spellings of a path
   as the same location when matching.

   If the current workspace is `default`, no cleanup is needed. Stop here.

2. **Branch on provenance — who created the workspace decides who ends it:**

   - **Root under `/tmp/jj-workspaces/`** — an ephemeral workspace the
     WorktreeCreate hook made (`claude --worktree`, `EnterWorktree`). Ours to
     clean up:
     ```bash
     jj workspace forget <workspace-name>
     ```
   - **Any other root** — a durable side thread (e.g. a `jjtab` sibling
     directory). Ending one with `/finish` is a documented use, but the thread
     outlives any single change, so ending it is the user's call, not a side
     effect — ask:
     ```
     This session is in the durable workspace <name> (<root>).
     Finish the side thread too (forget the workspace), or keep it for more work?
     ```
     Forget only on a yes. Keeping it is not a failure — report the change as
     finished and the workspace as kept.

3. **Report what was cleaned up.** Never remove the workspace directory
   itself — the WorktreeRemove hook owns ephemeral directories, and a durable
   directory's removal is the user's to do by hand.

## Quick Reference

| Option | Push | Merge | Keep Workspace | Cleanup |
|--------|------|--------|----------------|---------|
| 1. PR | ✓ | - | ✓ | bookmark only |
| 2. Local merge | - | ✓ | - | ✓ |
| 3. Keep | - | - | ✓ | - |
| 4. Discard | - | - | - | ✓ |

## Important Rules

- **Never use raw git commands.** Always jj equivalents.
- **Never force-push.** Use `jj git push` only.
- **Make discard recoverable; don't gate it.** Capture `jj op log -n 1 --no-graph -T 'id.short()'` before abandoning, then hand back `jj op restore <id>`. A typed-confirmation prompt is a git habit — in jj the op log is the safety net, and it works whether or not anyone was asked.
- **If the discard removed a pushed bookmark from the remote, the recovery command is `jj op restore <id> --what repo`.** The bare form restores remote-tracking refs too, and the following `jj git push` reports `Nothing changed.` over a remote that is still empty.
- **Don't auto-remove worktree directories.** Let the WorktreeRemove hook handle it.
- **Provenance gates workspace cleanup.** Auto-forget only ephemeral workspaces (root under `/tmp/jj-workspaces/`); a durable workspace is forgotten only after the user says so.
- **Menu after green.** Run the project's test suite (Step 2) before presenting options; skip the gate only when no suite is detected. Reviews remain the caller's responsibility.

## Integration

**Replaces:** `superpowers:finishing-a-development-branch` in jj repos.

**Called by:**
- `superpowers:subagent-driven-development` (after all tasks complete)
- `superpowers:executing-plans` (after all batches complete)
- Manual invocation when work is done

**Pairs with:**
- `workspace-jj` — workspace creation and cleanup hooks
- `/commit-push-pr` — if you just want to push without the options menu
