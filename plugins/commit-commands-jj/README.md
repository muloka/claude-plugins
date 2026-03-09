# Commit Commands Plugin (jj)

Streamline your jj (Jujutsu) workflow with simple commands for committing, navigating changes, syncing with trunk, and creating pull requests.

## Overview

The Commit Commands Plugin for jj automates common Jujutsu operations, reducing context switching and manual command execution. Instead of running multiple jj commands, use a single slash command to handle your entire workflow.

**Key difference from Git**: In jj, the working copy IS already a commit. There is no staging area. All changes are automatically tracked. The `/commit` command finalizes the current change with a description and starts a new empty change on top.

## Setup

### Colocated repos (`.jj/` + `.git/`)

If you initialized with `jj git clone` or `jj git init --colocate`, everything works out of the box — including `gh` CLI for PR creation.

### Non-colocated repos (`.jj/` only)

For `/commit-push-pr`, the `gh` CLI needs access to Git state. Either:

1. **Set `GIT_DIR`** before running:
   ```bash
   export GIT_DIR=.jj/repo/store/git
   ```

2. **Or run `jj git export`** before using `gh` commands to sync jj state to the backing Git repo.

## Commands

### `/commit`

Finalizes the current jj change with an automatically generated description.

**What it does:**
1. Reviews the current jj status and diff
2. Examines recent change descriptions to match your repository's style
3. Runs `jj commit -m "<msg>"` to describe the current change and start a new empty one

**Usage:**
```bash
/commit
```

**Example workflow:**
```bash
# Make some changes to your code
# (jj automatically tracks everything — no staging needed)
# Then simply run:
/commit

# Claude will:
# - Review your changes via jj diff
# - Create a commit with an appropriate description
# - A new empty change is created on top
```

**Features:**
- Automatically drafts descriptions that match your repo's style
- No staging step — all working copy changes are included
- For partial commits, use `jj split` before running `/commit`

### `/commit-push-pr`

Complete workflow command that commits, pushes, and creates a pull request in one step.

**What it does:**
1. Finalizes the working copy with `jj commit -m "<msg>"`
2. Checks if the change is on trunk and needs a bookmark
3. Creates a bookmark on the committed change if needed
4. Pushes the bookmark with `jj git push`
5. Creates a pull request using `gh pr create`

**Usage:**
```bash
/commit-push-pr
```

**Example workflow:**
```bash
# Make your changes
# Then run:
/commit-push-pr

# Claude will:
# - Finalize your change with a description
# - Create a bookmark (jj's equivalent of a branch name)
# - Push to remote
# - Open a PR with summary and test plan
# - Give you the PR URL to review
```

**Features:**
- Uses jj revsets (`trunk()`) for idiomatic trunk detection
- Creates bookmarks automatically when needed
- Works with colocated repos out of the box
- For non-colocated repos, provides guidance on `GIT_DIR` setup

**Requirements:**
- GitHub CLI (`gh`) must be installed and authenticated
- Repository must have a remote configured

### `/describe`

Sets or updates the description of the current jj change without finalizing it.

**What it does:**
1. Reviews the current jj status and diff
2. Runs `jj describe -m "<msg>"` to set a description on the current change
3. The change ID stays the same — you remain on the same change

**Usage:**
```bash
/describe
```

**Example workflow:**
```bash
# Start working on something
# Label what you're doing:
/describe

# Claude will:
# - Review your current changes
# - Set an appropriate description
# - You stay on the same change (unlike /commit)
```

**Features:**
- Does NOT finalize the change or start a new one (unlike `/commit`)
- Useful for labeling work-in-progress changes
- Identifies changes in anonymous branches (jj favors descriptions over bookmarks)
- Update the message before pushing

### `/new`

Starts a new empty change on top of the current one (or a specified revision).

**What it does:**
1. Runs `jj new` to create a new empty change
2. Optionally sets a description if you state your intent
3. Confirms the new change with `jj log`

**Usage:**
```bash
/new
/new main    # start on top of main
```

**Example workflow:**
```bash
# After finishing work on a change:
/new

# Claude will:
# - Create a new empty change on top
# - Optionally describe it if you said what you're working on next
# - Show the new change
```

**Features:**
- No need to commit first — jj auto-snapshots the working copy
- Accepts an optional target revision to start from a different point
- The previous change keeps all its content

### `/edit`

Moves the working copy to an earlier change so you can amend it in place.

**What it does:**
1. Runs `jj edit <revision>` to switch to the target change
2. Shows the status and diff of the change
3. Reminds you to run `/new` when done

**Usage:**
```bash
/edit <revision>
```

**Example workflow:**
```bash
# Need to fix something in a previous change:
/edit qpvuntsm

# Claude will:
# - Switch the working copy to that change
# - Show what's in the change
# - Remind you to /new when done
```

