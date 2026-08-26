# Commit Commands Plugin (jj)

Streamline your jj (Jujutsu) workflow with simple commands for committing, navigating changes, syncing with trunk, and creating pull requests.

## Overview

The Commit Commands Plugin for jj automates common Jujutsu operations, reducing context switching and manual command execution. Instead of running multiple jj commands, use a single slash command to handle your entire workflow.

**Key difference from Git**: In jj, the working copy IS already a commit. There is no staging area. All changes are automatically tracked. The `/commit` command finalizes the current change with a description and starts a new empty change on top.

**Requires [`project-setup-jj`](../project-setup-jj/).** Install it alongside this plugin. Claude Code plugin manifests have no dependency field, so this is stated rather than enforced — nothing will warn you.

The dependency is the raw-`git` wall. Until #128 this plugin shipped and registered its own copy of `block-raw-git.sh` so it would stand alone; it now relies on `project-setup-jj`'s copy, which is the same hook and fires on every `Bash` call as soon as that plugin is enabled. Installed on its own, this plugin still works, but a reflexive `git commit` goes through unblocked — and these commands are written on the assumption that it cannot.

**Scope of the hook.** It denies `git` where the shell would start a command: on its own, after `;` `&&` `||` `|` or a newline, inside `$(…)` or `<(…)`, inside `(…)` or `{ …; }`, and after a keyword, wrapper or `VAR=value` prefix. A clause beginning `jj git …` is never denied — `/commit-push-pr` and `/finish` rely on that.

