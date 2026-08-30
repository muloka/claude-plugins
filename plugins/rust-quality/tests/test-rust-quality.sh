#!/usr/bin/env bash
set -euo pipefail

# Structural contract for the rust-quality plugin: manifest is valid, the
# specialist file honors the basename-is-concern-type contract, and the
# frontmatter fields peer-review-jj's dispatch reads are present.
# (validate-frontmatter.yml does not cover specialists/*.md — this suite is
# the only check that frontmatter gets.)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$SCRIPT_DIR/.."

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

MANIFEST="$PLUGIN_ROOT/.claude-plugin/plugin.json"
if [ -f "$MANIFEST" ] && jq -e . "$MANIFEST" >/dev/null 2>&1; then
  ok "plugin.json exists and parses"
  jq -e '.name == "rust-quality"' "$MANIFEST" >/dev/null \
    && ok "manifest name is rust-quality" || bad "manifest/name" "$(jq -r .name "$MANIFEST")"
  jq -e '.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' "$MANIFEST" >/dev/null \
    && ok "manifest version is semver" || bad "manifest/version" "$(jq -r .version "$MANIFEST")"
  jq -e 'has("hooks") | not' "$MANIFEST" >/dev/null \
    && ok "prompt-only plugin ships no hooks" || bad "manifest/hooks" "hooks present"
else
  bad "manifest" "missing or invalid JSON at $MANIFEST"
fi

SPECIALIST="$PLUGIN_ROOT/specialists/rust.md"
if [ -f "$SPECIALIST" ]; then
  ok "specialists/rust.md exists"
else
  bad "specialist" "missing $SPECIALIST"
fi

# Basename-is-concern-type: every specialist's frontmatter name equals its
# file basename. First-match-wins shadowing keys on this string.
for f in "$PLUGIN_ROOT"/specialists/*.md; do
  base="$(basename "$f" .md)"
  fmname="$(awk '/^---$/{n++; next} n==1 && $1=="name:"{print $2; exit}' "$f")"
  if [ "$fmname" = "$base" ]; then
    ok "specialist $base: frontmatter name matches basename"
  else
    bad "specialist $base" "frontmatter name is '$fmname'"
  fi
  grep -q '^model: ' "$f" \
    && ok "specialist $base: model pinned" || bad "specialist $base" "no model: line"
  grep -q '^description: ' "$f" \
    && ok "specialist $base: has description" || bad "specialist $base" "no description: line"
done

# Sections the receiving skill's template expects (refinement appends target
# '## Proposed Refinements' verbatim).
for sec in '## Role' '## Review Focus' '## Proposed Refinements'; do
  grep -qxF "$sec" "$SPECIALIST" \
    && ok "specialist has section: $sec" || bad "specialist/section" "missing $sec"
done

[ -f "$PLUGIN_ROOT/README.md" ] && ok "README exists" || bad "readme" "missing"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
