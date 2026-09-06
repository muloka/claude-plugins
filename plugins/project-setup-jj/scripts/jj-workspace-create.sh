#!/usr/bin/env bash
set -euo pipefail

# WorktreeCreate hook: create a jj workspace for Claude Code worktree isolation.
# Input (stdin): JSON with "name" and "cwd" fields
# Output (stdout): absolute path of the created workspace directory
#
# Hooks win: when WorktreeCreate is configured, `claude --worktree` and
# `EnterWorktree` call this even in a colocated repo — measured 2026-09-06.
# The session that lands here is worktree-ISOLATED: the harness refuses every
# `jj git` command inside it (it reads the `git` token as a git invocation).
# The SessionStart briefing says so; /finish leaves the worktree before pushing.

input=$(cat)
name=$(echo "$input" | jq -r '.name')
cwd=$(echo "$input" | jq -r '.cwd')

# Create the workspace OUTSIDE the repo so jj's auto-snapshot in the default
# workspace never attributes workspace edits to the default @. /tmp is not
# under any repo root. (macOS reports this path back as /private/tmp/...;
# every consumer matches both spellings.)
DIR="/tmp/jj-workspaces/$(basename "$cwd")/$name"
mkdir -p "$(dirname "$DIR")"

# Base revision: trunk, guarded — then @-, then jj's default.
#
# Why trunk and not @-: a thread based on @- inherits whatever is parked on
# the default workspace, including an undescribed empty change that later
# blocks `jj git push`. trunk never carries that.
#
# Why `trunk() ~ root()` and not `trunk()`: in a repo with no remote trunk()
# does not fail — it resolves to the ROOT COMMIT with exit 0, and a workspace
# added there has no project files at all. Subtracting root() turns that case
# into an empty string, which is the signal the fallback below needs. A local
# `main` that is ahead of origin (merged locally, push not yet asked for) is a
# transient state; a deliberate stacked follow-up on current context is
# `jjtab <name> '@-'` territory, not this hook's.
base=$(jj -R "$cwd" log -r 'trunk() ~ root()' --no-graph -T 'commit_id' 2>/dev/null || true)
if [ -z "$base" ]; then
  base=$(jj -R "$cwd" log -r '@-' --no-graph -T 'commit_id' 2>/dev/null || true)
fi

if [ -n "$base" ]; then
  jj -R "$cwd" workspace add "$DIR" --name "workspace-$name" --revision "$base" >&2
else
  # Nothing resolved (empty repo?): let jj pick.
  jj -R "$cwd" workspace add "$DIR" --name "workspace-$name" >&2
fi

echo "$DIR"
