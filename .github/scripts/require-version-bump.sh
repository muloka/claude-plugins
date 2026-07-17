#!/usr/bin/env bash
# Fail if a PR changes files under plugins/<name>/ without bumping that
# plugin's version in plugins/<name>/.claude-plugin/plugin.json.
#
# Why (#84): the Claude plugin cache is keyed by version STRING. If content
# changes but the version does not, `claude plugin update` sees equal versions,
# prints "already at the latest version", and never re-fetches — the change
# ships to nobody. A green checkmark over stale content.
#
# Inputs (env), injected so this is testable with no VCS at all:
#   CHANGED_FILES  newline-separated repo-relative paths the PR touched
#   BASE_DIR       path to a checkout of the PR's base ref; base versions are
#                  read from "$BASE_DIR/<manifest>". A manifest absent there
#                  means the plugin is new in this PR.
# Head versions are read from the working tree (cwd = repo root).
#
# Runs on ubuntu bash 5 in CI and macOS bash 3.2 in the suite — keep it
# 3.2-safe: no associative arrays, no mapfile, no globstar, no jq. No git/jj:
# obtaining the base tree is the workflow's job (a second checkout).
set -euo pipefail

CHANGED_FILES="${CHANGED_FILES:-}"
BASE_DIR="${BASE_DIR:-}"

# Extract the top-level "version" string from a plugin.json on stdin. Our own
# controlled manifests carry exactly one "version" key, so this is safe.
version_of() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# Unique plugin names with any changed file under plugins/<name>/.
# Paths directly under plugins/ (e.g. plugins/.DS_Store) have no <name>/ and
# are correctly ignored.
plugins=$(printf '%s\n' "$CHANGED_FILES" \
  | sed -n 's#^plugins/\([^/]*\)/.*#\1#p' \
  | sort -u)

failed=0
# Here-string, NOT a pipe: `... | while` runs the loop in a subshell, losing
# `failed`, so the script would exit 0 over an unbumped change — #84 inside its
# own fix.
while IFS= read -r name; do
  [ -n "$name" ] || continue
  manifest="plugins/$name/.claude-plugin/plugin.json"

  # Full plugin deletion (manifest gone at head): nothing to bump — skip.
  [ -f "$manifest" ] || continue

  head_ver=$(version_of < "$manifest")

  # Base manifest absent => plugin is new in this PR => nothing to bump.
  base_manifest="$BASE_DIR/$manifest"
  if [ -f "$base_manifest" ]; then
    base_ver=$(version_of < "$base_manifest")
  else
    base_ver=""
  fi

  if [ -n "$base_ver" ] && [ "$base_ver" = "$head_ver" ]; then
    echo "::error::plugin '$name' changed but its version is still $head_ver — bump $manifest (the cache is keyed by version; an unbumped change never re-fetches, see #84)"
    failed=1
  fi
done <<< "$plugins"

exit "$failed"
