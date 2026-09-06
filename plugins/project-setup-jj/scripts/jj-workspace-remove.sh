#!/usr/bin/env bash
set -euo pipefail

# WorktreeRemove hook: forget and remove a jj workspace the create hook made.
#
# Two calling forms:
#   harness:  JSON on stdin — {"worktree_path": ..., "cwd": ...}
#   /finish:  positional — jj-workspace-remove.sh <worktree_path> <cwd>
# The positional form exists because /finish runs this from the MAIN checkout
# after ExitWorktree (the WorktreeRemove hook no longer fires for a worktree the
# session has already left), and a plain two-argument command fits its
# allowed-tools where a stdin pipe would not.

if [ "$#" -ge 2 ]; then
  workspace_path="$1"
  cwd="$2"
else
  input=$(cat)
  workspace_path=$(echo "$input" | jq -r '.worktree_path')
  cwd=$(echo "$input" | jq -r '.cwd')
fi

if [ -z "$workspace_path" ] || [ "$workspace_path" = "null" ]; then
  echo "jj-workspace-remove: no worktree_path given" >&2
  exit 2
fi
workspace_path="${workspace_path%/}"

# This script ends in `rm -rf`, and since /finish can now supply the path it
# refuses anything that is not a harness workspace. Both /tmp spellings; the
# path must have a <repo>/<name> tail.
case "$workspace_path" in
  /tmp/jj-workspaces/*/*|/private/tmp/jj-workspaces/*/*) ;;
  *) echo "jj-workspace-remove: refusing a path outside /tmp/jj-workspaces/<repo>/: $workspace_path" >&2
     exit 2 ;;
esac

# Registry name = "workspace-" + the path RELATIVE to /tmp/jj-workspaces/<repo>/.
# Not basename: the create hook registers `workspace-<name>` for the full
# name, and EnterWorktree allows slash-separated names (`feat/auth`), so
# basename would forget `workspace-auth` — a miss, swallowed — and then remove
# the directory anyway, leaving a registration that points at nothing.
rel="${workspace_path#/private}"
rel="${rel#/tmp/jj-workspaces/}"
name="${rel#*/}"                      # drop the <repo> segment

# Forget first (a failure here is not fatal — the workspace may already be
# forgotten), then remove the directory.
jj -R "$cwd" workspace forget "workspace-$name" 2>/dev/null || true
rm -rf "$workspace_path"