**Features:**
- Amends the target change in place — no cherry-picking needed
- Descendants are automatically rebased
- Does NOT auto-return to the tip — you control when you're done

### `/sync`

Fetches the latest remote state and rebases your current work onto trunk.

**What it does:**
1. Runs `jj git fetch` to get the latest remote state
2. Rebases onto `main@origin` (falls back to `trunk()`)
3. Checks for conflicts with `jj log -r 'conflicts()'`
4. Shows the final state with `jj log`

**Usage:**
```bash
/sync
```

**Example workflow:**
```bash
# Before starting work or before pushing:
/sync

# Claude will:
# - Fetch from remote
# - Rebase onto trunk
# - Report any conflicts or confirm success
# - Show the updated log
```

**Features:**
- Equivalent of `git pull --rebase` in a single command
- Auto-prunes deleted remote tracking refs
- Reports conflicts clearly (jj records conflicts in commits, not the working copy)

### `/squash`

Squashes the current change into its parent, combining their content and descriptions.

**What it does:**
1. Checks if the current change has modifications
2. Runs `jj squash` to move changes into the parent
3. Cleans up the combined description if needed
4. Shows the result

**Usage:**
```bash
/squash
/squash --into <rev>    # squash into a specific change
```

**Example workflow:**
```bash
# After making a small fixup:
/squash

# Claude will:
# - Move your changes into the parent change
# - Clean up the description if the merge was awkward
# - Show the final state
```

**Features:**
- Idiomatic way to fold fixups into a previous change
- Reports "nothing to squash" if the current change is empty
- Supports `--into <rev>` for squashing into a non-parent change
- Automatically cleans up combined descriptions

### `/undo`

Undoes the last jj operation by restoring the repository to its previous state.

**What it does:**
1. Reviews the operation log to identify the last operation
2. Runs `jj undo` to reverse it
3. Confirms the result and reports what was undone

**Usage:**
```bash
/undo
```

**Example workflow:**
```bash
# After an accidental squash or abandon:
/undo

# Claude will:
# - Show the last operation
# - Reverse it
# - Confirm the repository state
```

**Features:**
- Every jj operation is recorded — nothing is truly lost
- Undo itself is an operation and can be undone
- For older operations, use `jj op restore <op-id>` (op IDs shown in `jj op log`)
- Much safer than git's reflog-based recovery

### `/abandon`

Discards a jj change entirely, rebasing descendants onto its parent.

**What it does:**
1. Warns if the change has modifications that will be lost
2. Runs `jj abandon` to discard the change
3. Shows the result and reminds you about `/undo`

**Usage:**
```bash
/abandon
/abandon <revision>    # abandon a specific change
```

**Example workflow:**
```bash
# Discard a change you no longer need:
/abandon

# Claude will:
# - Warn if the change has content
# - Abandon it
# - Show the updated log
# - Remind you about /undo for recovery
```

**Features:**
- Descendants are rebased onto the abandoned change's parent
- Abandoning the working copy (`@`) auto-creates a new empty change
- Recoverable with `/undo` — nothing is permanently lost
- Accepts a revset for abandoning multiple changes

### `/show`

Inspects a single revision with JSON-structured metadata and file summary.

**What it does:**
1. Shows revision metadata (change ID, commit ID, author, description, parents) via JSON
2. Lists modified/added/deleted files
3. Optionally shows the full diff on request

**Usage:**
```bash
/show          # inspect current change (@)
/show qpvuntsm # inspect a specific revision
```

**Features:**
- Same Commit JSON type as `jj log` — structured, machine-parseable
- Combines metadata + file summary in one command
- Accepts any revset expression

### `/evolog`

Shows how a change has evolved over time — every rebase, describe, squash, and conflict resolution.

**What it does:**
1. Presents the evolution history of a change in chronological order
2. Highlights what changed at each step (description update, rebase, content change)
3. Summarizes the change's journey

**Usage:**
```bash
/evolog          # evolution of current change (@)
/evolog qpvuntsm # evolution of a specific change
```

**Features:**
- jj's equivalent of per-commit reflog — full history of a single change
- Useful for debugging "what happened to this change?" after syncs or collaboration
- Each entry includes the operation that caused the mutation
- The change ID stays the same across all versions — only the commit ID changes

### `/op-show`

Inspects a single operation from the operation log with JSON output.

**What it does:**
1. Shows operation details: ID, timestamp, user, description
2. Pairs with `/undo` — inspect before deciding whether to reverse

**Usage:**
```bash
/op-show          # inspect most recent operation
/op-show <op-id>  # inspect a specific operation
```

**Features:**
- Same Operation JSON type as `jj op log` — structured, machine-parseable
- Every repository mutation is recorded as an operation
- Use `jj op diff` for before/after comparison

### `/tag-list`

Lists all tags in the repository with JSON-structured output.

**What it does:**
1. Shows all tags with their target commit metadata
2. Reports if no tags exist

