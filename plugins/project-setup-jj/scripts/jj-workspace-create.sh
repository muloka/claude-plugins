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

# Base revision: trunk, guarded — then @-, guarded the same way — then @
# itself, guarded the same way — then jj's default.
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
#
# Why `@- ~ root()` and not plain `@-`: the tier-2 fallback carries the same
# guard for the same reason — in a fresh repo (only `@` with files, parent =
# root) `@-` IS the root commit, and without the subtraction this tier would
# silently produce the same empty workspace tier 1 exists to avoid.
#
# Why a third `@ ~ root()` tier, and why NOT simply fall through to jj's
# no-revision default at that point: `jj workspace add` with no --revision
# makes the new workspace a SIBLING of the source @ — same parents, not a
# copy of @ itself (measured 2026-09-05, jj 0.44: help text says "share the
# same parent(s)"). In the exact fresh-repo case above (only `@` with files,
# parent = root) that reproduces the empty-tree bug via a different route,
# because @'s parent is root. Passing `--revision "$base"` with base = @
# instead makes the new workspace a CHILD of @, which checks out @'s content.
# Only a truly virgin repo — @ itself is root, nothing committed at all — has
# nothing left for any tier to resolve, and that case still falls through to
# jj's default.
#
# This hook is also reached through `isolation: "worktree"` subagent
# dispatch, not only `claude --worktree` / EnterWorktree — an isolated
# subagent therefore starts from trunk, not from the orchestrator's local
# stack, and no longer sees the orchestrator's unpushed work. kaisen is
# unaffected: it calls `jj workspace add` itself and never reaches this hook.
base=$(jj -R "$cwd" log -r 'trunk() ~ root()' --no-graph -T 'commit_id' 2>/dev/null || true)
if [ -z "$base" ]; then
  base=$(jj -R "$cwd" log -r '@- ~ root()' --no-graph -T 'commit_id' 2>/dev/null || true)
fi
if [ -z "$base" ]; then
  base=$(jj -R "$cwd" log -r '@ ~ root()' --no-graph -T 'commit_id' 2>/dev/null || true)
fi

if [ -n "$base" ]; then
  jj -R "$cwd" workspace add "$DIR" --name "workspace-$name" --revision "$base" >&2
else
  # Nothing resolved (truly virgin repo — @ itself is root): let jj pick.
  jj -R "$cwd" workspace add "$DIR" --name "workspace-$name" >&2
fi

echo "$DIR"
