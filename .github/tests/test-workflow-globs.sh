#!/usr/bin/env bash
# Verifies every glob a validation workflow relies on matches at least one file.
#
# Why this exists (#82): validate-frontmatter.yml gates on `paths:` globs. A
# glob that matches nothing means the workflow never triggers, which on GitHub
# is indistinguishable from passing — green tick, no check. `**/skills/*/SKILL.md`
# matched ZERO files for months (#77) and nobody noticed.
#
# This CANNOT live inside validate-frontmatter.yml: that workflow only triggers
# on the very globs it would check, so a dead glob means no trigger means no
# check — the same circularity. It runs unconditionally via the test runner
# (.github/workflows/test.yml, no paths: filter).
#
# The globs are EXTRACTED from the workflow, never hardcoded: a hardcoded copy
# would go stale when a glob is added — #82 inside the fix for #82.
#
# Usage: test-workflow-globs.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$ROOT/.github/workflows/validate-frontmatter.yml"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Evaluate an Actions `paths:` glob via `find`, NOT bash globstar.
# macOS runners ship bash 3.2, which has no `shopt -s globstar` — a lint that
# needs bash 4+ is a portability bug the way the statusline one is (#88), and it
# is the exact failure CI caught on this lint's first run. `find` is version-
# independent. `**` and `*` both become find's `*` (which already crosses `/`),
# and a leading `**/` is folded into the `*/` anchor.
_glob_to_findpath() {
  local g="$1"
  g="${g#\*\*/}"       # strip a leading **/
  g="${g//\*\*/\*}"    # any remaining ** -> *
  printf '*/%s' "$g"
}
_glob_match_count() {
  find "$ROOT" -path "$(_glob_to_findpath "$1")" -not -path '*/.jj/*' 2>/dev/null | wc -l | tr -d ' '
}

# Extract the quoted entries under `paths:` in the workflow.
globs=$(awk '
  /^[[:space:]]*paths:/ {inpaths=1; next}
  inpaths && /^[[:space:]]*-[[:space:]]/ {
    line=$0
    sub(/^[[:space:]]*-[[:space:]]*/, "", line)
    gsub(/^['\''"]|['\''"]$/, "", line)
    print line
    next
  }
  inpaths && /^[[:space:]]*[^[:space:]-]/ {inpaths=0}
' "$WF")

# fail loudly if we extracted nothing — a glob-checker that checks no globs is
# the bug (#82 applied to itself).
n=$(printf '%s\n' "$globs" | grep -c .)
if [ "$n" -eq 0 ]; then
  bad "no paths: globs found in $WF — the parser or the workflow changed"
else
  ok "extracted $n glob(s) from validate-frontmatter.yml"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    c=$(_glob_match_count "$g")
    if [ "$c" -gt 0 ]; then
      ok "$g matches $c file(s)"
    else
      bad "$g matches ZERO files — the workflow gates on it but it is dead (see #77)"
    fi
  done <<< "$globs"
fi

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
