#!/usr/bin/env bash
set -euo pipefail

# WorktreeCreate hook: Create a jj workspace for Claude Code worktree isolation
# Input (stdin): JSON with "name" and "cwd" fields
# Output (stdout): Absolute path to created workspace directory

input=$(cat)
name=$(echo "$input" | jq -r '.name')
cwd=$(echo "$input" | jq -r '.cwd')

DIR="$cwd/.claude/workspaces/$name"
mkdir -p "$(dirname "$DIR")"

# Create jj workspace at the directory, branching from the current working copy's parents
# Use -R to operate on the repo at cwd, redirect jj output to stderr
jj -R "$cwd" workspace add "$DIR" --name "workspace-$name" >&2

# Print the absolute path for Claude Code
echo "$DIR"
