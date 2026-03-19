#!/usr/bin/env bash
set -euo pipefail

# WorktreeRemove hook: Remove a jj workspace created by WorktreeCreate
# Input (stdin): JSON with "worktree_path" and "cwd" fields

input=$(cat)
# Claude Code sends .worktree_path in the hook JSON (can't change the key name)
workspace_path=$(echo "$input" | jq -r '.worktree_path')
cwd=$(echo "$input" | jq -r '.cwd')

# Extract workspace name from directory name
name=$(basename "$workspace_path")

# Forget the workspace in jj (stop tracking it)
# Use -R to target the repo, ignore errors if workspace already forgotten
jj -R "$cwd" workspace forget "workspace-$name" 2>/dev/null || true

# Remove the workspace directory
rm -rf "$workspace_path"
