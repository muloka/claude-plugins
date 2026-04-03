#!/usr/bin/env bash
set -euo pipefail

# WorktreeCreate hook: Create a jj workspace for Claude Code worktree isolation
# Input (stdin): JSON with "name" and "cwd" fields
# Output (stdout): Absolute path to created workspace directory

input=$(cat)
name=$(echo "$input" | jq -r '.name')
cwd=$(echo "$input" | jq -r '.cwd')

# Create workspace OUTSIDE the repo to prevent jj's auto-snapshotting in the
# default workspace from attributing workspace file edits to @.
# Using /tmp ensures the workspace directory is not under the repo root.
DIR="/tmp/jj-workspaces/$(basename "$cwd")/$name"
mkdir -p "$(dirname "$DIR")"

# Pin workspace to the current working copy's parents (not the working copy itself).
# Without --revision, concurrent workspaces can see each other's changes and chain
# instead of branching independently. Pinning ensures each workspace creates an
# independent change from the same base — the fan-out pattern fan-flames expects.
parent_rev=$(jj -R "$cwd" log -r '@-' --no-graph -T 'commit_id' 2>/dev/null || echo "")

if [ -n "$parent_rev" ]; then
  jj -R "$cwd" workspace add "$DIR" --name "workspace-$name" --revision "$parent_rev" >&2
else
  # Fallback: no parent found (empty repo?), use default behavior
  jj -R "$cwd" workspace add "$DIR" --name "workspace-$name" >&2
fi

# Print the absolute path for Claude Code
echo "$DIR"
