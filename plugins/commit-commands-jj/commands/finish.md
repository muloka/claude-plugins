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
- Is this a workspace?: !`jj workspace list --no-pager -T 'self.name() ++ "\n"'`

## Overview

**This skill replaces `superpowers:finishing-a-development-branch` for jj repos.**

Guide completion of development work by presenting clear options and executing the chosen workflow.

**Core principle:** Verify work exists → Present options → Execute choice → Clean up.

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

## Step 2: Present options

Present exactly these 4 options:

```
What would you like to do?

1. Push and create a Pull Request
2. Squash into trunk (local merge)
3. Keep as-is (I'll handle it later)
4. Discard this work
```

## Step 3: Execute choice

### Option 1: Push and create PR (most common)

1. Ensure a bookmark exists on the target change:
   ```bash
   # Check for existing bookmark
   jj log -r <target> --no-graph -T 'bookmarks'
   ```
   If no bookmark: create one from the change description:
   ```bash
   jj bookmark create <kebab-case-name> -r <target>
   ```

2. Push the bookmark:
   ```bash
   jj git push --bookmark <name> --allow-new
   ```

3. Create the PR:
   ```bash
   gh pr create --title "<title>" --body "$(cat <<'EOF'
   ## Summary
   <2-3 bullets from the diff>

   ## Test plan
   - [ ] <verification steps>

   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   EOF
   )"
   ```

4. Output the PR URL.

5. Then: Workspace cleanup (Step 4).

### Option 2: Squash into trunk (local merge)

1. Fetch latest trunk:
   ```bash
   jj git fetch
   ```

2. Rebase the work onto trunk and squash:
   ```bash
   jj rebase -r <target> -d trunk()
   jj squash --into trunk() -r <target>
   ```

3. Verify the squash landed:
   ```bash
   jj log -r 'trunk()' --limit 3 --no-graph
   ```

4. Then: Workspace cleanup (Step 4).

### Option 3: Keep as-is

Report:
```
Keeping change <change-id>. No cleanup performed.
```

**Do NOT clean up workspace.** Stop here.

### Option 4: Discard

**Confirm first:**
```
This will permanently discard:
- Change <change-id>: <description>
- <N> files changed

Type 'discard' to confirm. (Recoverable via /undo)
```

Wait for exact confirmation.

If confirmed:
```bash
jj abandon <target>
```

Then: Workspace cleanup (Step 4).

## Step 4: Workspace cleanup

**For Options 1, 2, and 4 only.**

Check if running inside a jj workspace (from context above — if workspace list shows more than just "default"):

```bash
jj workspace list --no-pager -T 'self.name() ++ "\n"'
```

If in a non-default workspace:
```bash
# Get the workspace name
# Forget the workspace from the repo
jj workspace forget <workspace-name>
```

Report what was cleaned up. If the worktree directory should be removed, note it but do NOT remove it automatically — the WorktreeRemove hook handles that.

If in the default workspace, no cleanup needed.

## Quick Reference

| Option | Push | Squash | Keep Workspace | Cleanup |
|--------|------|--------|----------------|---------|
| 1. PR | ✓ | - | ✓ | bookmark only |
| 2. Squash | - | ✓ | - | ✓ |
| 3. Keep | - | - | ✓ | - |
| 4. Discard | - | - | - | ✓ |

## Important Rules

- **Never use raw git commands.** Always jj equivalents.
- **Never force-push.** Use `jj git push` only.
- **Get typed confirmation for discard.** Always remind that `/undo` can recover.
- **Don't auto-remove worktree directories.** Let the WorktreeRemove hook handle it.
- **Keep it focused.** This skill finishes work. It does not run tests or do reviews — those are the caller's responsibility.

## Integration

**Replaces:** `superpowers:finishing-a-development-branch` in jj repos.

**Called by:**
- `superpowers:subagent-driven-development` (after all tasks complete)
- `superpowers:executing-plans` (after all batches complete)
- Manual invocation when work is done

**Pairs with:**
- `workspace-jj` — workspace creation and cleanup hooks
- `/commit-push-pr` — if you just want to push without the options menu