**Usage:**
```bash
/tag-list
```

**Features:**
- Same CommitRef JSON type as `jj bookmark list`
- Use `jj show -r <tag-name>` for details on a tag's target

### `/clean_stale`

Cleans up stale local bookmarks and workspaces (replaces `/clean_gone` from the Git plugin).

**What it does:**
1. Fetches latest remote state with `jj git fetch`
2. Lists all bookmarks to find those deleted on the remote
3. Lists workspaces to find stale ones
4. Deletes stale bookmarks with `jj bookmark delete`
5. Forgets stale workspaces with `jj workspace forget`

**Usage:**
```bash
/clean_stale
```

**Example workflow:**
```bash
# After PRs are merged and remote bookmarks are deleted
/clean_stale

# Claude will:
# - Fetch latest remote state
# - Find bookmarks deleted on remote
# - Remove stale bookmarks and workspaces
# - Report what was cleaned up
```

**Features:**
- jj auto-prunes remote tracking refs during fetch (no `--prune` needed)
- Handles both bookmarks and workspaces
- Reports if no cleanup was needed

**When to use:**
- After merging and deleting remote branches/bookmarks
- When your bookmark list is cluttered with stale entries
- During regular repository maintenance

## Installation

```bash
claude plugins add ./plugins/commit-commands-jj
```

## Best Practices

### Using `/commit`
- Let Claude review your changes and match your repo's description style
- For partial commits, use `jj split` first, then `/commit`
- Use for routine commits during development

### Using `/describe`
- Use to label work-in-progress changes before they're ready to commit
- Prefer descriptions over bookmarks for identifying changes (idiomatic jj)
- Update descriptions before pushing to ensure clean history

### Using `/commit-push-pr`
- Use when you're ready to create a PR
- Ensure all your changes are complete and tested
- Review the PR description and edit if needed

### Using `/new`
- Run after `/commit` to start fresh work
- Use `/new <rev>` to branch from a specific change
- Combine with `/describe` to label what you're about to work on

### Using `/edit`
- Use to amend earlier changes without cherry-picking
- Always run `/new` when done to return to the tip
- Descendants are rebased automatically — check for conflicts after editing

### Using `/sync`
- Run before starting new work to stay up to date
- Run before pushing to avoid conflicts
- If conflicts are reported, resolve them before continuing

### Using `/squash`
- Use to fold small fixups into the parent change
- Check the combined description after squashing
- For squashing into non-parent changes, specify `--into <rev>`

### Using `/undo`
- Safe to run — the undo itself can be undone
- Check `jj op log` to understand what will be reversed
- For older operations, use `jj op restore <op-id>` directly

### Using `/abandon`
- Always check the diff before abandoning — modifications will be lost
- Use `/undo` immediately if you abandoned by mistake
- Descendants are rebased onto the parent, not deleted

### Using `/show`
- Use to quickly inspect any revision's metadata and file changes
- Accepts change IDs, commit IDs, bookmarks, or revsets
- For full diff content, ask after seeing the summary

### Using `/evolog`
- Use to debug "what happened to this change?" after unexpected state
- Especially useful after syncs, rebases, or multi-agent collaboration
- Pairs well with `/undo` — understand evolution before reversing

### Using `/op-show`
- Use to inspect an operation before deciding to `/undo` it
- Find operation IDs with `jj op log`
- For comparing before/after state, use `jj op diff`

### Using `/tag-list`
- Use to see all tags in the repository
- For tag details, follow up with `/show <tag-name>`

### Using `/clean_stale`
- Run periodically to keep your bookmark list clean
- Especially useful after merging multiple PRs
- Safe to run — only removes bookmarks already deleted remotely

## jj Concepts for Git Users

| Git | jj |
|---|---|
| staging area | No equivalent — working copy IS a commit |
| `git add` | Not needed — all changes automatically tracked |
| `git commit` | `jj commit` — finalizes current change, starts new one |
| `git commit --amend` | `jj describe` or `jj squash` |
| `git checkout -b` | `jj new` — start a new change |
| `git checkout <commit>` | `jj edit` — move working copy to a change |
| `git pull --rebase` | `jj git fetch` + `jj rebase` |
| `git rebase -i` (squash) | `jj squash` |
| `git reset HEAD~1` | `jj undo` |
| `git reflog` | `jj op log` |
| branch | bookmark |
| `git branch` | `jj bookmark` |
| `git push` | `jj git push` |
| `git fetch --prune` | `jj git fetch` (auto-prunes) |
| `[gone]` branches | Bookmarks deleted on remote |
| worktree | workspace |

## Requirements

- jj (Jujutsu) must be installed and configured
- For `/commit-push-pr`: GitHub CLI (`gh`) must be installed and authenticated
- Repository must be a jj repository with a remote

## Author

[muloka](https://github.com/muloka)

## Version

1.0.0
