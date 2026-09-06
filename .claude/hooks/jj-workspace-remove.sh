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
#
# A path outside /tmp/jj-workspaces/<repo>/ (or containing '..') now exits 2
# and removes nothing; the old hook removed whatever it was given.

if [ "$#" -ge 2 ]; then
  workspace_path="$1"
  cwd="$2"
elif [ "$#" -eq 1 ]; then
  echo "usage: jj-workspace-remove.sh <worktree_path> <cwd>   (or JSON on stdin)" >&2
  exit 2
else
  input=$(cat)
  workspace_path=$(echo "$input" | jq -r '.worktree_path')
  cwd=$(echo "$input" | jq -r '.cwd')
fi

if [ -z "$workspace_path" ] || [ "$workspace_path" = "null" ]; then
  echo "jj-workspace-remove: no worktree_path given" >&2
  exit 2
fi

# No harness-produced or `jj workspace root` path ever contains '..', so this
# refusal is deliberately over-broad: it exists only to stop a lexical prefix
# match (below) from being defeated by a crafted '../../..' segment.
case "$workspace_path" in
  *..*) echo "jj-workspace-remove: refusing a path containing '..': $workspace_path" >&2
        exit 2 ;;
esac

while [ "${workspace_path%/}" != "$workspace_path" ]; do workspace_path="${workspace_path%/}"; done

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