It matches text rather than parsing the shell, so some shapes are out of scope (backtick substitution, `bash -c 'git …'`, wrappers with their own options, `/usr/bin/git`), and because it is quote-blind it can over-catch: a git command named right after a separator *inside* a quoted message still reads as command position. Full scope note in the [project-setup-jj README](../project-setup-jj/README.md#overview); the authoritative list is the comment block in that plugin's `scripts/block-raw-git.sh`. The must-allow shapes `/commit-push-pr` and `/finish` write are pinned by assertions in `project-setup-jj/tests/test-block-raw-git.sh`.

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
- For a quick anonymous push, skips bookmark creation and pushes directly with `jj git push --change @-` (generates a `push-<change-id>` bookmark)
- Works with colocated repos out of the box
- For non-colocated repos, provides guidance on `GIT_DIR` setup

**Requirements:**
- GitHub CLI (`gh`) must be installed and authenticated
- Repository must have a remote configured

### `/finish`

Finishes development work by presenting a menu of completion options and executing the chosen workflow. Replaces `superpowers:finishing-a-development-branch` for jj repos.

**What it does:**
1. Verifies the target change (current or parent, if `@` is empty) has content against trunk
2. Runs the project's test suite — the menu only appears after a green run (skipped when no suite is detected)
3. Presents four options: push and create a PR, merge into trunk locally, keep as-is, or discard
4. Executes the chosen workflow:
   - **Push and create PR:** warns about non-target ancestor changes that would be swept into the PR, creates a bookmark if needed (or uses `jj git push --change <target>` for a quick anonymous push), pushes with `jj git push --bookmark`, and opens the PR with `gh pr create`
   - **Merge into trunk locally:** fetches, rebases the change onto trunk, and fast-forwards the trunk bookmark with `jj bookmark move` (not `jj squash --into trunk()` — trunk is immutable, so that form errors)
   - **Keep as-is:** reports the change ID and stops — no cleanup
   - **Discard:** records a restore point from the op log, runs `jj abandon`, and hands back the exact `jj op restore <id>` that undoes it
5. For push, merge, and discard, cleans up the jj workspace if running in a non-default one (`jj workspace forget`) — auto-forgetting only ephemeral hook-created workspaces, and asking before ending a durable side thread

**Usage:**
```bash
/finish
```

**Example workflow:**
```bash
# Work is done and tested:
/finish

# Claude will:
# - Confirm there's work to finish (against trunk)
# - Run the project's test suite (menu only appears after a green run)
# - Ask which of the 4 options you want
# - Execute it (push+PR, local merge, keep, or discard)
# - Clean up the workspace if applicable
```

**Features:**
- Never force-pushes — uses `jj git push` only
- Makes discarding recoverable rather than gating it — captures an op id first, then reports `jj op restore <id>`
- Detects and warns about ancestor changes not part of the target work before pushing
- After a PR merges, abandons the now-landed local ancestor changes as part of cleanup
- Gates the menu behind the project's test suite (skipped only when no suite is detected); reviews remain the caller's concern
- Workspace cleanup respects provenance — auto-forgets only ephemeral hook-created workspaces (`/tmp/jj-workspaces/`), and asks before ending a durable side thread

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

### `/absorb`

Distributes the working copy's edits into the mutable ancestor changes that last touched those lines.

**What it does:**
1. Reports "nothing to absorb" if the current change has no diff
2. Runs `jj absorb` (optionally scoped to specific paths, or `--into <revset>` to restrict target changes)
3. Reports which changes absorbed what, from the command's output
4. Flags any edits left in the working copy afterward — lines with no single clear ancestor are left behind by design; suggests `/squash` for those

**Usage:**
```bash
/absorb
```

**Example workflow:**
```bash
# Fixed a bug that touches three earlier changes in a stack:
/absorb

# Claude will:
# - Distribute your edits into the changes that last touched those lines
# - Report which change absorbed what
# - Flag any leftover edits that need a manual /squash
```

**Features:**
- jj's built-in equivalent of `git absorb` — no plugin needed
- Fixes the "I amended three stacked changes in one sitting" problem
- Scope with `--into <revset>` or specific paths
- Leftover edits (no clear single ancestor) are reported, not silently dropped

### `/undo`

Undoes the last jj operation by restoring the repository to its previous state.

**What it does:**
1. Reviews the operation log to identify the last operation
2. Runs `jj op revert <op-id>` to reverse it
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
1. Records a restore point from the op log before touching anything
2. Warns if the change has modifications that will be lost
3. Runs `jj abandon` to discard the change
4. Shows the result and hands back the exact `jj op restore <id>` that reverses it

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
1. Fetches latest remote state with `jj git fetch` — which is also the entire bookmark cleanup, since fetch drops the local bookmark whose remote counterpart was deleted
2. Lists workspaces to find stale ones
3. Forgets stale workspaces with `jj workspace forget`

**Usage:**
```bash
/clean_stale
```

**Example workflow:**
```bash
# After PRs are merged and remote bookmarks are deleted
/clean_stale

# Claude will:
# - Fetch latest remote state (bookmarks deleted on the remote go with it)
# - Find and forget stale workspaces
# - Report what was cleaned up
```

**Features:**
- jj auto-prunes remote tracking refs during fetch (no `--prune` needed, and no follow-up `jj bookmark delete` — there is nothing left to delete)
- Handles the half jj does *not* do for you: workspaces registered to directories that no longer exist
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

### Using `/finish`
- Use when work is complete and tested — it presents the completion options rather than assuming one
- Discarding is recoverable: it records an op id before abandoning and gives you `jj op restore <id>`, which stays correct even after later operations
- Prefer this over `/commit-push-pr` when you also want the squash-into-trunk, keep, or discard paths

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

### Using `/absorb`
- Use for stacked changes — fold a fix into whichever ancestor last touched those lines
- Restrict scope with `--into <revset>` or specific paths when you don't want it touching the whole stack
- Check for leftover edits afterward — not every line has a single clear ancestor

### Using `/undo`
- Safe to run — the undo itself can be undone
- Check `jj op log` to understand what will be reversed
- For older operations, use `jj op restore <op-id>` directly

### Using `/abandon`
- Always check the diff before abandoning — modifications will be lost
- Recover with the `jj op restore <id>` it hands you, not with bare `jj undo` — `jj undo` reverses whatever the *latest* operation is, so once any other command has run it silently reverses that instead and reports success while the abandoned work stays gone
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
- Mostly worth running for the workspace half — the bookmark half is what `jj git fetch` already does on its own
- Especially useful after deleting workspace directories by hand
- Safe to run — it prunes only what the remote already deleted, and forgets only workspaces you point it at

## jj Concepts for Git Users

The table below is a short orientation for the concepts these commands rely on. For a **command-by-command** mapping, use jj's own [git command table](https://docs.jj-vcs.dev/latest/git-command-table/) — it is more complete, carries a Notes column, and tracks jj releases. Two things it does not cover that matter here:

- **`jj undo` is sequential.** It reverses whatever the *latest* operation happens to be, so once any other command has run it reverses that instead — silently, while reporting success. Prefer `jj op revert <op-id>`, or an op id captured before the change. See `/undo` and `/abandon`.
- **Deleting a pushed bookmark is recoverable only with care.** A bare `jj op restore` also restores remote-tracking refs, leaving jj convinced the remote still has the branch; the next push answers `Nothing changed.` over an empty remote. Use `jj op restore <id> --what repo`, then re-push. See `/finish`.

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
| `git reset HEAD~1` | `jj op revert` |
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
